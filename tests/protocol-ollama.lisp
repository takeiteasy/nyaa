(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; Ollama's native protocol against the fake HTTP backend: the /api/chat
;;; request shape, the flat reply and its counters, NDJSON streaming, and the
;;; one ordering trap -- the counters arrive only on the final done:true line.

(defun call-with-ollama (answer body)
  (let* ((registry (make-instance 'm:registry))
         (m:*registry* registry)
         (context (m:start-service (make-instance 'm:context :name :protocols)
                                   :registry registry))
         (server (start-fake-http
                  (lambda (&rest request)
                    (if (functionp answer) (apply answer request) answer)))))
    (setf *backend* server)
    (unwind-protect
         (progn (m:mount context 'nyaa:protocol-ollama)
                (funcall body))
      (m:stop context)
      (stop-fake-http server))))

(defmacro with-ollama ((answer) &body body)
  `(call-with-ollama ,answer (lambda () ,@body)))

(defun ask-ollama (&rest extra)
  (apply #'nyaa:complete :protocol-ollama
         :base-url (fake-http-url *backend*)
         :model "test-model"
         :messages '((:role :user :content "hello"))
         extra))

(defparameter +hello-chat-reply+
  "{\"model\":\"llama3.2\",
    \"message\":{\"role\":\"assistant\",\"content\":\"hi there\"},
    \"done\":true,\"done_reason\":\"stop\",
    \"prompt_eval_count\":26,\"eval_count\":298,
    \"total_duration\":4883583458,\"load_duration\":1073398416,
    \"prompt_eval_duration\":132000000,\"eval_duration\":3678000000}")

;;; --- the convention -----------------------------------------------------

(test ollama-is-discoverable-and-describes-itself
  (with-ollama ((json-response +hello-chat-reply+))
    (is (equal '(:protocol-ollama) (nyaa:protocols)))
    (let ((metadata (nyaa:describe-protocol :protocol-ollama)))
      (is (eq :protocol (getf metadata :kind)))
      (is (stringp (getf metadata :summary))))))

;;; --- the request ----------------------------------------------------------

(test the-request-goes-to-api-chat
  (with-ollama ((json-response +hello-chat-reply+))
    (is (eq :ok (first (ask-ollama))))
    (let ((request (first (fake-http-requests *backend*))))
      (is (equal "POST" (getf request :method)))
      (is (equal "/api/chat" (getf request :path))))))

(test sampling-parameters-nest-under-options
  (with-ollama ((json-response +hello-chat-reply+))
    (ask-ollama :temperature 0.2 :num-ctx 8192)
    (let* ((body (sent-body))
           (options (gethash "options" body)))
      (is (= 0.2d0 (gethash "temperature" options)))
      (is (= 8192 (gethash "num_ctx" options)))
      ;; Not top-level: the sampling knobs are grouped.
      (is (null (nth-value 1 (gethash "temperature" body)))))))

(test format-and-keep-alive-stay-top-level
  (with-ollama ((json-response +hello-chat-reply+))
    (ask-ollama :format "json" :keep-alive "5m")
    (let ((body (sent-body)))
      (is (equal "json" (gethash "format" body)))
      (is (equal "5m" (gethash "keep_alive" body)))
      (is (null (nth-value 1 (gethash "options" body)))))))

(test an-absent-param-is-absent-from-the-body
  (with-ollama ((json-response +hello-chat-reply+))
    (ask-ollama)
    (is (null (nth-value 1 (gethash "options" (sent-body)))))))

(test tools-render-the-same-as-the-openai-protocol
  (with-ollama ((json-response +hello-chat-reply+))
    (ask-ollama :tools (list (list :name :tool-demo
                                   :summary "A demo tool"
                                   :params '((:cmd string :required t :doc "the command")))))
    (let* ((tool (aref (gethash "tools" (sent-body)) 0))
           (function (gethash "function" tool)))
      (is (equal "function" (gethash "type" tool)))
      (is (equal "tool-demo" (gethash "name" function)))
      (is (equal "A demo tool" (gethash "description" function))))))

(test a-sent-tool-call-carries-its-arguments-as-an-object
  (with-ollama ((json-response +hello-chat-reply+))
    (nyaa:complete
     :protocol-ollama
     :base-url (fake-http-url *backend*)
     :model "test-model"
     :messages '((:role :user :content "go")
                 (:role :assistant :content nil
                  :tool-calls ((:id "c1" :name :tool-shell :arguments (:cmd "ls"))))))
    (let* ((messages (gethash "messages" (sent-body)))
           (call (aref (gethash "tool_calls" (aref messages 1)) 0))
           (arguments (gethash "arguments" (gethash "function" call))))
      ;; An object, not a stringified one: JZON parses it straight to a hash
      ;; table, unlike the OpenAI protocol's "{\"cmd\":\"ls\"}".
      (is (hash-table-p arguments))
      (is (equal "ls" (gethash "cmd" arguments))))))

;;; --- the reply --------------------------------------------------------

(test a-reply-becomes-the-neutral-shape-with-native-counters
  (with-ollama ((json-response +hello-chat-reply+))
    (let ((reply (second (ask-ollama))))
      (is (eq :assistant (getf reply :role)))
      (is (eq t (getf reply :done)))
      (is (equal "hi there" (nyaa:content-text (getf reply :content))))
      (is (eq :stop (getf (getf reply :meta) :finish-reason)))
      (let ((usage (getf (getf reply :meta) :usage)))
        (is (= 26 (getf usage :prompt-eval-count)))
        (is (= 298 (getf usage :eval-count)))
        (is (= 4883583458 (getf usage :total-duration)))
        (is (= 1073398416 (getf usage :load-duration)))))))

(test a-tool-call-comes-back-with-a-synthesised-id
  (with-ollama ((json-response
                  "{\"message\":{\"role\":\"assistant\",\"content\":\"\",
                     \"tool_calls\":[{\"function\":{\"name\":\"tool-shell\",
                       \"arguments\":{\"cmd\":\"ls -l\"}}}]},
                    \"done\":true,\"done_reason\":\"tool_calls\"}"))
    (let* ((reply (second (ask-ollama)))
           (call (first (getf reply :tool-calls))))
      (is (eq :tool-calls (getf (getf reply :meta) :finish-reason)))
      (is (equal "call_0" (getf call :id)))
      (is (eq :tool-shell (getf call :name)))
      (is (equal "ls -l" (getf (getf call :arguments) :cmd))))))

(test a-tool-call-round-trips-back-through-complete
  ;; Parse a native reply with two calls, then feed the reply's own
  ;; tool-calls and matching tool-role messages straight back in: the
  ;; synthesised ids must correlate, not merely exist, and CHECK-REQUEST's
  ;; own :id/:name requirement must be satisfied by them.
  (with-ollama ((json-response
                  "{\"message\":{\"role\":\"assistant\",\"content\":\"\",
                     \"tool_calls\":[{\"function\":{\"name\":\"tool-shell\",\"arguments\":{\"cmd\":\"ls\"}}},
                                     {\"function\":{\"name\":\"tool-shell\",\"arguments\":{\"cmd\":\"pwd\"}}}]},
                    \"done\":true,\"done_reason\":\"tool_calls\"}"))
    (let* ((reply (second (ask-ollama)))
           (calls (getf reply :tool-calls)))
      (is (= 2 (length calls)))
      (is (equal '("call_0" "call_1") (mapcar (lambda (c) (getf c :id)) calls)))
      (let ((tool-messages (mapcar (lambda (c)
                                     (list :role :tool
                                           :tool-call-id (getf c :id)
                                           :content "ok"))
                                   calls))
            (assistant-turn (list :role :assistant :content nil :tool-calls calls)))
        (let ((followup-request
                (list :messages
                      (list* '(:role :user :content "list, then pwd")
                             assistant-turn tool-messages))))
          (is (null (nyaa:check-request followup-request)))
          (is (eq :ok (first (apply #'nyaa:complete :protocol-ollama
                                    :base-url (fake-http-url *backend*)
                                    :model "test-model"
                                    followup-request)))))))))

;;; --- streaming --------------------------------------------------------

(defun collect-ollama-stream (&rest extra)
  (let* ((events '())
         (result (apply #'ask-ollama :ref :r1
                        :stream (lambda (event) (push event events))
                        extra)))
    (values (nreverse events) result)))

(test text-deltas-reach-the-sink-and-the-reply
  (with-ollama ((ndjson-response
                 "{\"message\":{\"role\":\"assistant\",\"content\":\"hi \"},\"done\":false}"
                 "{\"message\":{\"role\":\"assistant\",\"content\":\"there\"},\"done\":false}"
                 "{\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\",\"prompt_eval_count\":3,\"eval_count\":2}"))
    (multiple-value-bind (events result) (collect-ollama-stream)
      (is (equal '(:text-delta :text-delta :done)
                 (mapcar (lambda (event) (getf event :type)) events)))
      (is (equal "hi " (getf (first events) :text)))
      (is (eq :stop (getf (third events) :reason)))
      (is (equal "hi there" (nyaa:content-text (getf (second result) :content))))
      ;; The counters arrive only on the final line, and must still land.
      (is (= 3 (getf (getf (getf (second result) :meta) :usage) :prompt-eval-count)))
      (is (eq t (gethash "stream" (sent-body)))))))

(test a-stream-ending-at-eof-without-done-is-a-backend-error
  (with-ollama ((ndjson-response
                 "{\"message\":{\"role\":\"assistant\",\"content\":\"partial\"},\"done\":false}"))
    (multiple-value-bind (events result) (collect-ollama-stream)
      (declare (ignore events))
      (is (eq :backend-error (first (nyaa:tool-error result)))))))

;;; --- errors -----------------------------------------------------------

(test a-non-ok-status-is-a-backend-error
  (with-ollama ('(429 ("Content-Type" "application/json")
                  "{\"error\":\"rate limited\"}")
                )
    (let ((reason (nyaa:tool-error (ask-ollama))))
      (is (eq :backend-error (first reason)))
      (is (= 429 (second reason))))))

(test a-connection-closed-before-a-response-is-unavailable
  (with-ollama (:close)
    (is (eq :unavailable (nyaa:tool-error (ask-ollama))))))

(test an-unreachable-backend-is-unavailable
  (with-ollama ((json-response +hello-chat-reply+))
    (is (eq :unavailable
            (nyaa:tool-error
             (nyaa:complete :protocol-ollama
                            :base-url "http://127.0.0.1:1"
                            :model "test-model"
                            :timeout 5000
                            :messages '((:role :user :content "hello"))))))))

;;; --- live -------------------------------------------------------------

;;; A separate variable from NYAA_OLLAMA_URL, which the OpenAI protocol's live
;;; tests point at the /v1 route.

(test ollama-live-completion
  (let ((base-url (uiop:getenv "NYAA_OLLAMA_NATIVE_URL"))
        (model (or (uiop:getenv "NYAA_OLLAMA_MODEL") "llama3.2")))
    (if (null base-url)
        (skip "set NYAA_OLLAMA_NATIVE_URL to run live native Ollama tests")
        (let* ((registry (make-instance 'm:registry))
               (m:*registry* registry)
               (context (m:start-service (make-instance 'm:context :name :live)
                                         :registry registry)))
          (unwind-protect
               (progn
                 (m:mount context 'nyaa:protocol-ollama)
                 (let ((result (nyaa:complete
                                :protocol-ollama :base-url base-url :model model
                                :timeout 120000 :num-ctx 2048
                                :messages '((:role :user
                                             :content "Reply with the word ok.")))))
                   (if (model-missing-p result)
                       (skip "~a has no model ~a; set NYAA_OLLAMA_MODEL" base-url model)
                       (progn
                         (is (eq :ok (first result)))
                         (is (plusp (length (nyaa:content-text
                                             (getf (second result) :content)))))
                         (is (getf (getf (second result) :meta) :usage))))))
            (m:stop context))))))
