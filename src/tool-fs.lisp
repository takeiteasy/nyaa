(in-package #:nyaa)

;;; Filesystem tool, sandboxed to a root given at mount time.
;;;
;;; TODO: the sandbox is path-based, so a symlink inside the root pointing
;;; out of it is followed. Upgrade path: resolve each path and re-check the
;;; result against the root, keeping the lexical check as the first gate.
;;; Tracked in ~takeiteasy/nyaa#15.

(m:defservice tool-fs ()
  ((root :initarg :root :reader fs-root :type string))
  (:name :tool-fs))

(defmethod initialize-instance :after ((service tool-fs) &key)
  ;; Normalise once, without a trailing slash, so UNDER-ROOT's boundary
  ;; check stays a single character comparison.
  (setf (slot-value service 'root)
        (normalize-path (native-absolute (fs-root service)))))

(defmethod m:metadata ((service tool-fs))
  (list :kind :tool
        :name :tool-fs
        :trust :agent
        :summary "Read, write, list and delete files inside the sandboxed root"
        :params '((:op (member :read :write :list :mkdir :delete) :required t
                   :doc "operation to perform")
                  (:path string :required t
                   :doc "path relative to the sandbox root")
                  (:data string :doc "file contents, for write"))))

(define-tool-handler tool-fs (service args)
  (let ((resolved (normalize-path (join-path (fs-root service)
                                             (getf args :path)))))
    (if (under-root (fs-root service) resolved)
        (apply-fs-op (getf args :op) resolved args)
        (fail (list :forbidden "path escapes sandbox root")))))

;;; --- the sandbox -----------------------------------------------------

;;; The check is lexical and must stay lexical: resolving symlinks here
;;; would break the guarantee that a normalised path outside the root is
;;; rejected before anything touches the filesystem.

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

;;; --- operations ------------------------------------------------------

(defun apply-fs-op (op path args)
  (handler-case
      (case op
        (:read (ok :data (a:read-file-into-string path)))
        ;; :data is required for write alone, which the schema cannot say.
        ;; Tracked in ~takeiteasy/nyaa#30.
        (:write (let ((data (getf args :data)))
                  (if (null data)
                      (bad-request "data required for write, a string")
                      (progn
                        (ensure-directories-exist path)
                        (a:write-string-into-file data path
                                                  :if-exists :supersede
                                                  :if-does-not-exist :create)
                        (ok)))))
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
