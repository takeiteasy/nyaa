(in-package #:nyaa)

;;; The agent loop. A meow agent (M:AGENT) that sends a conversation to a
;;; bound model, dispatches the tool calls that come back, feeds the results
;;; in and goes round again. Driven by messages rather than a blocking call,
;;; so it stays responsive between turns -- CANCEL and STEER land during a
;;; run, not just before one -- and a sub-agent delegated under meow's own
;;; agent supervisor reports back into the same machine. See docs/agent.md.
;;;
;;; Every outbound piece of work -- a model turn, a tool call, a sub-agent --
;;; is issued from a spawned process and reported back as a message, so
;;; HANDLE is never blocked waiting on one. A spawned process is a fresh
;;; thread and inherits no dynamic bindings, so each one rebinds M:*REGISTRY*
;;; from the service's own before calling back into COMPLETE or INVOKE-TOOL.
;;;
;;; Finishing a run returns (values :done result) from HANDLE, which is
;;; M:AGENT's own convention: the parent gets :agent-done and the agent
;;; exits, so the run is the agent's whole life rather than a state it
;;; outlives.

(defconstant +sub-agent-tool-name+ :agent-task
  "The reserved tool name a model calls to delegate a task, when :SUB-AGENTS
is on. Never a registered tool, so it is dispatched before the allow-list is
consulted.")

(defclass agent (m:agent)
  ((model :initarg :model :initform nil :reader agent-model
          :documentation "A protocol or provider service name.")
   (tools-spec :initarg :tools :initform :default :reader agent-tools-spec
               :documentation ":DEFAULT is the discovered :TRUST :AGENT
tools -- tool-fs, tool-plan, tool-image and tool-services today.
Otherwise a list of tool names.")
   (system :initarg :system :initform nil :reader agent-system)
   (max-turns :initarg :max-turns :initform 16 :reader agent-max-turns)
   (turn-timeout :initarg :turn-timeout :initform +default-tool-timeout+
                 :reader agent-turn-timeout)
   (deadline :initarg :deadline :initform 300000 :reader agent-deadline
             :documentation "Milliseconds for the whole run.")
   (sub-agents :initarg :sub-agents :initform nil :reader agent-sub-agents)
   (sink :initarg :sink :initform nil :reader agent-sink)
   (sampling :initarg :sampling :initform nil :reader agent-sampling
             :documentation "A plist of sampling parameters passed through
to COMPLETE, e.g. :TEMPERATURE.")
   (vault :initarg :vault :initform nil :reader agent-vault
          :documentation "NIL (the default): steering is in-memory only. T:
record to the default vault log (~takeiteasy/nyaa#14). A string or
pathname: record there instead.")
   ;; Run state, reset by START-RUN.
   (messages :initform nil :accessor %messages)
   (turns :initform 0 :accessor %turns)
   (allow-list :initform nil :accessor %allow-list)
   (pending :initform nil :accessor %pending)
   (pending-order :initform nil :accessor %pending-order)
   (steer-queue :initform nil :accessor %steer-queue)
   (step-ref :initform 0 :accessor %step-ref)
   (running-p :initform nil :accessor %running-p)
   (cancel-timer :initform nil :accessor %cancel-timer)
   (turn-token :initform nil :accessor %turn-token)
   (turn-in-flight :initform nil :accessor %turn-in-flight)
   (turn-stream :initform nil :accessor %turn-stream))
  (:default-initargs :name nil))

(defmethod m:metadata ((service agent))
  (list :kind :agent
        :name (m:service-name service)
        :summary "A turn cycle over a bound model and its tools"
        :model (agent-model service)
        :tools (agent-tools-spec service)
        :sub-agents (agent-sub-agents service)
        :max-turns (agent-max-turns service)
        :vault (agent-vault service)))

(defun agents (&key (registry m:*registry*))
  "Every registered agent name, sorted."
  (%registered-of-kind :agent :registry registry))

(defun %agent-process (name &key (registry m:*registry*))
  (multiple-value-bind (process props) (m:lookup name :registry registry)
    (unless process (error "No agent registered under ~s." name))
    (values process props)))

(defun describe-agent (name &key (registry m:*registry*))
  "NAME's metadata plist."
  (m:call (%agent-process name :registry registry) '(:describe)))

;;; --- the machine --------------------------------------------------------

(defmethod m:handle ((service agent) message)
  (case (first message)
    (:describe (m:metadata service))
    (:run (start-run service (rest message)))
    (:steer (queue-steer service (rest message)))
    (:cancel (cancel-run service))
    (:step (step-agent service))
    (:deadline (deadline-run service))
    (:turn-reply (turn-reply service (second message) (third message)))
    (:tool-reply (tool-reply service (second message) (third message)))
    ;; Reports from a delegated sub-agent, routed into HANDLE by the meow fix
    ;; for ~takeiteasy/meow#59.
    (:agent-done (sub-agent-done service (second message) (fourth message)))
    (:agent-down (sub-agent-down service (second message) (third message)))
    (:snapshot (snapshot service))
    (:restore (restore service (second message)))
    (t (bad-request "unknown message ~s" (first message)))))

(defun start-run (service args)
  (if (%running-p service)
      (bad-request "agent is already running")
      (progn
        (setf (%messages service)
              (append (if (and (getf args :continue) (%messages service))
                          (%messages service)
                          (and (agent-system service)
                               (list (list :role :system :content (agent-system service)))))
                      (getf args :messages))
              (%turns service) 0
              (%pending service) nil
              (%pending-order service) nil
              ;; %STEER-QUEUE is deliberately not cleared here: a steer (or
              ;; a vault :restore) sent while the agent was idle waits in
              ;; the queue rather than being dropped, and folds in on the
              ;; first turn below, after the seed messages.
              (%allow-list service) (resolve-tools service)
              (%running-p service) t)
        (arm-deadline service)
        (m:cast (m:self) '(:step))
        :ok)))

(defun resolve-tools (service)
  "The allow-list for this run: an explicit list, or every discovered tool
whose :TRUST is :AGENT."
  (let ((spec (agent-tools-spec service))
        (registry (m:service-registry service)))
    (if (eq spec :default)
        (remove-if-not (lambda (name)
                          (eq (tool-trust (describe-tool name :registry registry))
                              :agent))
                        (tools :registry registry))
        spec)))

(defun queue-steer (service args)
  "Queue a :USER message from ARGS' :CONTENT. When the vault is on
(AGENT-VAULT) and ARGS names no :VAULT-ID, this is a fresh steer and gets
recorded there first and claimed; a :VAULT-ID names an entry already in the
vault, claimed by TOOL-VAULT's :RESTORE, which redelivers one this way
rather than double-recording it, with :VAULT-PATH the log it lives in. The
id and path travel in the queue cell, never in the message plist pushed onto
%MESSAGES, so they can never reach a provider's request. :INTERRUPT true
also abandons a model turn in flight (INTERRUPT-TURN); otherwise the steer
waits for the next turn as usual."
  (let* ((content (getf args :content))
         (path (or (getf args :vault-path) (%vault-path (agent-vault service))))
         (id (or (getf args :vault-id)
                 (and path
                      (vault-record path (m:service-name service) content :claim t)))))
    (push (list* id path (list :role :user :content content)) (%steer-queue service)))
  (if (and (getf args :interrupt) (%turn-in-flight service))
      ;; An interrupt on the last allowed turn finishes the run, and
      ;; (VALUES :DONE result) is how HANDLE ends it.
      (multiple-value-bind (value result) (interrupt-turn service)
        (if (eq value :done) (values :done result) :ok))
      :ok))

(defun interrupt-turn (service)
  "Abandon the model turn in flight for the steer just queued: its late reply
drops with the step ref, the text it had streamed is kept as an assistant
message, and the next turn folds the steer in. Re-stepping through
STEP-AGENT keeps :MAX-TURNS in force, so the abandoned turn counts."
  (setf (%turn-in-flight service) nil)
  (incf (%step-ref service))
  ;; Superseded before it is cancelled, so the cancelled :DONE the protocol
  ;; then emits meets a closed stream rather than racing :TURN-INTERRUPTED.
  (let ((partial (supersede-turn-stream service)))
    (cancel-turn service)
    (when (plusp (length partial))
      (push-message service (list :role :assistant :content partial))))
  (step-agent service))

(defun release-steer-claims (service)
  "Release the vault claim of every steer queued at SERVICE."
  (let ((by-path (make-hash-table :test 'equal)))
    (dolist (cell (%steer-queue service))
      (when (car cell) (push (car cell) (gethash (cadr cell) by-path))))
    (maphash #'vault-release-all by-path)))

(defun reclaim-steer-claims (service)
  "Claim, as this image, every steer queued at SERVICE, dropping any that
another process holds or that is already consumed."
  (setf (%steer-queue service)
        (remove-if-not (lambda (cell)
                         (or (null (car cell))
                             (eq :claimed (vault-claim-pending (cadr cell) (car cell)))))
                       (%steer-queue service))))

(defmethod m:dispose ((service agent) reason)
  (declare (ignore reason))
  (release-steer-claims service))

(defun cancel-run (service)
  (if (%running-p service)
      (progn
        (close-pending-calls service)
        (finish-run service (ok :messages (%messages service) :content nil
                                :turns (%turns service) :stop-reason :cancelled)))
      :ok))

(defun deadline-run (service)
  (when (%running-p service)
    (close-pending-calls service)
    (finish-run service (ok :messages (%messages service) :content nil
                            :turns (%turns service) :stop-reason :timeout))))

(defun step-agent (service)
  (if (>= (%turns service) (agent-max-turns service))
      (finish-run service (ok :messages (%messages service) :content nil
                              :turns (%turns service) :stop-reason :max-turns))
      (issue-turn service)))

(defun issue-turn (service)
  ;; Steering only folds in here, between turns, so a message queued mid-turn
  ;; never lands ahead of the assistant reply or tool results already owed.
  (dolist (cell (nreverse (shiftf (%steer-queue service) nil)))
    (push-message service (cddr cell))
    (a:when-let ((id (car cell)))
      (vault-consume (cadr cell) id :folded)))
  (incf (%turns service))
  (emit-event (agent-sink service) (turn-event (m:agent-ref service) (%turns service)))
  (setf (%turn-in-flight service) t
        (%turn-stream service) (and (agent-sink service) (make-turn-stream)))
  (let ((ref (incf (%step-ref service)))
        (request (build-request service
                                (setf (%turn-token service) (make-cancel-token))
                                (%turn-stream service)))
        (registry (m:service-registry service))
        (parent (m:self)))
    (m:spawn (lambda ()
               (let ((m:*registry* registry))
                 (m:cast parent (list :turn-reply ref
                                      (apply #'complete (agent-model service) request))))))
    nil))

(defun build-request (service token stream)
  (list* :cancel token
         :messages (%messages service)
         :tools (request-tools service)
         :stream (and stream (turn-stream-sink stream (agent-sink service)))
         :ref (m:agent-ref service)
         :timeout (agent-turn-timeout service)
         (agent-sampling service)))

(defun request-tools (service)
  (append (mapcar (lambda (name)
                     (describe-tool name :registry (m:service-registry service)))
                   (%allow-list service))
          (when (agent-sub-agents service) (list (sub-agent-tool-metadata)))))

(defun sub-agent-tool-metadata ()
  (list :kind :tool :name +sub-agent-tool-name+
        :summary "Delegate a task to a sub-agent with this agent's model and
tools, and get back its final answer."
        :params '((:task string :required t :doc "the task to hand off"))))

(defun turn-reply (service ref result)
  ;; A late reply from a turn CANCEL or :DEADLINE already superseded: the
  ;; step ref has moved on, so this one is dropped.
  (when (eql ref (%step-ref service))
    (setf (%turn-in-flight service) nil)
    (if (tool-error-p result)
        (finish-run service result)
        (let ((reply (second result)))
          (push-message service reply)
          (let ((calls (getf reply :tool-calls)))
            (cond
              (calls (dispatch-calls service calls))
              ;; A steer that arrived while this turn was in flight gets a
              ;; turn of its own rather than waiting for the next :RUN.
              ((and (%steer-queue service)
                    (< (%turns service) (agent-max-turns service)))
               (issue-turn service))
              (t (finish-run service (ok :messages (%messages service)
                                         :content (getf reply :content)
                                         :turns (%turns service)
                                         :stop-reason :stop)))))))))

(defun dispatch-calls (service calls)
  (setf (%pending service) (mapcar (lambda (call) (cons (getf call :id) :pending)) calls)
        (%pending-order service) (mapcar (lambda (call) (getf call :id)) calls))
  (dolist (call calls)
    (emit-event (agent-sink service)
                (tool-call-event (m:agent-ref service) (getf call :id)
                                 (getf call :name) (getf call :arguments)))
    (dispatch-call service call))
  nil)

(defun dispatch-call (service call)
  "A call outside the allow-list, and a tool error of any kind, both come
back as a :TOOL message rather than ending the run: the model gets a chance
to recover."
  (let ((name (getf call :name)))
    (cond
      ((and (agent-sub-agents service) (eq name +sub-agent-tool-name+))
       (dispatch-sub-agent service call))
      ((member name (%allow-list service))
       (dispatch-tool service call))
      (t (tool-reply service (getf call :id)
                     (bad-request "~(~a~) is not in this agent's tool allow-list"
                                  name))))))

(defun dispatch-tool (service call)
  (let ((id (getf call :id))
        (name (getf call :name))
        (args (getf call :arguments))
        (registry (m:service-registry service))
        (parent (m:self)))
    (m:spawn (lambda ()
               (let ((m:*registry* registry))
                 (m:cast parent (list :tool-reply id (apply #'invoke-tool name args))))))
    nil))

(defun dispatch-sub-agent (service call)
  "A tool cannot delegate on the loop's behalf -- the parent would be the
tool's own process, not this agent -- so the reserved call is dispatched
here, directly on this agent's own process, which is what M:DELEGATE reads
its parent from. The child inherits this agent's model and allow-list but
not :SUB-AGENTS, so delegation does not nest by default; which models and
tool sets a child may be given is ~takeiteasy/nyaa#22's policy, not this
ticket's."
  (let* ((id (getf call :id))
         (task (getf (getf call :arguments) :task))
         (context (m:service-process (m:service-context service)))
         (child (m:delegate context 'agent :ref id
                            :model (agent-model service)
                            :tools (%allow-list service)
                            :sub-agents nil
                            :max-turns (agent-max-turns service)
                            :turn-timeout (agent-turn-timeout service)
                            :deadline (agent-deadline service)
                            :sink (agent-sink service)
                            :vault (agent-vault service))))
    (m:cast child (list :run :messages (list (list :role :user :content task))))
    nil))

(defun sub-agent-done (service ref result)
  (tool-reply service ref
              (if (tool-error-p result)
                  result
                  (ok :answer (content-text (getf (second result) :content))))))

(defun sub-agent-down (service ref reason)
  (tool-reply service ref (fail (list :sub-agent-down reason))))

(defun tool-reply (service id result)
  (let ((cell (assoc id (%pending service) :test #'equal)))
    (when cell
      (setf (cdr cell) result)
      (emit-event (agent-sink service) (tool-result-event (m:agent-ref service) id result))
      (when (every (lambda (c) (not (eq (cdr c) :pending))) (%pending service))
        (close-pending-calls service)
        (m:cast (m:self) '(:step))))
    nil))

(defun pending-tool-messages (service)
  "A :TOOL message for each call dispatched this turn, in order: its result,
or an :INTERRUPTED error where none has arrived."
  (mapcar (lambda (id)
            (let ((result (cdr (assoc id (%pending service) :test #'equal))))
              (tool-message id (if (eq result :pending) (fail :interrupted) result))))
          (%pending-order service)))

(defun close-pending-calls (service)
  (dolist (cell (%pending service))
    (when (eq (cdr cell) :pending)
      (setf (cdr cell) (fail :interrupted))
      (emit-event (agent-sink service)
                  (tool-result-event (m:agent-ref service) (car cell) (cdr cell)))))
  (dolist (message (pending-tool-messages service))
    (push-message service message))
  (setf (%pending service) nil
        (%pending-order service) nil))

(defun tool-message (id result)
  (list :role :tool :tool-call-id id :content (render-tool-result result)))

(defun render-tool-result (result)
  "RESULT, an (:ok plist) or (:error reason), as JSON text -- more legible to
a model than PRINC-TO-STRING, and jzon is already a dependency."
  (json:stringify
   (if (tool-error-p result)
       (json-object "error" (untyped->json (tool-error result)))
       (untyped->json (second result)))))

(defun push-message (service message)
  (setf (%messages service) (append (%messages service) (list message))))

;;; --- a turn's stream ------------------------------------------------------

;;; The events a turn streams pass through one of these on their way to the
;;; sink. An interrupt supersedes it under the same lock the sink is called
;;; under, so nothing from the abandoned turn reaches the sink after its
;;; :TURN-INTERRUPTED, and the text kept is exactly the text the sink saw.

(defstruct (turn-stream (:constructor make-turn-stream ()))
  (lock (bt:make-lock :name "nyaa-turn-stream"))
  (text (make-string-output-stream))
  (superseded nil))

;;; TODO: the sink is called under the stream's lock, so an interrupt waits
;;; on a sink call in progress, however slow. Upgrade path: one emitter per
;;; agent feeding the sink, as protocols have. Tracked in ~takeiteasy/nyaa#122.

(defun turn-stream-sink (stream sink)
  (lambda (event)
    (bt:with-lock-held ((turn-stream-lock stream))
      (unless (turn-stream-superseded stream)
        (when (eq (getf event :type) :text-delta)
          (write-string (getf event :text) (turn-stream-text stream)))
        (emit-event sink event)))))

(defun supersede-turn-stream (service)
  "Close the turn's stream to further events, emit :TURN-INTERRUPTED, and
return the text it streamed. With no sink there is no stream, and nothing to
tell or keep."
  (let ((stream (shiftf (%turn-stream service) nil)))
    (if stream
        (bt:with-lock-held ((turn-stream-lock stream))
          (setf (turn-stream-superseded stream) t)
          (emit-event (agent-sink service)
                      (turn-interrupted-event (m:agent-ref service) (%turns service)))
          (get-output-stream-string (turn-stream-text stream)))
        "")))

;;; TODO: only the model turn is cancelled; dispatched tool calls run to their
;;; own timeouts. Upgrade path: a cancel token per call. Tracked in
;;; ~takeiteasy/nyaa#111.

(defun cancel-turn (service)
  "Stop the completion in flight, if any, rather than leave it to its own
timeout."
  (a:when-let ((token (shiftf (%turn-token service) nil)))
    (cancel token)))

(defun finish-run (service result)
  (cancel-deadline service)
  (cancel-turn service)
  (setf (%running-p service) nil
        (%turn-in-flight service) nil
        (%pending service) nil
        (%pending-order service) nil)
  ;; Invalidates any turn already in flight, so its late TURN-REPLY is
  ;; dropped rather than reopening a run that has already finished.
  (incf (%step-ref service))
  (emit-event (agent-sink service)
              (run-done-event (m:agent-ref service)
                              (if (tool-error-p result)
                                  (tool-error result)
                                  (getf (second result) :stop-reason))))
  (values :done result))

(defun arm-deadline (service)
  (let ((self (m:self)))
    (setf (%cancel-timer service)
          (m:after service (/ (agent-deadline service) 1000.0d0)
                   (lambda () (m:cast self '(:deadline)))))))

(defun cancel-deadline (service)
  (a:when-let ((cancel (%cancel-timer service)))
    (funcall cancel)
    (setf (%cancel-timer service) nil)))

;;; --- events ---------------------------------------------------------

;;; The protocol's own :TEXT-DELTA / :TOOL-CALL-DELTA / :DONE pass straight
;;; through, since the sink is handed down in the request. These are the
;;; loop's own, all echoing :REF as the protocol events do.

(defun turn-event (ref n) (list :type :turn :ref ref :turn n))

(defun turn-interrupted-event (ref n) (list :type :turn-interrupted :ref ref :turn n))

(defun tool-call-event (ref id name arguments)
  (list :type :tool-call :ref ref :id id :name name :arguments arguments))

(defun tool-result-event (ref id result)
  (list :type :tool-result :ref ref :id id :result result))

(defun run-done-event (ref reason) (list :type :run-done :ref ref :reason reason))

;;; --- a blocking entry point --------------------------------------------

(defun run-agent (context &rest initargs &key messages timeout &allow-other-keys)
  "Delegate an agent on CONTEXT (a mounted context's process), run it to
completion and return its result. The one place nyaa reaches the loop
synchronously: a plain process is the parent, since a service parent needs
the meow fix a mounted agent does not (~takeiteasy/meow#59, already applied
here but not assumed of the caller's own services)."
  (let ((deadline (getf initargs :deadline 300000)))
    (m:with-process (%runner)
      (let ((child (apply #'m:delegate context 'agent
                          (a:remove-from-plist initargs :messages :timeout))))
        (m:cast child (list :run :messages messages))
        (multiple-value-bind (message received)
            (m:receive :timeout (or timeout (/ deadline 1000.0d0)))
          (cond
            ((not received) (fail :timeout))
            ((eq (first message) :agent-done) (fourth message))
            (t (fail (list :error (third message))))))))))

;;; --- checkpoints (~takeiteasy/nyaa#11) ----------------------------------

;;; The turn and tool calls in flight reference spawned processes a restore
;;; cannot bring back, so only their ids are recorded, under :IN-FLIGHT, for
;;; a caller to see the checkpoint was taken mid-run. RESTORE lands a
;;; not-running agent and ignores it. A call with no result yet is recorded
;;; closed as :INTERRUPTED, so the restored conversation is well-formed.

(defmethod snapshot ((service agent))
  (append (list :messages (append (%messages service) (pending-tool-messages service))
                :turns (%turns service))
          (when (%running-p service)
            (list :in-flight (list :turn (%turns service)
                                   :tool-calls (copy-list (%pending-order service)))))))

(defmethod restore ((service agent) state)
  (cancel-deadline service)
  (cancel-turn service)
  (release-steer-claims service)
  (setf (%messages service) (getf state :messages)
        (%turns service) (getf state :turns)
        (%pending service) nil
        (%pending-order service) nil
        (%steer-queue service) nil
        (%turn-in-flight service) nil
        (%running-p service) nil)
  ;; As FINISH-RUN does: a turn or tool call already in flight has this
  ;; agent's process as its :cast target, not a call RESTORE can cancel, so
  ;; its late reply is made unmatchable instead -- TURN-REPLY and TOOL-REPLY
  ;; both check the ref/id they were issued against.
  (incf (%step-ref service))
  t)
