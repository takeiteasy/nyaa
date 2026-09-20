(in-package #:nyaa)

;;; The OpenAI chat completions wire shape: POST <base-url>/chat/completions,
;;; with optional SSE streaming. One protocol for every backend speaking it --
;;; OpenRouter, Ollama, Groq, vLLM, LM Studio, llama.cpp-server -- which differ
;;; only in provider data. See docs/protocols.md.
;;;
;;; Base URL, model and auth travel in the request rather than in a config
;;; slot: one mounted service answers for every backend of the shape at once.
;;;
;;; TODO: a completion abandoned at its deadline leaves its reader thread
;;; blocked on a socket that may never close, holding a stream rather than a
;;; single response. Upgrade path: drive the socket directly so the deadline
;;; can close it. Tracked in ~takeiteasy/nyaa#34.

(defparameter +openai-params+
  '((:temperature number :doc "sampling temperature")
    (:top-p number :doc "nucleus sampling cutoff")
    (:max-tokens (integer 1) :doc "cap on generated tokens")
    (:stop (array-of string) :doc "sequences that end the turn")
    (:seed integer :doc "sampling seed, where the backend honours one"))
  "The sampling parameters the shape understands, advertised and rendered
from one declaration.")

(m:defservice protocol-openai () ()
  (:name :protocol-openai))

(defmethod m:metadata ((service protocol-openai))
  (list :kind :protocol
        :name :protocol-openai
        :summary "OpenAI-compatible chat completions"
        :params +openai-params+))

(define-protocol-handler protocol-openai (service request)
  (let ((problem (check-openai-request request)))
    (if problem
        (bad-request "~a" problem)
        (perform-completion request))))

(defun check-openai-request (request)
  "NIL when REQUEST carries the provider data this protocol needs, else a
problem string. The shared CHECK-REQUEST stays neutral, so this runs on top."
  (let ((base-url (getf request :base-url))
        (model (getf request :model)))
    (cond
      ((not (named-p base-url)) ":base-url is required, naming the backend")
      ((not (http-url-p base-url)) ":base-url must be an http or https URL")
      ((not (named-p model)) ":model is required")
      (t nil))))

(defun named-p (value)
  (and (stringp value) (plusp (length value))))

(defun http-url-p (url)
  ;; Checked here so that everything past it failing before a status line is
  ;; a transport failure and nothing else.
  (some (lambda (scheme)
          (and (>= (length url) (length scheme))
               (string-equal scheme url :end2 (length scheme))))
        '("http://" "https://")))

;;; --- names and keys ---------------------------------------------------

(defun wire-key (name)
  "NAME as a JSON property name: :MAX-TOKENS is max_tokens."
  (substitute #\_ #\- (string-downcase (symbol-name name))))

(defun wire-tool-name (name)
  (string-downcase (symbol-name name)))

(defun lisp-tool-name (name)
  (a:make-keyword (string-upcase name)))

(defun lisp-key (key)
  (a:make-keyword (string-upcase (substitute #\- #\_ key))))

(defun completion-url (base-url)
  (format nil "~a/chat/completions" (string-right-trim "/" base-url)))

;;; --- values -----------------------------------------------------------

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

;;; --- the request ------------------------------------------------------

(defun completion-body (request streaming)
  (let* ((tools (getf request :tools))
         (json (json-object "model" (getf request :model)
                            "messages" (map 'vector
                                            (lambda (message)
                                              (message->json message tools))
                                            (getf request :messages))
                            "stream" streaming)))
    (when tools
      (setf (gethash "tools" json) (tools->json tools)))
    (dolist (param +openai-params+ json)
      (let ((value (getf request (param-name param) *absent*)))
        (unless (eq value *absent*)
          (setf (gethash (wire-key (param-name param)) json)
                (value->json value (param-type param))))))))

(defun message->json (message tools)
  (let* ((role (getf message :role))
         (content (getf message :content))
         (json (json-object "role" (string-downcase (symbol-name role))
                            ;; Null, not "": an assistant turn that is only
                            ;; tool calls carries no content at all.
                            "content" (if content (content-text content) 'null))))
    (when (eq role :tool)
      (setf (gethash "tool_call_id" json) (getf message :tool-call-id)))
    (a:when-let ((calls (getf message :tool-calls)))
      (setf (gethash "tool_calls" json)
            (map 'vector (lambda (call) (tool-call->json call tools)) calls)))
    json))

(defun tool-call->json (call tools)
  (let ((name (getf call :name)))
    (json-object
     "id" (getf call :id)
     "type" "function"
     "function" (json-object
                 "name" (wire-tool-name name)
                 "arguments" (json:stringify
                              (arguments->json (getf call :arguments)
                                               (call-schema name tools)))))))

;;; Each tool's schema renders straight through SCHEMA->JSON-SCHEMA. A shared
;;; renderer waits for a second protocol to want the same one (#33).

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

;;; --- the exchange -----------------------------------------------------

(defun perform-completion (request)
  "Run the exchange on a worker thread bounded by the caller's deadline, as
TOOL-HTTP does: a wedged backend costs a timeout, not a wedged service."
  (let ((result nil)
        (done (bt:make-semaphore)))
    (bt:make-thread
     (lambda ()
       (unwind-protect
            (setf result (attempt-completion request))
         (bt:signal-semaphore done)))
     :name "nyaa-openai-completion")
    (if (bt:wait-on-semaphore
         done :timeout (/ (getf request :timeout +default-tool-timeout+) 1000))
        result
        (fail :timeout))))

(defun attempt-completion (request)
  ;; The two failure regions are kept apart: nothing read yet is a transport
  ;; failure, and everything after the status is the backend misbehaving.
  (let (stream status)
    (handler-case
        (multiple-value-setq (stream status) (open-completion request))
      ;; Nothing was read, so there is no backend answer to report on: a
      ;; refused connection and a peer that hangs up before the status line
      ;; are the same failure to the caller.
      (error () (return-from attempt-completion (fail :unavailable))))
    (unwind-protect
         (handler-case
             (if (<= 200 status 299)
                 (read-completion request stream status)
                 (backend-error status (read-detail stream)))
           (error (e) (backend-error status (princ-to-string e))))
      (ignore-errors (close stream)))))

(defun open-completion (request)
  "POST the request body, answering the response stream and its status."
  (let ((streaming (and (getf request :stream) t)))
    (multiple-value-bind (body status)
        (drakma:http-request
         (completion-url (getf request :base-url))
         :method :post
         :redirect nil
         :want-stream t
         :additional-headers (header-alist (getf request :headers))
         :content-type "application/json"
         :content (json:stringify (completion-body request streaming)))
      (values (character-stream body) status))))

(defun character-stream (stream)
  "STREAM as characters. Drakma decodes a content type it knows to be textual
and leaves the rest as octets."
  (if (subtypep (stream-element-type stream) 'character)
      stream
      (flexi-streams:make-flexi-stream stream :external-format :utf-8)))

(defun read-detail (stream)
  "An error response's body, for the detail of a (:backend-error ...)."
  (or (ignore-errors (uiop:slurp-stream-string stream)) ""))

(defun read-completion (request stream status)
  (if (getf request :stream)
      (read-streamed-completion request stream status)
      (read-whole-completion request stream status)))

;;; --- the reply --------------------------------------------------------

(defun make-reply (text calls reason meta)
  (list :ok (list :role :assistant
                  :content (when (plusp (length text)) (normalize-content text))
                  :tool-calls calls
                  :done t
                  :meta (list* :finish-reason reason meta))))

(defun finish-reason (value)
  "A wire finish_reason as a keyword: tool_calls is :TOOL-CALLS."
  (when (stringp value) (lisp-key value)))

(defun reply-meta (json)
  (let ((meta '()))
    (a:when-let ((id (gethash "id" json)))
      (when (stringp id) (setf meta (list :id id))))
    (a:when-let ((usage (gethash "usage" json)))
      (when (hash-table-p usage)
        (setf meta (list* :usage (json->arguments usage nil) meta))))
    meta))

(defun read-whole-completion (request stream status)
  (let* ((json (json:parse (uiop:slurp-stream-string stream)))
         (choice (first-choice json status))
         (message (gethash "message" choice)))
    (unless (hash-table-p message)
      (return-from read-whole-completion
        (backend-error status "a choice carries no message")))
    (make-reply (text-of (gethash "content" message))
                (message-tool-calls message (getf request :tools))
                (finish-reason (gethash "finish_reason" choice))
                (reply-meta json))))

(defun first-choice (json status)
  (let ((choices (gethash "choices" json)))
    (unless (and (vectorp choices) (plusp (length choices)))
      (error "no choices in a ~d response" status))
    (aref choices 0)))

(defun text-of (value)
  (if (stringp value) value ""))

(defun message-tool-calls (message tools)
  (let ((calls (gethash "tool_calls" message)))
    (when (and (vectorp calls) (not (stringp calls)))
      (map 'list (lambda (call) (wire-call->lisp call tools)) calls))))

(defun wire-call->lisp (call tools)
  (let* ((function (gethash "function" call))
         (name (lisp-tool-name (gethash "name" function))))
    (list :id (gethash "id" call)
          :name name
          :arguments (parse-arguments (gethash "arguments" function)
                                      (call-schema name tools)))))

(defun parse-arguments (text schema)
  "TEXT, a JSON object as a string, as an argument plist. An empty argument
list arrives as \"\" as readily as \"{}\"."
  (if (or (null text) (zerop (length text)))
      nil
      (json->arguments (json:parse text) schema)))

;;; --- streaming --------------------------------------------------------

;;; Deltas accumulate into the same reply the whole-response path returns, so
;;; a caller may ignore the sink entirely and read only the (:ok ...).

(defstruct (streamed-call (:conc-name call-))
  id name (arguments (make-string-output-stream)))

(defun read-streamed-completion (request stream status)
  (let ((sink (getf request :stream))
        (ref (getf request :ref))
        (text (make-string-output-stream))
        (calls '())
        (reason nil)
        (meta '())
        (ended nil))
    (loop
      (multiple-value-bind (data eof) (read-sse-event stream)
        (when data
          (if (string= data "[DONE]")
              (setf ended t)
              (let ((chunk (json:parse data)))
                (setf meta (or (reply-meta chunk) meta))
                (multiple-value-setq (calls reason ended)
                  (absorb-chunk chunk sink ref text calls reason ended)))))
        (when (or eof ended) (return))))
    ;; Neither a [DONE] nor a finish_reason means the stream stopped early.
    (unless ended
      (return-from read-streamed-completion
        (backend-error status "the stream ended before the turn did")))
    (emit-event sink (done ref reason))
    (make-reply (get-output-stream-string text)
                (streamed-calls calls (getf request :tools))
                reason meta)))

(defun absorb-chunk (chunk sink ref text calls reason ended)
  (let ((choices (gethash "choices" chunk)))
    (when (and (vectorp choices) (plusp (length choices)))
      (let* ((choice (aref choices 0))
             (delta (gethash "delta" choice))
             (finish (finish-reason (gethash "finish_reason" choice))))
        (when finish (setf reason finish ended t))
        (when (hash-table-p delta)
          (a:when-let ((content (gethash "content" delta)))
            (when (and (stringp content) (plusp (length content)))
              (write-string content text)
              (emit-event sink (text-delta ref content))))
          (let ((fragments (gethash "tool_calls" delta)))
            (when (and (vectorp fragments) (not (stringp fragments)))
              (map nil (lambda (fragment)
                         (setf calls (absorb-call fragment sink ref calls)))
                   fragments)))))))
  (values calls reason ended))

(defun absorb-call (fragment sink ref calls)
  "One tool_calls fragment. Id and name reach the wire on the first fragment
of an index only; both are remembered and stamped on every delta, so a
consumer of the sink alone reassembles without tracking arrival order."
  (let* ((index (or (gethash "index" fragment) 0))
         (call (or (cdr (assoc index calls))
                   (let ((fresh (make-streamed-call)))
                     (setf calls (append calls (list (cons index fresh))))
                     fresh)))
         (function (gethash "function" fragment))
         (arguments (and (hash-table-p function)
                         (gethash "arguments" function))))
    (a:when-let ((id (gethash "id" fragment)))
      (when (stringp id) (setf (call-id call) id)))
    (when (hash-table-p function)
      (a:when-let ((name (gethash "name" function)))
        (when (stringp name) (setf (call-name call) (lisp-tool-name name)))))
    (when (stringp arguments)
      (write-string arguments (call-arguments call)))
    (emit-event sink (tool-call-delta ref
                                      :id (call-id call)
                                      :name (call-name call)
                                      :arguments (if (stringp arguments)
                                                     arguments
                                                     "")))
    calls))

(defun streamed-calls (calls tools)
  (loop for (nil . call) in calls
        collect (list :id (call-id call)
                      :name (call-name call)
                      :arguments (parse-arguments
                                  (get-output-stream-string (call-arguments call))
                                  (call-schema (call-name call) tools)))))

;;; --- SSE --------------------------------------------------------------

(defun read-sse-event (stream)
  "The next event's data payload and T at end of stream. Fields other than
data, and the comment lines a backend sends to keep a connection warm, are
skipped; an event's several data lines join with a newline."
  (let ((data '()))
    (loop
      (let ((line (read-line stream nil nil)))
        (cond
          ((null line) (return (values (join-data data) t)))
          (t (let ((field (string-right-trim '(#\Return) line)))
               (cond
                 ((string= field "")
                  (when data (return (values (join-data data) nil))))
                 ((sse-data-p field)
                  (push (string-left-trim " " (subseq field 5)) data))))))))))

(defun sse-data-p (field)
  (and (>= (length field) 5) (string= "data:" field :end2 5)))

(defun join-data (data)
  (when data
    (format nil "~{~a~^~%~}" (reverse data))))
