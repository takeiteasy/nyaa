(in-package #:nyaa)

#+sbcl (eval-when (:compile-toplevel :load-toplevel :execute) (require :sb-posix))

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
          ;; A symlink swapped into place between this check and
          ;; APPLY-FS-OP's actual open is not caught -- the two are not
          ;; atomic. Tracked in ~takeiteasy/nyaa#52.
          (let ((resolved (resolve-path lexical)))
            (if (and resolved (under-root (fs-root service) resolved))
                (apply-fs-op op resolved data)
                (fail (list :forbidden "path escapes sandbox root"))))))))

(defmethod initialize-instance :after ((service tool-fs) &key)
  ;; Normalise once, without a trailing slash, so UNDER-ROOT's boundary
  ;; check stays a single character comparison. Truenamed when the root
  ;; already exists, so it compares like with like against a RESOLVE-PATH
  ;; result -- /tmp is itself a symlink to /private/tmp on macOS, and a
  ;; lexical-only root would reject every path inside it once resolved.
  ;; A root given before it exists keeps the lexical form; nothing can
  ;; escape through it before then, since nothing under it exists either.
  (let ((lexical (normalize-path (native-absolute (fs-root service)))))
    (setf (slot-value service 'root)
          (or (resolve-path lexical) lexical))))

;;; --- the sandbox -----------------------------------------------------

;;; Two gates, in order: a lexical check first, so a path outside the root
;;; is rejected before anything touches the filesystem, and a resolved
;;; check behind it, so a symlink inside the root pointing out of it does
;;; not admit an open that lands elsewhere (~takeiteasy/nyaa#15). Neither
;;; gate alone is enough: the lexical check alone follows a symlink, and a
;;; resolved check alone would let ".." reach a sibling before the root is
;;; known to exist.

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

(defun leaf-link-p (path)
  "True when PATH's own final component is a symlink, dangling or not.
Only the leaf: an ancestor is checked when PATH recurses onto it as its
own leaf, in RESOLVE-PATH below.

Always NIL on an implementation other than SBCL or ECL: a dangling
symlink is then indistinguishable from a plain file, and RESOLVE-PATH
admits it. Tracked in ~takeiteasy/nyaa#53."
  #+sbcl (and (ignore-errors (sb-posix:readlink path)) t)
  #+ecl (eq :link (ignore-errors (ext:file-kind path nil)))
  #-(or sbcl ecl) nil)

(defun resolve-path (path)
  "PATH, absolute and lexically normalised, with every symlink along it
followed -- or NIL when it runs through a dangling one. TRUENAME* cannot
tell a dangling symlink from a plain file by itself: for one, it reports
the link's own path back unresolved, the same shape as an ordinary file
that exists. LEAF-LINK-P checks the leaf directly to tell them apart.

A path that does not exist yet -- a :write or :mkdir target -- resolves
through its deepest existing prefix instead, with the missing tail kept
literal, so a symlinked ancestor directory is still caught."
  (let ((truename (uiop:truename* path)))
    (cond
      ((and truename (leaf-link-p path)
            (equal (string-right-trim "/" (uiop:native-namestring truename))
                   (string-right-trim "/" path)))
       nil)
      (truename (string-right-trim "/" (uiop:native-namestring truename)))
      ((string= path "/") "/")
      (t (let* ((slash (position #\/ path :from-end t))
                (parent (if (and slash (plusp slash)) (subseq path 0 slash) "/"))
                (leaf (subseq path (1+ (or slash -1))))
                (resolved-parent (resolve-path parent)))
           (and resolved-parent
                (concatenate 'string resolved-parent
                            (if (string= resolved-parent "/") "" "/")
                            leaf)))))))

;;; --- operations ------------------------------------------------------

(defun apply-fs-op (op path data)
  (handler-case
      (case op
        (:read (ok :data (a:read-file-into-string path)))
        ;; :data is required for write alone, which the schema cannot say.
        ;; Tracked in ~takeiteasy/nyaa#30.
        (:write (if (null data)
                    (bad-request "data required for write, a string")
                    (progn
                      (ensure-directories-exist path)
                      (a:write-string-into-file data path
                                                :if-exists :supersede
                                                :if-does-not-exist :create)
                      (ok))))
        (:list (ok :files (sort (mapcar #'entry-name
                                        (append (uiop:subdirectories path)
                                                (uiop:directory-files path)))
                                #'string<)))
        (:mkdir (ensure-directories-exist (concatenate 'string path "/"))
                (ok))
        ;; Directories are refused and recursive delete is not offered: a
        ;; tool this easy to call should not be able to rm -rf.
        (:delete (if (uiop:directory-exists-p path)
                     (bad-request "delete refuses directories")
                     (progn (delete-file path) (ok))))
        (t (bad-request "unknown op ~s" op)))
    (file-error (e) (fail (list :error (princ-to-string e))))))

(defun entry-name (pathname)
  (if (uiop:directory-pathname-p pathname)
      (car (last (pathname-directory pathname)))
      (file-namestring pathname)))
