(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; The agent loop against the fake HTTP backend and the provider harness
;;; PROVIDER.LISP set up: allow-list resolution, the tool round trip,
;;; budgets, steering, cancellation, sub-agents and the event stream.

;;; Two :TRUST :AGENT tools -- nothing shipped is that trust level, so the
;;; default allow-list needs at least one to be non-empty in a test.

(m:defservice tool-echo () () (:name :tool-echo))

(defmethod m:metadata ((service tool-echo))
  (list :kind :tool :name :tool-echo :trust :agent
        :summary "Echo TEXT back"
        :params '((:text string :required t :doc "text to echo"))))

(nyaa::define-tool-handler tool-echo (service args)
  (nyaa::ok :text (getf args :text)))

(m:defservice tool-boom () () (:name :tool-boom))

(defmethod m:metadata ((service tool-boom))
  (list :kind :tool :name :tool-boom :trust :agent
        :summary "Always fails" :params nil))

(nyaa::define-tool-handler tool-boom (service args)
  args
  (nyaa::fail (list :error "boom")))

;;; Holds a call in flight long enough to cancel or snapshot around it.

(m:defservice tool-hold () () (:name :tool-hold))

(defmethod m:metadata ((service tool-hold))
  (list :kind :tool :name :tool-hold :trust :agent
        :summary "Hold the call open, then answer" :params nil))

(nyaa::define-tool-handler tool-hold (service args)
  args
  (sleep 0.5)
  (nyaa::ok :slept t))

;;; --- the harness --------------------------------------------------------

(defun call-with-agent (answer tool-classes body)
  "Like WITH-PROVIDERS, plus the tools TOOL-CLASSES names mounted alongside
the keyed provider, ready for RUN-AGENT."
  (let* ((registry (make-instance 'm:registry))
         (m:*registry* registry)
         (context (m:start-service (make-instance 'm:context :name :agents)
                                   :registry registry))
         (server (start-fake-http
                  (lambda (&rest request)
                    (if (functionp answer) (apply answer request) answer)))))
    (setf *backend* server)
    (unwind-protect
         (progn
           (m:mount context 'nyaa:protocol-openai)
           (m:mount context 'nyaa:protocol-ollama)
           (let ((mount (keyed)))
             (apply #'m:mount context (first mount)
                    :base-url (fake-http-url server) (rest mount)))
           (dolist (class tool-classes) (m:mount context class))
           (funcall body context))
      (m:stop context)
      (stop-fake-http server))))

(defmacro with-agent ((answer &rest tool-classes) &body body)
  `(call-with-agent ,answer (list ,@tool-classes) (lambda (*ctx*) ,@body)))

(defvar *ctx* nil "The running context, bound by WITH-AGENT.")

(defun agent-turn (&rest extra)
  (apply #'nyaa:run-agent *ctx* :model :provider-test-keyed extra))

(defun requests () (fake-http-requests *backend*))

(defun request-tool-names (n)
  "The `name`s in request N's (1-based) `tools` array."
  (let ((body (com.inuoe.jzon:parse (getf (nth (1- n) (requests)) :body))))
    (map 'list (lambda (tool) (gethash "name" (gethash "function" tool)))
         (gethash "tools" body))))

(defun tool-call-reply (id name arguments-json)
  "ARGUMENTS-JSON is the call's arguments as already-encoded JSON text,
matching the wire's own doubly-encoded shape (a JSON string holding a JSON
object)."
  (json-response
   (format nil "{\"choices\":[{\"message\":{\"role\":\"assistant\",
     \"tool_calls\":[{\"id\":\"~a\",\"type\":\"function\",
       \"function\":{\"name\":\"~a\",\"arguments\":~s}}]},
     \"finish_reason\":\"tool_calls\"}]}"
           id name arguments-json)))

(defun final-reply (text)
  (json-response
   (format nil "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":~a},
     \"finish_reason\":\"stop\"}]}"
           (com.inuoe.jzon:stringify text))))

;;; --- the happy path -----------------------------------------------------

(test a-turn-with-no-tool-calls-finishes-stop
  (with-agent ((final-reply "hi there"))
    (let ((result (agent-turn :messages '((:role :user :content "hello")))))
      (is (eq :ok (first result)))
      (is (eq :stop (getf (second result) :stop-reason)))
      (is (= 1 (getf (second result) :turns)))
      (is (equal "hi there" (nyaa:content-text (getf (second result) :content))))
      (is (= 1 (length (requests)))))))

(test a-tool-call-round-trips-and-the-run-continues
  (let ((n 0))
    (with-agent ((lambda (&rest request)
                   (declare (ignore request))
                   (if (= 0 (incf n))
                       nil
                       (if (= n 1)
                           (tool-call-reply "c1" "tool-echo" "{\"text\":\"hi\"}")
                           (final-reply "done"))))
                'tool-echo)
      (let ((result (agent-turn :messages '((:role :user :content "go")))))
        (is (eq :ok (first result)))
        (is (eq :stop (getf (second result) :stop-reason)))
        (is (= 2 (length (requests))))
        (let ((tool-message (find :tool (getf (second result) :messages)
                                  :key (lambda (m) (getf m :role)))))
          (is (equal "c1" (getf tool-message :tool-call-id)))
          (is (search "hi" (nyaa:content-text (getf tool-message :content)))))))))

(test a-disallowed-tool-comes-back-as-a-tool-message
  (let ((n 0))
    (with-agent ((lambda (&rest request)
                   (declare (ignore request))
                   (incf n)
                   (if (= n 1)
                       (tool-call-reply "c1" "tool-boom" "{}")
                       (final-reply "recovered")))
                'tool-echo)
      ;; tool-boom is mounted but not in the allow-list, so it fails as
      ;; "not allowed" without ever reaching the tool.
      (let ((result (agent-turn :messages '((:role :user :content "go"))
                                :tools '(:tool-echo))))
        (is (eq :ok (first result)))
        (is (eq :stop (getf (second result) :stop-reason)))
        (let ((tool-message (find :tool (getf (second result) :messages)
                                  :key (lambda (m) (getf m :role)))))
          (is (search "error" (nyaa:content-text (getf tool-message :content)))))))))

(test an-erroring-tool-comes-back-as-a-tool-message-and-the-run-continues
  (let ((n 0))
    (with-agent ((lambda (&rest request)
                   (declare (ignore request))
                   (incf n)
                   (if (= n 1)
                       (tool-call-reply "c1" "tool-boom" "{}")
                       (final-reply "recovered")))
                'tool-boom)
      (let ((result (agent-turn :messages '((:role :user :content "go"))
                                :tools '(:tool-boom))))
        (is (eq :ok (first result)))
        (is (eq :stop (getf (second result) :stop-reason)))
        (is (= 2 (length (requests))))
        (let ((tool-message (find :tool (getf (second result) :messages)
                                  :key (lambda (m) (getf m :role)))))
          (is (search "boom" (nyaa:content-text (getf tool-message :content)))))))))

;;; --- the allow-list -----------------------------------------------------

(test the-allow-list-is-what-reaches-the-wire
  (with-agent ((final-reply "hi") 'tool-echo 'tool-boom)
    (agent-turn :messages '((:role :user :content "hi")) :tools '(:tool-echo))
    (is (equal '("tool-echo") (request-tool-names 1)))))

(test the-default-allow-list-is-the-trust-agent-tools
  (with-agent ((final-reply "hi") 'tool-echo 'tool-boom)
    (agent-turn :messages '((:role :user :content "hi")))
    (is (equal '("tool-boom" "tool-echo") (sort (request-tool-names 1) #'string<)))))

;;; --- budgets --------------------------------------------------------

(test max-turns-stops-a-model-that-keeps-calling-tools
  (with-agent ((lambda (&rest request)
                 (declare (ignore request))
                 (tool-call-reply "c1" "tool-echo" "{\"text\":\"again\"}"))
              'tool-echo)
    (let ((result (agent-turn :messages '((:role :user :content "go"))
                              :tools '(:tool-echo) :max-turns 2)))
      (is (eq :ok (first result)))
      (is (eq :max-turns (getf (second result) :stop-reason)))
      (is (= 2 (getf (second result) :turns))))))

(test deadline-stops-a-slow-model
  (with-agent ((lambda (&rest request)
                 (declare (ignore request))
                 (sleep 0.3)
                 (final-reply "too late")))
    (let ((result (agent-turn :messages '((:role :user :content "go"))
                              :deadline 100 :timeout 5)))
      (is (eq :ok (first result)))
      (is (eq :timeout (getf (second result) :stop-reason))))))

;;; --- cancel and steer ---------------------------------------------------

(test cancel-mid-run-finishes-cancelled
  (with-agent ((lambda (&rest request)
                 (declare (ignore request))
                 (sleep 0.3)
                 (final-reply "too late")))
    (m:with-process (runner)
      (let ((child (m:delegate *ctx* 'nyaa:agent :model :provider-test-keyed)))
        (m:cast child (list :run :messages '((:role :user :content "go"))))
        (m:cast child '(:cancel))
        (multiple-value-bind (message received) (m:receive :timeout 5)
          (is-true received)
          (is (eq :agent-done (first message)))
          (is (eq :cancelled (getf (second (fourth message)) :stop-reason))))))))

(test cancel-stops-the-completion-in-flight
  ;; The backend never finishes its answer, so the turn's thread can only
  ;; end because :cancel closed its connection.
  (with-agent ((stalled-stream "application/json" "{\"choices\":["))
    (with-hold
      (m:with-process (runner)
        (let ((child (m:delegate *ctx* 'nyaa:agent :model :provider-test-keyed
                                 :turn-timeout 30000)))
          (m:cast child (list :run :messages '((:role :user :content "go"))))
          (is-true (eventually (lambda () (stream-threads))))
          (m:cast child '(:cancel))
          (multiple-value-bind (message received) (m:receive :timeout 5)
            (is-true received)
            (is (eq :cancelled (getf (second (fourth message)) :stop-reason))))
          (is-true (eventually (lambda () (null (stream-threads))))))))))

(test steer-reaches-the-next-request
  (let ((n 0))
    (with-agent ((lambda (&rest request)
                   (declare (ignore request))
                   (incf n)
                   (if (= n 1)
                       (tool-call-reply "c1" "tool-echo" "{\"text\":\"hi\"}")
                       (final-reply "done")))
                'tool-echo)
      (m:with-process (runner)
        (let ((child (m:delegate *ctx* 'nyaa:agent :model :provider-test-keyed
                                 :tools '(:tool-echo))))
          (m:cast child (list :run :messages '((:role :user :content "go"))))
          (m:cast child (list :steer :content "also do this"))
          (multiple-value-bind (message received) (m:receive :timeout 5)
            (is-true received)
            (is (eq :agent-done (first message)))
            (is (find "also do this" (getf (second (fourth message)) :messages)
                     :key (lambda (m) (nyaa:content-text (getf m :content)))
                     :test #'equal))))))))

(test cancel-mid-tool-call-closes-the-call
  ;; A sink makes the request stream, so the backend answers in SSE.
  (with-agent ((sse-response
                "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"tool-hold\",\"arguments\":\"{}\"}}]}}]}"
                "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}"
                "[DONE]")
               'tool-hold)
    (m:with-process (runner)
      (let* ((events '())
             (child (m:delegate *ctx* 'nyaa:agent :model :provider-test-keyed
                                :tools '(:tool-hold)
                                :sink (lambda (event) (push event events)))))
        (m:cast child (list :run :messages '((:role :user :content "go"))))
        (loop repeat 100
              until (getf (getf (m:call child '(:snapshot)) :in-flight) :tool-calls)
              do (sleep 0.02))
        (m:cast child '(:cancel))
        (multiple-value-bind (message received) (m:receive :timeout 5)
          (is-true received)
          (let* ((messages (getf (second (fourth message)) :messages))
                 (last-message (car (last messages))))
            (is (eq :tool (getf last-message :role)))
            (is (equal "c1" (getf last-message :tool-call-id)))
            (is (search "interrupted" (nyaa:content-text (getf last-message :content))))
            (let ((event (find :tool-result events :key (lambda (e) (getf e :type)))))
              (is (equal "c1" (getf event :id)))
              (is (equal '(:error :interrupted) (getf event :result))))))))))

;;; --- continuing a conversation ---------------------------------------

(defun restored-conversation ()
  '((:role :system :content "be brief")
    (:role :user :content "first")
    (:role :assistant :content "earlier answer")))

(defun run-on-restored (&rest run-args)
  "Restore a three-message conversation onto a fresh agent, :RUN it with
RUN-ARGS and return the run's result."
  (m:with-process (runner)
    (let ((child (m:delegate *ctx* 'nyaa:agent :model :provider-test-keyed
                             :system "be brief")))
      (m:call child (list :restore (list :messages (restored-conversation) :turns 3)))
      (m:cast child (list* :run run-args))
      (multiple-value-bind (message received) (m:receive :timeout 5)
        (is-true received)
        (fourth message)))))

(test continue-runs-on-the-restored-conversation
  (with-agent ((final-reply "ok"))
    (let* ((result (run-on-restored :continue t
                                    :messages '((:role :user :content "more"))))
           (messages (getf (second result) :messages)))
      (is (eq :stop (getf (second result) :stop-reason)))
      (is (= 1 (getf (second result) :turns)))
      (is (equal '(:system :user :assistant :user :assistant)
                 (mapcar (lambda (m) (getf m :role)) messages)))
      (is (search "earlier answer" (getf (first (requests)) :body)))
      (is (search "more" (getf (first (requests)) :body))))))

(test run-without-continue-replaces-the-conversation
  (with-agent ((final-reply "ok"))
    (run-on-restored :messages '((:role :user :content "fresh")))
    (is (not (search "earlier answer" (getf (first (requests)) :body))))
    (is (search "fresh" (getf (first (requests)) :body)))))

;;; --- events ---------------------------------------------------------

(test stream-events-reach-the-sink-in-order
  (with-agent ((sse-response
                "{\"choices\":[{\"delta\":{\"content\":\"hi \"}}]}"
                "{\"choices\":[{\"delta\":{\"content\":\"there\"}}]}"
                "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"
                "[DONE]"))
    (let ((events '()))
      (agent-turn :messages '((:role :user :content "hi"))
                 :sink (lambda (event) (push event events)))
      (setf events (nreverse events))
      ;; :TEXT-DELTA/:DONE are the protocol's own, passed straight through
      ;; because :STREAM is handed down in the request; :TURN and :RUN-DONE
      ;; are the loop's.
      (is (equal '(:turn :text-delta :text-delta :done :run-done)
                 (mapcar (lambda (e) (getf e :type)) events))))))

;;; A failed turn ends the sink's turn with a failed :DONE, ahead of the loop's
;;; own :RUN-DONE.
(test a-failed-streamed-turn-emits-a-failed-done-before-run-done
  (with-agent ('(500 ("Content-Type" "application/json") "{\"error\":\"boom\"}"))
    (let* ((events '())
           (result (agent-turn :messages '((:role :user :content "hi"))
                               :sink (lambda (event) (push event events)))))
      (setf events (nreverse events))
      (is (eq :backend-error (first (nyaa:tool-error result))))
      (is (equal '(:turn :done :run-done)
                 (mapcar (lambda (e) (getf e :type)) events)))
      (is (nyaa:tool-error-p (getf (second events) :reason))))))

;;; --- sub-agents ----------------------------------------------------

(test a-sub-agent-result-reaches-the-parent-as-a-tool-message
  (let ((n 0))
    (with-agent ((lambda (&rest request)
                   (declare (ignore request))
                   (incf n)
                   (cond
                     ((= n 1) (tool-call-reply "c1" "agent-task" "{\"task\":\"help\"}"))
                     ((= n 2) (final-reply "sub-answer"))
                     (t (final-reply "done")))))
      (let ((result (agent-turn :messages '((:role :user :content "go"))
                                :sub-agents t)))
        (is (eq :ok (first result)))
        (is (eq :stop (getf (second result) :stop-reason)))
        (is (= 3 (length (requests))))
        (let ((tool-message (find :tool (getf (second result) :messages)
                                  :key (lambda (m) (getf m :role)))))
          (is (search "sub-answer" (nyaa:content-text (getf tool-message :content)))))))))

(defun other-agent-child (context exclude)
  "Poll CONTEXT's children for a mounted AGENT that is not EXCLUDE, up to
2s -- delegation happens on the parent's own process, asynchronously to the
test's."
  (loop repeat 100
        for found = (find-if (lambda (c)
                                (and (eq (getf c :class) 'nyaa:agent)
                                     (not (eq (getf c :process) exclude))))
                              (m:children context))
        when found return (getf found :process)
        do (sleep 0.02)))

(test a-crashed-sub-agent-comes-back-as-an-error-tool-message
  (let ((n 0))
    (with-agent ((lambda (&rest request)
                   (declare (ignore request))
                   (incf n)
                   (if (= n 1)
                       (tool-call-reply "c1" "agent-task" "{\"task\":\"help\"}")
                       ;; Slow, so there is a window to unmount the child
                       ;; before its own turn would otherwise finish it.
                       (progn (sleep 0.5) (final-reply "recovered")))))
      (m:with-process (runner)
        (let ((parent (m:delegate *ctx* 'nyaa:agent :model :provider-test-keyed
                                  :sub-agents t)))
          (m:cast parent (list :run :messages '((:role :user :content "go"))))
          (let ((sub (other-agent-child *ctx* parent)))
            (is-true sub)
            ;; UNMOUNT stops the sub-agent for :shutdown, which is the
            ;; :agent-down path -- the one raw shape ~takeiteasy/meow#59's
            ;; fallback exists for.
            (m:unmount *ctx* sub)
            (multiple-value-bind (message received) (m:receive :timeout 5)
              (is-true received)
              (is (eq :agent-done (first message)))
              (let ((tool-message (find :tool (getf (second (fourth message)) :messages)
                                        :key (lambda (m) (getf m :role)))))
                (is (search "sub_agent_down"
                           (nyaa:content-text (getf tool-message :content))))))))))))

;;; --- discovery -----------------------------------------------------

(test a-mounted-agent-is-discoverable-and-describes-itself
  (with-agent ((final-reply "hi"))
    (m:mount *ctx* 'nyaa:agent :name :agent-under-test :model :provider-test-keyed)
    (is (member :agent-under-test (nyaa:agents) :test #'equal))
    (let ((metadata (nyaa:describe-agent :agent-under-test)))
      (is (eq :agent (getf metadata :kind)))
      (is (eq :provider-test-keyed (getf metadata :model))))))
