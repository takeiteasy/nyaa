(in-package #:nyaa)

;;; The tool convention. A tool is a meow service named :TOOL-<name> whose
;;; METADATA carries :KIND :TOOL, and which answers (:describe) and
;;; (:invoke . plist). See docs/tools.md.

(defun tools (&key (registry m:*registry*))
  "Every registered tool name, sorted. Discovery is a scan of registration
props: meow has no props-filtered lookup."
  (sort (loop for name in (m:names :registry registry)
              for props = (nth-value 1 (m:lookup name :registry registry))
              when (eq (getf props :kind) :tool)
                collect name)
        #'string< :key #'string))

(defun %tool-process (name &key (registry m:*registry*))
  (or (m:lookup name :registry registry)
      (error "No tool registered under ~s." name)))

(defun describe-tool (name &key (registry m:*registry*))
  "NAME's metadata plist."
  (m:call (%tool-process name :registry registry) '(:describe)))

(defconstant +default-tool-timeout+ 30000
  "Milliseconds a tool gives its own work when the caller names no deadline.")

(defun %caller-timeout (args)
  "Seconds to wait on M:CALL. A tool bounds its own work, so the caller must
outlast it -- otherwise M:CALL's 5s default aborts the caller while the tool
runs on, and the tool's own (:error :timeout) is never seen."
  (let ((ms (getf args :timeout +default-tool-timeout+)))
    (+ 5 (/ (if (and (integerp ms) (plusp ms)) ms +default-tool-timeout+)
            1000))))

(defun invoke-tool (name &rest args)
  "Invoke NAME with ARGS, a plist. Returns (:ok plist) or (:error reason)."
  (m:call (%tool-process name)
          (list* :invoke args)
          :timeout (%caller-timeout args)))

;;; --- results ---------------------------------------------------------

;;; One error vocabulary across every tool and adapter:
;;;   (:bad-request msg) | :timeout | :unavailable | (:error detail)

(defun ok (&rest plist) (list :ok plist))
(defun fail (reason) (list :error reason))
(defun bad-request (format &rest args)
  (fail (list :bad-request (apply #'format nil format args))))

(defun tool-error-p (result)
  (and (consp result) (eq (first result) :error)))

(defun tool-error (result)
  (when (tool-error-p result) (second result)))

;;; --- argument coercion -----------------------------------------------

;;; Model-supplied arguments arrive as whatever the caller had to hand:
;;; strings, symbols or keywords. Accept all three, reject the rest.

(defun arg-string (value)
  "VALUE as a string, or NIL if it is absent or of an unusable type. NIL is
absence, never the symbol name."
  (typecase value
    (null nil)
    (string value)
    (symbol (string-downcase (symbol-name value)))
    (t nil)))

(defun arg-timeout (args)
  "ARGS' :timeout in milliseconds, or NIL if it is present but unusable."
  (let ((ms (getf args :timeout +default-tool-timeout+)))
    (and (integerp ms) (plusp ms) ms)))

(defmacro define-tool-handler (class (service args) &body body)
  "Define HANDLE for CLASS: (:describe) answers METADATA and (:invoke . plist)
runs BODY with ARGS bound to the plist. Meow intercepts %update-config,
%effects and %timer-fire before HANDLE, so a tool must not use those heads."
  `(defmethod m:handle ((,service ,class) message)
     (case (first message)
       (:describe (m:metadata ,service))
       (:invoke (let ((,args (rest message)))
                  (declare (ignorable ,args))
                  ,@body))
       (t (bad-request "unknown message ~s" (first message))))))
