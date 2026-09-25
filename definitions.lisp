(in-package #:nyaa)

;;; The table of service definitions DEFINE-TOOL, DEFINE-PROTOCOL and
;;; DEFINE-PROVIDER fill, so a front end can mount a service by name. See
;;; docs/tools.md#definitions.

(defvar *definitions* (make-hash-table :test 'eq)
  "Service name -> (:kind k :class c :depends-on (names)).")

(defun register-definition (name kind class &optional depends-on)
  (setf (gethash name *definitions*)
        (list :kind kind :class class :depends-on depends-on))
  name)

(defun definitions (&key kind)
  "Every defined service name, sorted, optionally only those of KIND."
  (sort (loop for name being the hash-keys of *definitions* using (hash-value entry)
              when (or (null kind) (eq kind (getf entry :kind)))
                collect name)
        #'string< :key #'string))

(defun ensure-mounted (context name &rest initargs)
  "Mount NAME under CONTEXT, its dependencies first, unless a service is
already registered under it. INITARGS apply to NAME only. Signals for a name
nothing defines."
  (let ((entry (gethash name *definitions*)))
    (unless entry (error "No definition for ~s." name))
    (unless (m:lookup name)
      (dolist (dependency (getf entry :depends-on))
        (ensure-mounted context dependency))
      (apply #'m:mount context (getf entry :class) initargs))
    name))
