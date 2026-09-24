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
  (%registered-of-kind :protocol :registry registry))

(defun %protocol-process (name &key (registry m:*registry*))
  "NAME's process and its registration props. A provider answers the same
messages, so both reach a backend through here."
  (multiple-value-bind (process props) (m:lookup name :registry registry)
    (unless process (error "Nothing registered under ~s." name))
    (values process props)))

(defun describe-protocol (name &key (registry m:*registry*))
  "NAME's metadata plist."
  (m:call (%protocol-process name :registry registry) '(:describe)))

;;; --- connect refusal ---------------------------------------------------

;;; usocket's SBCL :timeout connect path does a non-blocking connect, then
;;; polls GETPEERNAME to detect success. On Linux, a refused connect leaves
;;; GETPEERNAME reporting ENOTCONN indefinitely rather than surfacing
;;; SO_ERROR, so a refusal spins until the whole connect timeout elapses
;;; instead of failing immediately.
;;;
;;; TODO: this binds an unexported usocket symbol to fall back to its
;;; legacy blocking connect, which does fail a refusal immediately (an
;;; unreachable host is still bounded by :timeout). Drop it once usocket's
;;; new connect loop checks SO_ERROR itself. Tracked in
;;; ~takeiteasy/nyaa#61.
(defmacro with-immediate-connect-refusal (&body body)
  "Run BODY -- which must make its USOCKET:SOCKET-CONNECT call directly,
inside the same thread -- so a refused connection fails at once rather
than waiting out the connect timeout."
  `(let ((usocket::*socket-connect-nonblock-wait* nil))
     ,@body))

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

;;; --- names and keys -----------------------------------------------------

;;; Shared by every protocol that speaks JSON over HTTP: what OpenAI and
;;; Ollama's native endpoint both need, so the second protocol to want it
;;; found it already here rather than duplicated (~takeiteasy/nyaa#33).

(defun named-p (value)
  (and (stringp value) (plusp (length value))))

(defun http-url-p (url)
  ;; Checked here so that everything past it failing before a status line is
  ;; a transport failure and nothing else.
  (some (lambda (scheme)
          (and (>= (length url) (length scheme))
               (string-equal scheme url :end2 (length scheme))))
        '("http://" "https://")))

(defun wire-key (name)
  "NAME as a JSON property name: :MAX-TOKENS is max_tokens."
  (substitute #\_ #\- (string-downcase (symbol-name name))))

(defun lisp-key (key)
  (a:make-keyword (string-upcase (substitute #\- #\_ key))))

(defun wire-tool-name (name)
  (string-downcase (symbol-name name)))

(defun lisp-tool-name (name)
  (a:make-keyword (string-upcase name)))

;;; --- values -------------------------------------------------------------

;;; Tool arguments are a plist in the contract and a JSON object on the wire.
;;; The tool's own schema names each value's type, so a map and an object stay
;;; distinguishable where a plist alone leaves them ambiguous.

(defun call-schema (name tools)
  "The schema of the tool NAME names among TOOLS, a list of tool metadata."
  (a:when-let ((metadata (find name tools :key (lambda (m) (getf m :name)))))
    (tool-schema metadata)))

(defun arguments->json (arguments schema)
  (let ((json (json-object)))
    (loop for (name value) on arguments by #'cddr
          for param = (find name schema :key #'param-name)
          do (setf (gethash (wire-key name) json)
                   (value->json value (and param (param-type param)))))
    json))

(defun value->json (value spec)
  (cond
    ((null spec) (untyped->json value))
    ((spec-is spec "OR") (if (null value) 'null (value->json value (third spec))))
    ((spec-is spec "ARRAY-OF")
     (map 'vector (lambda (element) (value->json element (second spec))) value))
    ((spec-is spec "MAP-OF")
     (let ((json (json-object)))
       (loop for (key entry) on value by #'cddr
             do (setf (gethash (as-text key) json)
                      (value->json entry (second spec))))
       json))
    ((spec-is spec "OBJECT") (arguments->json value (rest spec)))
    ((spec-is spec "ANY") (untyped->json value))
    (t (json-value value))))

;;; TODO: without a schema, a plist of keywords is an object and any other
;;; list an array -- a map whose keys coerced to strings renders as an array.
;;; Upgrade path: carry the schema on the call. Tracked in
;;; ~takeiteasy/nyaa#36.

(defun untyped->json (value)
  (cond
    ((null value) nil)
    ((keywordp value) (json-value value))
    ((not (consp value)) value)
    ((and (evenp (length value))
          (loop for (name) on value by #'cddr always (keywordp name)))
     (let ((json (json-object)))
       (loop for (name entry) on value by #'cddr
             do (setf (gethash (wire-key name) json) (untyped->json entry)))
       json))
    (t (map 'vector #'untyped->json value))))

(defun json->arguments (json schema)
  "JSON, a parsed object, as an argument plist. Names become keywords, which
is what COERCE-ARGS matches a schema on."
  (let ((plist '()))
    (maphash (lambda (key value)
               (let* ((name (lisp-key key))
                      (param (find name schema :key #'param-name)))
                 (push name plist)
                 (push (json->value value (and param (param-type param))) plist)))
             json)
    (nreverse plist)))

(defun json->value (value spec)
  (cond
    ((eq value 'null) nil)
    ((null spec) (untyped->lisp value))
    ((spec-is spec "OR") (json->value value (third spec)))
    ((spec-is spec "ARRAY-OF")
     (map 'list (lambda (element) (json->value element (second spec))) value))
    ((spec-is spec "MAP-OF")
     (loop for key being the hash-keys of value using (hash-value entry)
           collect key collect (json->value entry (second spec))))
    ((spec-is spec "OBJECT") (json->arguments value (rest spec)))
    ((spec-is spec "ANY") (untyped->lisp value))
    ;; A member arrives as its name and an integer as digits; COERCE-ARGS
    ;; takes both, so a scalar passes through untouched.
    (t value)))

(defun untyped->lisp (value)
  (cond
    ((eq value 'null) nil)
    ((hash-table-p value) (json->arguments value nil))
    ((and (vectorp value) (not (stringp value)))
     (map 'list #'untyped->lisp value))
    (t value)))

;;; --- the tools array ------------------------------------------------------

;;; Each tool's schema renders straight through SCHEMA->JSON-SCHEMA, in the
;;; shape both OpenAI and Ollama's native endpoint use:
;;; {"type":"function","function":{name,description,parameters}}.

(defun tools->json (tools)
  (map 'vector
       (lambda (metadata)
         (let ((function (json-object
                          "name" (wire-tool-name (getf metadata :name))
                          "parameters" (schema->json-schema
                                        (tool-schema metadata)))))
           (a:when-let ((summary (getf metadata :summary)))
             (setf (gethash "description" function) summary))
           (json-object "type" "function" "function" function)))
       tools))

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
;;; the UIs consume these. A turn ends with exactly one :DONE, whose reason is
;;; the finish reason or, when the exchange failed, the failed result.

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

;;; --- cancelling ---------------------------------------------------------

;;; A caller-held handle rather than a message: a protocol answers one message
;;; at a time, so a cancel sent to it would wait behind the completion it
;;; means to stop.

(defstruct (cancel-token (:constructor make-cancel-token ()))
  (lock (bt:make-lock)) cancelled actions)

(defun cancelled-p (token)
  (bt:with-lock-held ((cancel-token-lock token))
    (cancel-token-cancelled token)))

(defun on-cancel (token function)
  "Call FUNCTION when TOKEN is cancelled, at once if it already is."
  (when (bt:with-lock-held ((cancel-token-lock token))
          (or (cancel-token-cancelled token)
              (progn (push function (cancel-token-actions token)) nil)))
    (funcall function)))

(defun cancel (token)
  "Cancel whatever TOKEN was passed to as :CANCEL. Idempotent; true the first
time."
  (let ((actions (bt:with-lock-held ((cancel-token-lock token))
                   (unless (cancel-token-cancelled token)
                     (setf (cancel-token-cancelled token) t)
                     (shiftf (cancel-token-actions token) nil)))))
    (mapc #'funcall actions)
    (and actions t)))

;;; --- the exchange -------------------------------------------------------

;;; Shared by every protocol that talks to a backend over a socket: the
;;; deadline-bounded worker thread, and the reply and transport shapes a
;;; JSON-over-HTTP protocol needs regardless of wire dialect.
;;;
;;; The connection is opened here rather than left to drakma, so the deadline
;;; has a socket of its own to close: drakma's :connection-timeout only bounds
;;; connecting, not the whole exchange.

(defun header-alist (headers)
  "HEADERS, a coerced plist of names and values, as a lower-cased alist."
  (loop for (name value) on headers by #'cddr
        collect (cons (string-downcase name) value)))

(defstruct (exchange (:conc-name exchange-))
  socket cancelled finished (lock (bt:make-lock)))

(defun call-with-deadline (timeout-ms function &key (name "nyaa-exchange") cancel)
  "Run FUNCTION on a worker thread, bounded by TIMEOUT-MS. FUNCTION takes
CONNECT, a function of a URL answering a stream ready for drakma's :STREAM.
Answers (values result reason), REASON being :TIMEOUT or, when CANCEL -- a
cancel token -- fired, :CANCELLED. At either the connection is closed, so the
worker unwinds instead of running until the backend answers or hangs up."
  (when (and cancel (cancelled-p cancel))
    (return-from call-with-deadline (values nil :cancelled)))
  (let* ((result nil)
         (exchange (make-exchange))
         (done (bt:make-semaphore))
         (connect (lambda (url) (open-connection url exchange timeout-ms))))
    (when cancel
      (on-cancel cancel (lambda () (cancel-exchange exchange done name))))
    (bt:make-thread
     (lambda ()
       (unwind-protect
            (setf result (funcall function connect))
         (close-socket (exchange-socket exchange))
         (bt:signal-semaphore done)))
     :name (format nil "~a-request" name))
    (let ((finished (bt:wait-on-semaphore done :timeout (/ timeout-ms 1000))))
      (bt:with-lock-held ((exchange-lock exchange))
        (setf (exchange-finished exchange) t)
        (cond ((eq t (exchange-cancelled exchange)) (values nil :cancelled))
              (finished (values result nil))
              (t ;; Marked so a connect still in progress closes its socket.
               (setf (exchange-cancelled exchange) :timeout)
               (abandon-connection (exchange-socket exchange) name)
               (values nil :timeout)))))))

(defun cancel-exchange (exchange done name)
  (bt:with-lock-held ((exchange-lock exchange))
    (unless (exchange-finished exchange)
      (setf (exchange-cancelled exchange) t)
      (abandon-connection (exchange-socket exchange) name)
      (bt:signal-semaphore done))))

(defun close-socket (socket)
  (when socket (ignore-errors (usocket:socket-close socket))))

(defun abandon-connection (socket name)
  "Closing the socket from a thread of its own reliably wakes the worker's
blocked read."
  (when socket
    (bt:make-thread (lambda () (close-socket socket))
                    :name (format nil "~a-close" name))))

(defun open-connection (url exchange timeout-ms)
  (let* ((uri (puri:parse-uri url))
         (securep (eq (puri:uri-scheme uri) :https))
         (socket (with-immediate-connect-refusal
                   (usocket:socket-connect
                    (puri:uri-host uri) (or (puri:uri-port uri) (if securep 443 80))
                    :element-type '(unsigned-byte 8)
                    ;; Bounds the connect phase alone, ahead of the whole-
                    ;; exchange deadline.
                    :timeout (max 1 (ceiling timeout-ms 1000))
                    :nodelay :if-supported))))
    ;; A cancel that landed while connecting found no socket to close.
    (when (bt:with-lock-held ((exchange-lock exchange))
            (setf (exchange-socket exchange) socket)
            (exchange-cancelled exchange))
      (close-socket socket)
      (error "cancelled"))
    (wrap-http-stream socket (puri:uri-host uri) securep)))

(defun wrap-http-stream (socket host securep)
  "SOCKET's stream, wrapped exactly as drakma wraps one it opens itself:
chunked framing under a flexi-stream, with SSL attached first when
SECUREP. Passing :stream skips drakma's own wrapping entirely -- it only
adjusts the flexi-stream's element-type and external-format -- so a stream
given raw fails outright, and one without SSL attached sends a TLS
handshake in the clear."
  (let ((raw (usocket:socket-stream socket)))
    (flexi-streams:make-flexi-stream
     (chunga:make-chunked-stream
      (if securep
          (cl+ssl:make-ssl-client-stream raw :hostname host)
          raw))
     ;; Matches drakma's own +LATIN-1+ (specials.lisp), which is internal.
     :external-format (flexi-streams:make-external-format :latin-1 :eol-style :lf))))

;;; --- streamed turns ---------------------------------------------------

;;; The worker's deltas and the caller's :DONE reach the sink through one
;;; gate, so the sink sees exactly one :DONE and nothing after it, however
;;; the worker and the deadline race. A function sink is called from an
;;; emitter of its own, fed through a mailbox, so a sink that blocks never
;;; holds up the worker or the deadline.
;;;
;;; TODO: an emitter whose sink never returns outlives its turn. Upgrade
;;; path: abandon it at the deadline as the exchange's own thread is.
;;; Tracked in ~takeiteasy/nyaa#110.

(defstruct (sink-gate (:conc-name gate-))
  sink (lock (bt:make-lock)) closed relay (drained (bt:make-semaphore)))

(defun start-relay (gate)
  "Give GATE's function sink an emitter, which stops after delivering :DONE."
  (let ((sink (gate-sink gate))
        (drained (gate-drained gate)))
    (when (and sink (typep sink '(or function symbol)))
      (setf (gate-relay gate)
            (m:spawn (lambda ()
                       (unwind-protect
                            (loop for event = (m:receive)
                                  do (ignore-errors (emit-event sink event))
                                  until (eq :done (getf event :type)))
                         (bt:signal-semaphore drained)))
                     :name "nyaa-sink")))
    gate))

(defun gate-deliver (gate event)
  (if (gate-relay gate)
      (m:send (gate-relay gate) event)
      (emit-event (gate-sink gate) event)))

(defun gate-emitter (gate)
  (lambda (event)
    (bt:with-lock-held ((gate-lock gate))
      (unless (gate-closed gate)
        (gate-deliver gate event)))))

(defun close-gate (gate ref result &optional wait)
  "End the turn: emit its :DONE, then drop whatever the worker still sends.
WAIT, in seconds, bounds how long to wait for the sink to have seen it."
  (bt:with-lock-held ((gate-lock gate))
    (unless (gate-closed gate)
      (setf (gate-closed gate) t)
      (gate-deliver gate (done ref (done-reason result)))))
  (when (and wait (gate-relay gate))
    (bt:wait-on-semaphore (gate-drained gate) :timeout (max 0 wait))))

(defun done-reason (result)
  (if (tool-error-p result)
      result
      (getf (getf (second result) :meta) :finish-reason)))

(defun perform-completion (request opener reader)
  "Run the exchange on a worker thread bounded by the caller's deadline, as
TOOL-HTTP does: a wedged backend costs a timeout, not a wedged service. OPENER
takes (request connect) and answers (values stream status); READER takes
(request stream status) and answers the reply. A request with a :STREAM sink
ends it with exactly one :DONE."
  (let* ((sink (getf request :stream))
         (gate (start-relay (make-sink-gate :sink sink)))
         (timeout (getf request :timeout +default-tool-timeout+))
         (started (get-internal-real-time))
         (request (if sink
                      (list* :stream (gate-emitter gate) request)
                      request)))
    (multiple-value-bind (result reason)
        (call-with-deadline
         timeout
         (lambda (connect) (attempt-completion request opener reader connect))
         :name "nyaa-completion"
         :cancel (getf request :cancel))
      (let ((result (case reason
                      (:timeout (fail :timeout))
                      (:cancelled (fail :cancelled))
                      (t result))))
        (when sink
          (close-gate gate (getf request :ref) result
                      (unless reason
                        (- (/ timeout 1000)
                           (/ (- (get-internal-real-time) started)
                              internal-time-units-per-second)))))
        result))))

(defun attempt-completion (request opener reader connect)
  ;; The two failure regions are kept apart: nothing read yet is a transport
  ;; failure, and everything after the status is the backend misbehaving.
  (let (stream status)
    (handler-case
        (multiple-value-setq (stream status) (funcall opener request connect))
      ;; Nothing was read, so there is no backend answer to report on: a
      ;; refused connection and a peer that hangs up before the status line
      ;; are the same failure to the caller.
      (error () (return-from attempt-completion (fail :unavailable))))
    (unwind-protect
         (handler-case
             (if (<= 200 status 299)
                 (funcall reader request stream status)
                 (backend-error status (read-detail stream)))
           (error (e) (backend-error status (princ-to-string e))))
      (ignore-errors (close stream)))))

(defun character-stream (stream)
  "STREAM as UTF-8 characters. Drakma leaves the stream it was given in the
external format of the response's content type, which is Latin-1 unless the
type names a charset."
  (if (typep stream 'flexi-streams:flexi-stream)
      (progn
        (setf (flexi-streams:flexi-stream-external-format stream)
              (flexi-streams:make-external-format :utf-8 :eol-style :lf)
              (flexi-streams:flexi-stream-element-type stream) 'character)
        stream)
      (flexi-streams:make-flexi-stream stream :external-format :utf-8)))

(defun read-detail (stream)
  "An error response's body, for the detail of a (:backend-error ...)."
  (or (ignore-errors (uiop:slurp-stream-string stream)) ""))

(defun make-reply (text calls reason meta)
  (list :ok (list :role :assistant
                  :content (when (plusp (length text)) (normalize-content text))
                  :tool-calls calls
                  :done t
                  :meta (list* :finish-reason reason meta))))

(defun finish-reason (value)
  "A wire finish/done reason as a keyword: tool_calls is :TOOL-CALLS."
  (when (stringp value) (lisp-key value)))

(defun text-of (value)
  (if (stringp value) value ""))

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
