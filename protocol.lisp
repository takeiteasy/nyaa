(in-package #:nyaa)

;;; The protocol convention. A protocol is a meow service named
;;; :PROTOCOL-<name> whose METADATA carries :KIND :PROTOCOL, and which answers
;;; (:describe) and (:complete . plist). It translates one neutral model
;;; contract onto one wire shape; base URL, auth and model catalogue are
;;; provider data layered on top. See docs/protocols.md.

(defparameter +protocol-roles+ '(:system :user :assistant :tool)
  "The closed set of message roles.")

(defun protocols (&key (registry m:*registry*))
  "Every registered protocol name, sorted."
  (sort (loop for name in (m:names :registry registry)
              for props = (nth-value 1 (m:lookup name :registry registry))
              when (eq (getf props :kind) :protocol)
                collect name)
        #'string< :key #'string))

(defun %protocol-process (name &key (registry m:*registry*))
  "NAME's process and its registration props. A provider answers the same
messages, so both reach a backend through here."
  (multiple-value-bind (process props) (m:lookup name :registry registry)
    (unless process (error "Nothing registered under ~s." name))
    (values process props)))

(defun describe-protocol (name &key (registry m:*registry*))
  "NAME's metadata plist."
  (m:call (%protocol-process name :registry registry) '(:describe)))

;;; --- content ----------------------------------------------------------

(defun text-block (text) (list :type :text :text text))

(defun normalize-content (content)
  "CONTENT as a list of typed blocks. A flat string is the degenerate
single-text-block case."
  (etypecase content
    (null nil)
    (string (list (text-block content)))
    (cons content)))

(defun content-text (content)
  "The text blocks of CONTENT, concatenated."
  (with-output-to-string (out)
    (dolist (block (normalize-content content))
      (when (eq (getf block :type) :text)
        (write-string (getf block :text "") out)))))

;;; --- requests ---------------------------------------------------------

;;; COERCE-ARGS is deliberately not used here: it rejects a key its schema
;;; does not name, and the contract ignores unknown keys so a portable caller
;;; may offer a superset. The checks below are the whole pre-flight.

(defun check-request (request)
  "NIL when REQUEST satisfies the contract, else a problem string."
  (cond
    ((not (and (listp request) (evenp (length request))))
     "request must be a plist")
    ((not (listp (getf request :messages)))
     "messages must be a list")
    ((null (getf request :messages))
     "messages is required")
    (t (some #'check-message (getf request :messages)))))

(defun check-message (message)
  (let ((role (getf message :role)))
    (cond
      ((not (and (listp message) (evenp (length message))))
       (format nil "message must be a plist, got ~s" message))
      ((not (member role +protocol-roles+))
       (format nil "role must be one of ~{~(~s~)~^, ~}, got ~s"
               +protocol-roles+ role))
      ((and (eq role :tool) (not (getf message :tool-call-id)))
       "a tool message must carry :tool-call-id")
      (t (some #'check-tool-call (getf message :tool-calls))))))

(defun check-tool-call (call)
  (unless (and (listp call) (getf call :id) (getf call :name))
    (format nil "a tool call must carry :id and :name, got ~s" call)))

;;; TODO: a completion in flight can only be abandoned at its deadline; there
;;; is no cancel message, so an interrupted caller pays the full timeout.
;;; Upgrade path: (:cancel ref), which makes :REF load-bearing rather than
;;; merely echoed. Tracked in ~takeiteasy/nyaa#32.

(defun complete (name &rest request)
  "Perform one turn against protocol or provider NAME. Returns (:ok plist) or
(:error reason)."
  (let ((problem (check-request request)))
    (if problem
        (bad-request "~a" problem)
        (multiple-value-bind (process props) (%protocol-process name)
          (m:call process
                  (list* :complete request)
                  ;; A provider delegates to its protocol, so the reply
                  ;; travels two hops and each waiter needs its own margin.
                  :timeout (%caller-timeout
                            request
                            (if (eq (getf props :kind) :provider) 2 1)))))))

;;; --- streaming --------------------------------------------------------

;;; A neutral event vocabulary, never raw provider chunks: the agent loop and
;;; the UIs consume these.
;;;
;;; TODO: three events and no error among them, so a stream that breaks down
;;; mid-turn stops without a terminating event and the reason reaches the
;;; caller only as the reply. Upgrade path: a failure reason on :DONE.
;;; Tracked in ~takeiteasy/nyaa#31.

(defun text-delta (ref text)
  (list :type :text-delta :ref ref :text text))

(defun tool-call-delta (ref &key id name arguments)
  "ARGUMENTS is a fragment of the call's argument text, which arrives split
across deltas."
  (list :type :tool-call-delta :ref ref :id id :name name :arguments arguments))

(defun done (ref &optional reason)
  (list :type :done :ref ref :reason reason))

(defun emit-event (sink event)
  "Deliver EVENT to SINK, a function or a meow process. A null sink drops it."
  (etypecase sink
    (null nil)
    (m:process (m:send sink event))
    ((or function symbol) (funcall sink event)))
  event)

;;; --- results ----------------------------------------------------------

;;; The docs/tools.md error vocabulary, plus one shape protocols add.

(defun backend-error (status detail)
  "The backend was reached and the exchange broke down: a non-OK STATUS, a
malformed payload, a stream cut short."
  (fail (list :backend-error status detail)))

;;; --- the handler ------------------------------------------------------

(defmacro define-protocol-handler (class (service request) &body body)
  "Define HANDLE for CLASS: (:describe) answers METADATA and
(:complete . plist) runs BODY with REQUEST bound to the plist, checked against
the contract. Meow intercepts %update-config, %effects and %timer-fire before
HANDLE, so a protocol must not use those heads."
  (a:with-gensyms (problem)
    `(defmethod m:handle ((,service ,class) message)
       (case (first message)
         (:describe (m:metadata ,service))
         ;; COMPLETE checks too; doing it here as well means a protocol
         ;; reached by a bare M:CALL sees the same checked request.
         (:complete (let* ((,request (rest message))
                           (,problem (check-request ,request)))
                      (declare (ignorable ,request))
                      (if ,problem
                          (bad-request "~a" ,problem)
                          (progn ,@body))))
         (t (bad-request "unknown message ~s" (first message)))))))
