(in-package #:nyaa)

;;; Filesystem tool, sandboxed to a root given at mount time.

(define-tool :tool-fs
    (:trust :agent
     :summary "Read, write, list and delete files, and remove empty directories, inside the sandboxed root"
     :slots ((root :initarg :root :reader fs-root :type string)
             (hide-links :initarg :hide-links :initform nil :reader fs-hide-links))
     :params ((:op (member :read :write :list :mkdir :delete :rmdir) :required t
               :doc "operation to perform")
              (:path string :required t
               :doc "path relative to the sandbox root")
              (:data string :required-when (:op :write) :doc "file contents")))
  (:invoke (op path data)
    (let ((lexical (normalize-path (join-path (fs-root service) path))))
      (if (not (under-root (fs-root service) lexical))
          (fail (list :forbidden "path escapes sandbox root"))
          (apply-fs-op op (fs-root service) lexical data (fs-hide-links service))))))

(defmethod initialize-instance :after ((service tool-fs) &key)
  ;; Normalise once, without a trailing slash, so UNDER-ROOT's boundary
  ;; check stays a single character comparison. Truenamed when the root
  ;; already exists, so it compares like with like against a lexically
  ;; normalised path -- /tmp is itself a symlink to /private/tmp on macOS,
  ;; and a lexical-only root would reject every path inside it once
  ;; resolved.
  ;; A root given before it exists keeps the lexical form; nothing can
  ;; escape through it before then, since nothing under it exists either.
  (let ((lexical (normalize-path (native-absolute (fs-root service)))))
    (setf (slot-value service 'root)
          (or (ignore-errors
               (string-right-trim "/" (uiop:native-namestring (uiop:truename* lexical))))
              lexical))))

;;; --- the sandbox -----------------------------------------------------

;;; A lexical check first, so a path outside the root is rejected before
;;; anything touches the filesystem, then an fd walk from the root (see
;;; tools/fs-posix.lisp): each component is opened with O_NOFOLLOW relative
;;; to its parent's fd, refusing every symlink below the root rather than
;;; resolving it. The final component is operated on relative to that
;;; directory, so the symlink check and the operation share one file
;;; descriptor -- there is no window between them for a swap to land in
;;; (~takeiteasy/nyaa#52).

(defun native-absolute (path)
  (if (and (plusp (length path)) (char= (char path 0) #\/))
      path
      (concatenate 'string (namestring (uiop:getcwd)) path)))

(defun join-path (root path)
  "PATH resolved against ROOT, unless it is already absolute."
  (if (and (plusp (length path)) (char= (char path 0) #\/))
      path
      (concatenate 'string root "/" path)))

(defun normalize-path (path)
  "Collapse \".\" and \"..\" segments as text, without touching the
filesystem. A leading \"..\" therefore lands outside the root instead of
prefix-matching it."
  (let ((kept '()))
    (dolist (segment (uiop:split-string path :separator "/"))
      (cond ((or (string= segment "") (string= segment ".")))
            ((string= segment "..") (pop kept))
            (t (push segment kept))))
    (format nil "/~{~a~^/~}" (nreverse kept))))

(defun under-root (root path)
  "True when PATH is ROOT or lives strictly beneath it. A bare prefix test
is not enough: it would admit siblings such as /sandbox-root-evil."
  (let ((n (length root)))
    (and (>= (length path) n)
         (string= root path :end2 n)
         (or (= (length path) n)
             (char= (char path n) #\/)))))

;;; --- operations --------------------------------------------------------

(defun path-components (root lexical)
  "LEXICAL's segments below ROOT, as a list of path components."
  (let ((tail (subseq lexical (length root))))
    (remove "" (uiop:split-string tail :separator "/") :test #'string=)))

(defun errno-result (errno &optional (not-found-message "no such file"))
  (case errno
    ((:eloop :enotdir) (fail (list :forbidden "path escapes sandbox root")))
    (:enoent (fail (list :error not-found-message)))
    (t (fail (list :error (string-downcase errno))))))

(defun apply-fs-op (op root lexical data hide-links)
  (let* ((components (path-components root lexical))
         (dirs (butlast components))
         (leaf (car (last components))))
    (multiple-value-bind (dirfd errno)
        (fs-walk root dirs :create (member op '(:write :mkdir)))
      (if (not dirfd)
          (errno-result errno)
          (unwind-protect
               (case op
                 (:list (fs-op-list dirfd leaf hide-links))
                 (:read (fs-op-read dirfd leaf))
                 (:write (fs-op-write dirfd leaf data))
                 (:mkdir (fs-op-mkdir dirfd leaf))
                 (:delete (fs-op-delete dirfd leaf))
                 (:rmdir (fs-op-rmdir dirfd leaf))
                 (t (bad-request "unknown op ~s" op)))
            (fs-close dirfd))))))

(defun fs-op-list (dirfd leaf hide-links)
  (multiple-value-bind (names errno) (fs-list-names dirfd leaf :hide-links hide-links)
    (if errno
        (errno-result errno "no such directory")
        (ok :files names))))

;;; The fd-stream in FS-SLURP-FD and FS-SPIT-FD owns the fd and closes it:
;;; closing it again here would risk closing a descriptor another thread has
;;; since been handed.

(defun fs-op-read (dirfd leaf)
  (if (null leaf)
      (fail (list :error "is a directory"))
      (multiple-value-bind (fd errno) (fs-open-leaf dirfd leaf '(:rdonly) 0)
        (if fd
            (ok :data (fs-slurp-fd fd))
            (errno-result errno)))))

(defun fs-op-write (dirfd leaf data)
  (if (null leaf)
      (fail (list :error "is a directory"))
      (multiple-value-bind (fd errno)
          (fs-open-leaf dirfd leaf '(:wronly :creat :trunc) #o644)
        (if fd
            (progn (fs-spit-fd fd data) (ok))
            (errno-result errno)))))

(defun fs-op-mkdir (dirfd leaf)
  (if (null leaf)
      (ok) ; the root itself always exists as a directory
      (multiple-value-bind (success errno) (fs-mkdir-leaf dirfd leaf #o755)
        (cond (success (ok))
              ((and (eq errno :eexist) (not (fs-symlink-leaf-p dirfd leaf))) (ok))
              ((eq errno :eexist) (fail (list :forbidden "path escapes sandbox root")))
              (t (errno-result errno))))))

(defun fs-op-delete (dirfd leaf)
  (cond
    ((null leaf) (bad-request "delete refuses directories"))
    ((fs-symlink-leaf-p dirfd leaf) (fail (list :forbidden "path escapes sandbox root")))
    (t (multiple-value-bind (success errno) (fs-unlink-leaf dirfd leaf)
         (cond (success (ok))
               ;; Directories are refused and recursive delete is not
               ;; offered: a tool this easy to call should not be able to
               ;; rm -rf. EPERM covers macOS's unlink(2) on a directory;
               ;; Linux reports EISDIR for the same attempt.
               ((member errno '(:eisdir :eperm)) (bad-request "delete refuses directories"))
               (t (errno-result errno)))))))

;;; The kernel refuses a non-empty directory, so no recursive removal is possible.

(defun fs-op-rmdir (dirfd leaf)
  (if (null leaf)
      (bad-request "rmdir refuses the sandbox root")
      ;; Before the unlink: a symlink to a directory also fails ENOTDIR.
      (if (fs-symlink-leaf-p dirfd leaf)
          (fail (list :forbidden "path escapes sandbox root"))
          (multiple-value-bind (success errno) (fs-rmdir-leaf dirfd leaf)
            (declare (ignore success))
            (case errno
              ((nil) (ok))
              ((:enotempty :eexist) (bad-request "directory not empty"))
              (:enotdir (bad-request "not a directory"))
              (t (errno-result errno)))))))

(defun fs-slurp-fd (fd)
  (with-open-stream (s (sb-sys:make-fd-stream fd :input t :element-type 'character))
    (uiop:slurp-stream-string s)))

(defun fs-spit-fd (fd data)
  (with-open-stream (s (sb-sys:make-fd-stream fd :output t :element-type 'character))
    (write-string data s)))
