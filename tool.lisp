(in-package #:nyaa)

;;; The tool convention. A tool is a meow service named :TOOL-<name> whose
;;; METADATA carries :KIND :TOOL, and which answers (:describe) and
;;; (:invoke . plist). See docs/tools.md.

(defun %registered-of-kind (kind &key (registry m:*registry*))
  "Every name registered under KIND, sorted. Discovery is a scan of
registration props: meow has no props-filtered lookup. Shared by TOOLS,
PROTOCOLS, PROVIDERS and AGENTS, one per :KIND."
  (sort (loop for name in (m:names :registry registry)
              for props = (nth-value 1 (m:lookup name :registry registry))
              when (eq (getf props :kind) kind)
                collect name)
        #'string< :key #'string))

(defun tools (&key (registry m:*registry*))
  "Every registered tool name, sorted."
  (%registered-of-kind :tool :registry registry))

(defun %tool-process (name &key (registry m:*registry*))
  "NAME's process and its registration props, which carry the metadata."
  (multiple-value-bind (process props) (m:lookup name :registry registry)
    (unless process (error "No tool registered under ~s." name))
    (values process props)))

(defun describe-tool (name &key (registry m:*registry*))
  "NAME's metadata plist."
  (m:call (%tool-process name :registry registry) '(:describe)))

(defun tool-schema (metadata)
  "METADATA's parameter schema."
  (getf metadata :params))

(defconstant +default-tool-timeout+ 30000
  "Milliseconds a tool gives its own work when the caller names no deadline.")

(defun %caller-timeout (args &optional (hops 1))
  "Seconds to wait on M:CALL, read from ARGS after coercion. A tool bounds
its own work, so the caller must outlast it -- otherwise M:CALL's 5s default
aborts the caller while the tool runs on, and the tool's own (:error
:timeout) is never seen. HOPS is the number of services the call passes
through, each of which needs that margin over the one it waits on."
  (+ (* 5 hops) (/ (getf args :timeout +default-tool-timeout+) 1000)))

(defun invoke-tool (name &rest args)
  "Invoke NAME with ARGS, a plist. Returns (:ok plist) or (:error reason)."
  (multiple-value-bind (process props) (%tool-process name)
    (multiple-value-bind (coerced problem)
        (coerce-args (tool-schema props) args)
      (if problem
          (bad-request "~a" problem)
          (m:call process
                  (list* :invoke coerced)
                  :timeout (%caller-timeout coerced))))))

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

(defun tool-trust (metadata)
  "METADATA's :TRUST, or :AGENT when it names none. :OPERATOR marks a tool
that only a trusted operator may reach."
  (getf metadata :trust :agent))

;;; --- the handler -----------------------------------------------------

(defmacro define-tool-handler (class (service args) &body body)
  "Define HANDLE for CLASS: (:describe) answers METADATA and (:invoke . plist)
runs BODY with ARGS bound to the plist, coerced against the metadata schema.
Meow intercepts %update-config, %effects and %timer-fire before HANDLE, so a
tool must not use those heads."
  (a:with-gensyms (problem)
    `(defmethod m:handle ((,service ,class) message)
       (case (first message)
         (:describe (m:metadata ,service))
         ;; INVOKE-TOOL coerces too; doing it here as well means a tool
         ;; reached by a bare M:CALL sees the same checked arguments.
         (:invoke (multiple-value-bind (,args ,problem)
                      (coerce-args (tool-schema (m:metadata ,service))
                                   (rest message))
                    (declare (ignorable ,args))
                    (if ,problem
                        (bad-request "~a" ,problem)
                        (progn ,@body))))
         (t (bad-request "unknown message ~s" (first message)))))))
