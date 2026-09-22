(in-package #:nyaa)

;;; Filesystem tool, sandboxed to a root given at mount time.

(define-tool :tool-fs
    (:trust :agent
     :summary "Read, write, list and delete files inside the sandboxed root"
     :slots ((root :initarg :root :reader fs-root :type string))
     :params ((:op (member :read :write :list :mkdir :delete) :required t
               :doc "operation to perform")
              (:path string :required t
               :doc "path relative to the sandbox root")
              (:data string :doc "file contents, for write")))
  (:invoke (op path data)
    (let ((lexical (normalize-path (join-path (fs-root service) path))))
      (if (not (under-root (fs-root service) lexical))
          (fail (list :forbidden "path escapes sandbox root"))
          (apply-fs-op op (fs-root service) lexical data)))))

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
;;; tools/fs-posix.lisp): each component is opened with O_NOFOLLOW and
;;; stepped into, refusing every symlink below the root rather than
;;; resolving it. The final component is operated on relative to that
;;; directory, so the symlink check and the operation share one file
;;; descriptor -- there is no window between them for a swap to land in
;;; (~takeiteasy/nyaa#52).
;;;
;;; Unavailable outside SBCL, ECL and CCL: without the walk, a path
;;; re-check is racy the same way, so TOOL-FS answers :UNAVAILABLE rather
;;; than fall back to one (~takeiteasy/nyaa#53).

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
    (:unavailable (fail :unavailable))
    (t (fail (list :error (string-downcase errno))))))

(defun apply-fs-op (op root lexical data)
  #-(or sbcl ecl ccl) (declare (ignore op root lexical data))
  #-(or sbcl ecl ccl) (fail :unavailable)
  #+(or sbcl ecl ccl)
  (bt:with-lock-held (*fs-lock*)
    (with-fs-cwd-saved
      (let* ((components (path-components root lexical))
             (dirs (butlast components))
             (leaf (car (last components))))
        (multiple-value-bind (ok errno)
            (fs-walk root dirs :create (member op '(:write :mkdir)))
          (if (not ok)
              (errno-result errno)
              (case op
                (:list (fs-op-list leaf))
                (:read (fs-op-read leaf))
                (:write (fs-op-write leaf data))
                (:mkdir (fs-op-mkdir leaf))
                (:delete (fs-op-delete leaf))
                (t (bad-request "unknown op ~s" op)))))))))

(defun fs-op-list (leaf)
  (if (null leaf)
      (ok :files (fs-list-names))
      (multiple-value-bind (fd errno) (fs-open-dir-component leaf)
        (if (not fd)
            (errno-result errno "no such directory")
            (progn
              (unwind-protect
                   (if (fs-fchdir fd)
                       (ok :files (fs-list-names))
                       (fail (list :error "cannot enter directory")))
                (fs-close fd)))))))

(defun fs-op-read (leaf)
  (if (null leaf)
      (fail (list :error "is a directory"))
      (multiple-value-bind (fd errno) (fs-open-leaf leaf '(:rdonly) 0)
        (if (not fd)
            (errno-result errno)
            (unwind-protect (ok :data (fs-slurp-fd fd))
              (fs-close fd))))))

(defun fs-op-write (leaf data)
  (cond
    ((null leaf) (fail (list :error "is a directory")))
    ;; :data is required for write alone, which the schema cannot say.
    ;; Tracked in ~takeiteasy/nyaa#30.
    ((null data) (bad-request "data required for write, a string"))
    (t (multiple-value-bind (fd errno)
           (fs-open-leaf leaf '(:wronly :creat :trunc) #o644)
         (if (not fd)
             (errno-result errno)
             (unwind-protect (progn (fs-spit-fd fd data) (ok))
               (fs-close fd)))))))

(defun fs-op-mkdir (leaf)
  (if (null leaf)
      (ok) ; the root itself always exists as a directory
      (multiple-value-bind (success errno) (fs-mkdir-leaf leaf #o755)
        (cond (success (ok))
              ((and (eq errno :eexist) (not (fs-symlink-leaf-p leaf))) (ok))
              ((eq errno :eexist) (fail (list :forbidden "path escapes sandbox root")))
              (t (errno-result errno))))))

(defun fs-op-delete (leaf)
  (cond
    ((null leaf) (bad-request "delete refuses directories"))
    ((fs-symlink-leaf-p leaf) (fail (list :forbidden "path escapes sandbox root")))
    (t (multiple-value-bind (success errno) (fs-unlink-leaf leaf)
         (cond (success (ok))
               ;; Directories are refused and recursive delete is not
               ;; offered: a tool this easy to call should not be able to
               ;; rm -rf. EPERM covers macOS's unlink(2) on a directory;
               ;; Linux reports EISDIR for the same attempt.
               ((member errno '(:eisdir :eperm)) (bad-request "delete refuses directories"))
               (t (errno-result errno)))))))

(defun fs-slurp-fd (fd)
  #+sbcl (with-open-stream (s (sb-sys:make-fd-stream fd :input t :element-type 'character))
           (uiop:slurp-stream-string s))
  #+ecl (with-open-stream (s (ext:make-stream-from-fd fd :input :element-type 'character))
          (uiop:slurp-stream-string s))
  #+ccl (with-open-stream (s (ccl::make-fd-stream fd :direction :input :element-type 'character))
          (uiop:slurp-stream-string s)))

(defun fs-spit-fd (fd data)
  #+sbcl (with-open-stream (s (sb-sys:make-fd-stream fd :output t :element-type 'character))
           (write-string data s))
  #+ecl (with-open-stream (s (ext:make-stream-from-fd fd :output :element-type 'character))
          (write-string data s))
  #+ccl (with-open-stream (s (ccl::make-fd-stream fd :direction :output :element-type 'character))
          (write-string data s)))
