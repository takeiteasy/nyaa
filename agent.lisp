(in-package #:nyaa)

;;; The agent loop. A meow agent (M:AGENT) that sends a conversation to a
;;; bound model, dispatches the tool calls that come back, feeds the results
;;; in and goes round again. Driven by messages rather than a blocking call,
;;; so it stays responsive between turns -- CANCEL and STEER land during a
;;; run, not just before one -- and a sub-agent delegated under meow's own
;;; agent supervisor reports back into the same machine. See docs/agent.md.
;;;
;;; Every outbound piece of work -- a model turn, a tool call, a sub-agent --
;;; is issued off the agent's process and reported back as a message, so
;;; HANDLE is never blocked waiting on one. A turn and a tool call are sent
;;; with M:CALL-ASYNC and answer as a (:REPLY tag value status) message,
;;; holding no thread meanwhile; a sub-agent is a delegated agent of its own.
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
   (max-parallel-tools :initarg :max-parallel-tools :initform nil
                       :type (or null (integer 1)) :reader agent-max-parallel-tools
                       :documentation "The most tool calls, sub-agents included,
running at once. The rest wait their turn.")
   (max-tool-result :initarg :max-tool-result :initform nil
                    :type (or null (integer 1)) :reader agent-max-tool-result
                    :documentation "The most characters of a tool result's
rendered text that reach the conversation; NIL is uncapped.")
   (max-context :initarg :max-context :initform nil
                :type (or null (integer 1)) :reader agent-max-context
                :documentation "The most tokens of conversation and tool
schemas a turn's request carries, estimated from characters at
:CHARS-PER-TOKEN; the oldest turns past it are left out of the request, not the
conversation. NIL is unbounded.")
   (chars-per-token :initarg :chars-per-token :initform 3
                    :type (real (0)) :accessor %chars-per-token
                    :documentation "Characters per token, the estimate
:MAX-CONTEXT is measured with. Starts here and is recalibrated from each
reply's prompt-token count, so it follows the model's own tokenizer.")
   (turn-retries :initarg :turn-retries :initform 0
                 :type (integer 0) :reader agent-turn-retries
                 :documentation "How many times a turn that failed transiently
is sent again before the run ends.")
   (retry-backoff :initarg :retry-backoff :initform 1000
                  :type (real 0) :reader agent-retry-backoff
                  :documentation "Milliseconds before the first retry; each
further one waits twice as long, plus jitter.")
   (sampling :initarg :sampling :initform nil :reader agent-sampling
             :documentation "A plist of sampling parameters passed through
to COMPLETE, e.g. :TEMPERATURE.")
   (vault :initarg :vault :initform nil :reader agent-vault
          :documentation "NIL (the default): steering is in-memory only. T:
record to the default vault log (~takeiteasy/nyaa#14). A string or
pathname: record there instead.")
   ;; Run state, reset by START-RUN.
   ;; Newest first, so adding one is O(1); CONVERSATION reads it in order.
   (messages :initform nil :accessor %messages)
   (turns :initform 0 :accessor %turns)
   (allow-list :initform nil :accessor %allow-list)
   (pending :initform nil :accessor %pending)
   (pending-order :initform nil :accessor %pending-order)
   (queued :initform nil :accessor %queued)
   (call-tokens :initform nil :accessor %call-tokens)
   (steer-queue :initform nil :accessor %steer-queue)
   (step-ref :initform 0 :accessor %step-ref)
   (running-p :initform nil :accessor %running-p)
   (cancel-timer :initform nil :accessor %cancel-timer)
   (turn-token :initform nil :accessor %turn-token)
   (turn-in-flight :initform nil :accessor %turn-in-flight)
   (attempt :initform 0 :accessor %attempt)
   (retry-pending :initform nil :accessor %retry-pending)
   (turn-stream :initform nil :accessor %turn-stream)
   (last-request-chars :initform nil :accessor %last-request-chars)
   (emitter :initform nil :accessor %emitter))
  (:default-initargs :name nil))

(defmethod m:metadata ((service agent))
  (list :kind :agent
        :name (m:service-name service)
        :summary "A turn cycle over a bound model and its tools"
        :model (agent-model service)
        :tools (agent-tools-spec service)
        :sub-agents (agent-sub-agents service)
        :max-turns (agent-max-turns service)
        :max-tool-result (agent-max-tool-result service)
        :max-context (agent-max-context service)
        :chars-per-token (%chars-per-token service)
        :turn-retries (agent-turn-retries service)
        :retry-backoff (agent-retry-backoff service)
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
    (:retry (when (and (%retry-pending service) (eql (second message) (%step-ref service)))
              (resend-turn service)
              nil))
    (:reply (destructuring-bind (tag value status) (rest message)
              (route-reply service tag (%call-result value status))))
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
              (revappend (getf args :messages)
                         (if (and (getf args :continue) (%messages service))
                             (%messages service)
                             (and (agent-system service)
                                  (list (list :role :system :content (agent-system service))))))
              (%turns service) 0
              (%pending service) nil
              (%pending-order service) nil
              (%queued service) nil
              (%call-tokens service) nil
              ;; %STEER-QUEUE is deliberately not cleared here: a steer (or
              ;; a vault :restore) sent while the agent was idle waits in
              ;; the queue rather than being dropped, and folds in on the
              ;; first turn below, after the seed messages.
              (%allow-list service) (resolve-tools service)
              (%running-p service) t)
        (unless (%emitter service)
          (setf (%emitter service) (start-emitter (agent-sink service))))
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
                          (eq (tool-trust (tool-metadata name :registry registry))
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
also abandons a model turn in flight (INTERRUPT-TURN) or the tool calls
outstanding (INTERRUPT-TOOLS); otherwise the steer waits for the next turn as
usual."
  (let* ((content (getf args :content))
         (path (or (getf args :vault-path) (%vault-path (agent-vault service))))
         (id (or (getf args :vault-id)
                 (and path
                      (vault-record path (m:service-name service) content :claim t)))))
    (push (list* id path (list :role :user :content content)) (%steer-queue service)))
  (if (getf args :interrupt)
      ;; An interrupt on the last allowed turn finishes the run, and
      ;; (VALUES :DONE result) is how HANDLE ends it.
      (multiple-value-bind (value result)
          (cond ((%retry-pending service) (resend-turn service))
                ((%turn-in-flight service) (interrupt-turn service))
                ((%pending service) (interrupt-tools service)))
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
  (let ((partial (close-turn-stream
                  service (turn-interrupted-event (m:agent-ref service) (%turns service)))))
    (cancel-turn service)
    (when (plusp (length partial))
      (push-message service (list :role :assistant :content partial))))
  (step-agent service))

(defun interrupt-tools (service)
  "Close the tool calls outstanding for the steer just queued: each still
running is cancelled and closed as :INTERRUPTED, the results already in are
kept, and the next turn folds the steer in, as INTERRUPT-TURN does."
  (close-pending-calls service)
  (incf (%step-ref service))
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
  (release-steer-claims service)
  (retire-emitter service))

(defun cancel-run (service)
  (if (%running-p service)
      (progn
        (close-pending-calls service)
        (finish-run service (ok :messages (conversation service) :content nil
                                :turns (%turns service) :stop-reason :cancelled)))
      :ok))

(defun deadline-run (service)
  (when (%running-p service)
    (close-pending-calls service)
    (finish-run service (ok :messages (conversation service) :content nil
                            :turns (%turns service) :stop-reason :timeout))))

(defun step-agent (service)
  (if (>= (%turns service) (agent-max-turns service))
      (finish-run service (ok :messages (conversation service) :content nil
                              :turns (%turns service) :stop-reason :max-turns))
      (issue-turn service)))

(defun fold-steers (service)
  "Steering only folds in between turns, so a message queued mid-turn never
lands ahead of the assistant reply or tool results already owed."
  (dolist (cell (nreverse (shiftf (%steer-queue service) nil)))
    (push-message service (cddr cell))
    (a:when-let ((id (car cell)))
      (vault-consume (cadr cell) id :folded))))

(defun issue-turn (service)
  (fold-steers service)
  (incf (%turns service))
  (setf (%attempt service) 0)
  (emit-event (agent-events service) (turn-event (m:agent-ref service) (%turns service)))
  (send-turn service))

(defun send-turn (service)
  (setf (%turn-in-flight service) t
        (%turn-stream service) (and (agent-sink service) (make-turn-stream)))
  (let ((ref (incf (%step-ref service)))
        (request (build-request service
                                (setf (%turn-token service) (make-cancel-token))
                                (%turn-stream service))))
    (send-call service (list :turn ref) #'%completion-call (agent-model service) request)
    nil))

(defun send-call (service tag prepare name args)
  "Send the call PREPARE builds for NAME and ARGS -- %COMPLETION-CALL or
%TOOL-CALL -- without waiting. Its reply reaches HANDLE as (:REPLY TAG value
status). A call that cannot be sent is answered at once."
  (multiple-value-bind (process message timeout)
      (handler-case (funcall prepare name args :registry (m:service-registry service))
        (error (e) (values nil (fail (list :error (princ-to-string e))))))
    (if process
        (m:call-async process message :timeout timeout :tag tag)
        (m:cast (m:self) (list :reply tag message nil)))))

(defun route-reply (service tag result)
  "Hand RESULT to the turn or tool call TAG names."
  (destructuring-bind (kind ref &optional id) tag
    (ecase kind
      (:turn (turn-reply service ref result))
      (:tool (when (eql ref (%step-ref service))
               (tool-reply service id result))))))

(defun build-request (service token stream)
  (let ((tools (request-tools service)))
    (multiple-value-bind (messages record chars)
        (fit-conversation (conversation service)
                          :max-context (agent-max-context service)
                          :max-tool-result (agent-max-tool-result service)
                          :chars-per-token (%chars-per-token service)
                          :margin +context-margin+
                          :reserved (%printed-size tools))
      (setf (%last-request-chars service) chars)
      (when record
        (emit-event (agent-events service)
                    (context-trimmed-event (m:agent-ref service) (%turns service) record)))
      (make-request service token stream messages tools))))

(defun make-request (service token stream messages tools)
  (list* :cancel token
         :messages messages
         :tools tools
         :stream (and stream (turn-stream-sink stream (agent-events service)))
         :ref (m:agent-ref service)
         :timeout (agent-turn-timeout service)
         (agent-sampling service)))

(defun request-tools (service)
  (append (mapcar (lambda (name)
                     (tool-metadata name :registry (m:service-registry service)))
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
    (cond
      ((and (tool-error-p result) (retry-turn-p service result))
       (schedule-retry service result))
      ((tool-error-p result)
       (finish-run service result))
      (t
       (let ((reply (second result)))
         (calibrate service reply)
         (push-message service reply)
         (let ((calls (getf reply :tool-calls)))
           (cond
             (calls (dispatch-calls service calls))
             ;; A steer that arrived while this turn was in flight gets a
             ;; turn of its own rather than waiting for the next :RUN.
             ((and (%steer-queue service)
                   (< (%turns service) (agent-max-turns service)))
              (issue-turn service))
             (t (finish-run service (ok :messages (conversation service)
                                        :content (getf reply :content)
                                        :turns (%turns service)
                                        :stop-reason :stop))))))))))

(defun retryable-p (result)
  "Whether RESULT, an (:error reason), is a failure a fresh attempt could get
past: a backend that could not be reached, or one that answered 408, 425, 429,
a 5xx, or a 2xx whose stream or payload broke. A :TIMEOUT is not, since another
attempt could double a wait the caller bounded."
  (let ((reason (tool-error result)))
    (or (eq reason :unavailable)
        (and (consp reason)
             (eq (first reason) :backend-error)
             (let ((status (second reason)))
               (and (integerp status)
                    (or (member status '(408 425 429))
                        (>= status 500)
                        (<= 200 status 299))))))))

(defun retry-turn-p (service result)
  (and (retryable-p result)
       (< (%attempt service) (agent-turn-retries service))))

(defun retry-after (reason)
  "The milliseconds a failed turn's REASON says to wait, or nil."
  (and (consp reason) (eq (first reason) :backend-error)
       (getf (cdddr reason) :retry-after)))

(defun retry-delay (backoff attempt retry-after)
  "Milliseconds before retry ATTEMPT: the doubled BACKOFF, or RETRY-AFTER when
the backend asked for longer, plus up to 25% jitter."
  (* (max (* backoff (expt 2 (1- attempt))) (or retry-after 0))
     (+ 1 (random 0.25d0))))

(defun schedule-retry (service result)
  "Send the turn that just failed again after a backoff. The retry is not a
new turn: :TURNS and the :TURN event stay as they were. Anything that moves
the step ref before the timer fires -- a cancel, the deadline, a restore, an
interrupt -- leaves the timer's :RETRY unmatchable."
  (let* ((attempt (incf (%attempt service)))
         (delay (retry-delay (agent-retry-backoff service) attempt
                             (retry-after (tool-error result))))
         (ref (%step-ref service))
         (self (m:self)))
    (close-turn-stream service)
    (emit-event (agent-events service)
                (turn-retry-event (m:agent-ref service) (%turns service) attempt
                                  (tool-error result)))
    (setf (%turn-in-flight service) t
          (%retry-pending service)
          (m:after service (/ delay 1000.0d0)
                   (lambda () (m:cast self (list :retry ref)))))
    nil))

(defun cancel-retry (service)
  (a:when-let ((cancel (shiftf (%retry-pending service) nil)))
    (funcall cancel)))

(defun resend-turn (service)
  "Send the turn again, with any steer that queued during the backoff."
  (cancel-retry service)
  (fold-steers service)
  (send-turn service))

(defun dispatch-calls (service calls)
  "Every call starts :QUEUED and is dispatched, in order, as
:MAX-PARALLEL-TOOLS allows."
  (setf (%pending service) (mapcar (lambda (call) (cons (getf call :id) :queued)) calls)
        (%pending-order service) (mapcar (lambda (call) (getf call :id)) calls)
        (%call-tokens service) (mapcar (lambda (call) (cons (getf call :id) (make-cancel-token)))
                                       calls)
        (%queued service) calls)
  (dolist (call calls)
    (emit-event (agent-events service)
                (tool-call-event (m:agent-ref service) (getf call :id)
                                 (getf call :name) (getf call :arguments))))
  (pump-calls service)
  nil)

(defun running-calls (service)
  (count :pending (%pending service) :key #'cdr))

(defun pump-calls (service)
  "Dispatch queued calls while a slot is free. A call refused outright
answers at once and never holds one."
  (loop with cap = (agent-max-parallel-tools service)
        while (and (%queued service)
                   (or (null cap) (< (running-calls service) cap)))
        do (let* ((call (pop (%queued service)))
                  (cell (assoc (getf call :id) (%pending service) :test #'equal)))
             (setf (cdr cell) :pending)
             (dispatch-call service call))))

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

(defun call-token (service id)
  (cdr (assoc id (%call-tokens service) :test #'equal)))

(defun dispatch-tool (service call)
  "The reply carries the step ref it was dispatched under: a provider may
reuse a call id on the next turn, and a late reply from an interrupted call
must not answer it."
  (let* ((id (getf call :id))
         (name (getf call :name))
         (args (getf call :arguments))
         (token (call-token service id))
         (ref (%step-ref service)))
    (send-call service (list :tool ref id) #'%tool-call name (list* :cancel token args))
    nil))

(defun dispatch-sub-agent (service call)
  "A tool cannot delegate on the loop's behalf -- the parent would be the
tool's own process, not this agent -- so the reserved call is dispatched
here, directly on this agent's own process, which is what M:DELEGATE reads
its parent from. The child inherits this agent's model and allow-list but
not :SUB-AGENTS, so delegation does not nest by default; which models and
tool sets a child may be given is ~takeiteasy/nyaa#22's policy, not this
ticket's. The child's ref pairs the step ref with the call id, for the same
reason DISPATCH-TOOL's reply does, and cancelling the call cancels the child."
  (let* ((id (getf call :id))
         (task (getf (getf call :arguments) :task))
         (context (m:service-process (m:service-context service)))
         (child (m:delegate context 'agent :ref (cons (%step-ref service) id)
                            :model (agent-model service)
                            :tools (%allow-list service)
                            :sub-agents nil
                            :max-turns (agent-max-turns service)
                            :max-parallel-tools (agent-max-parallel-tools service)
                            :max-tool-result (agent-max-tool-result service)
                            :max-context (agent-max-context service)
                            :chars-per-token (%chars-per-token service)
                            :turn-retries (agent-turn-retries service)
                            :retry-backoff (agent-retry-backoff service)
                            :turn-timeout (agent-turn-timeout service)
                            :deadline (agent-deadline service)
                            :sink (agent-events service)
                            :vault (agent-vault service))))
    (on-cancel (call-token service id) (lambda () (m:cast child '(:cancel))))
    (m:cast child (list :run :messages (list (list :role :user :content task))))
    nil))

(defun sub-agent-done (service ref result)
  (when (eql (car ref) (%step-ref service))
    (tool-reply service (cdr ref)
                (if (tool-error-p result)
                    result
                    (ok :answer (content-text (getf (second result) :content)))))))

(defun sub-agent-down (service ref reason)
  (when (eql (car ref) (%step-ref service))
    (tool-reply service (cdr ref) (fail (list :sub-agent-down reason)))))

(defun outstanding-p (status)
  (member status '(:pending :queued)))

(defun tool-reply (service id result)
  (let ((cell (assoc id (%pending service) :test #'equal)))
    (when (and cell (outstanding-p (cdr cell)))
      (setf (cdr cell) result)
      (emit-event (agent-events service) (tool-result-event (m:agent-ref service) id result))
      (pump-calls service)
      (when (notany (lambda (c) (outstanding-p (cdr c))) (%pending service))
        (close-pending-calls service)
        (m:cast (m:self) '(:step))))
    nil))

(defun pending-tool-messages (service)
  "A :TOOL message for each call dispatched this turn, in order: its result,
or an :INTERRUPTED error where none has arrived."
  (mapcar (lambda (id)
            (let ((result (cdr (assoc id (%pending service) :test #'equal))))
              (tool-message id (if (outstanding-p result) (fail :interrupted) result))))
          (%pending-order service)))

(defun cancel-pending-calls (service)
  "Cancel each call dispatched this turn that has no result yet."
  (setf (%queued service) nil)
  (dolist (cell (%pending service))
    (when (eq (cdr cell) :pending)
      (cancel (call-token service (car cell))))))

(defun close-pending-calls (service)
  (cancel-pending-calls service)
  (dolist (cell (%pending service))
    (when (outstanding-p (cdr cell))
      (setf (cdr cell) (fail :interrupted))
      (emit-event (agent-events service)
                  (tool-result-event (m:agent-ref service) (car cell) (cdr cell)))))
  (dolist (message (pending-tool-messages service))
    (push-message service message))
  (setf (%pending service) nil
        (%pending-order service) nil
        (%call-tokens service) nil))

(defun tool-message (id result)
  (list :role :tool :tool-call-id id :content (render-tool-result result)))

(defun render-tool-result (result)
  "RESULT, an (:ok plist) or (:error reason), as JSON text -- more legible to
a model than PRINC-TO-STRING, and jzon is already a dependency."
  (json:stringify
   (if (tool-error-p result)
       (json-object "error" (untyped->json (tool-error result)))
       (untyped->json (second result)))))

;;; --- fitting the conversation to a request --------------------------------

;;; The conversation is kept whole; each request carries a view of it. A tool
;;; result past :MAX-TOOL-RESULT is cut in the view, and when the view is
;;; still past :MAX-CONTEXT the oldest turns are left out of it. What changed
;;; comes back as a record, indexed into the whole conversation, that
;;; BUILD-REQUEST sends the sink as :CONTEXT-TRIMMED.

(defparameter +context-margin+ 9/10
  "The share of :MAX-CONTEXT a request may fill: the ratio drifts with content,
and code and JSON tokenise worse than prose.")

(defparameter +min-chars-per-token+ 1)
(defparameter +max-chars-per-token+ 8)

(defparameter +omitted-note+ "[~d earlier messages omitted to fit the context budget]")

(defun %cut-text (text cap)
  "TEXT, cut at CAP characters with a note of how much was dropped, so the
model knows it saw part of it."
  (if (and cap (> (length text) cap))
      (format nil "~a... [truncated: ~d characters, first ~d kept]"
              (subseq text 0 cap) (length text) cap)
      text))

(defun %printed-size (object)
  (length (let ((*print-pretty* nil)) (prin1-to-string object))))

(defun %message-size (message)
  (+ (length (content-text (getf message :content)))
     (let ((calls (getf message :tool-calls)))
       (if calls (%printed-size calls) 0))))

(defun %conversation-units (messages)
  "The indices of MESSAGES that go together, oldest first: an assistant turn
with tool calls and the :TOOL replies after it, or any other message alone.
A :SYSTEM message is in none."
  (let* ((messages (coerce messages 'vector))
         (units '()) (i 0) (n (length messages)))
    (loop while (< i n)
          do (let ((message (aref messages i)))
               (cond ((eq (getf message :role) :system) (incf i))
                     ((getf message :tool-calls)
                      (let ((end (1+ i)))
                        (loop while (and (< end n) (eq (getf (aref messages end) :role) :tool))
                              do (incf end))
                        (push (loop for k from i below end collect k) units)
                        (setf i end)))
                     (t (push (list i) units) (incf i)))))
    (nreverse units)))

;; TODO: the oldest turns are dropped outright and only a note stands in for
;; them; summarise the dropped span instead, under the policy of the
;; orchestrator DSL (~takeiteasy/nyaa#139).
(defun fit-conversation (messages &key max-context max-tool-result
                                    (chars-per-token 1) (margin 1) (reserved 0))
  "MESSAGES as a request should carry them, a record of what was changed, or
nil when nothing was, and the characters the request measures. Each :TOOL
message is cut to MAX-TOOL-RESULT characters. MAX-CONTEXT is in tokens, each
CHARS-PER-TOKEN characters, of which the request may fill MARGIN (a fraction);
RESERVED characters, the tool schemas, count against it. If the whole is
still past that, the oldest units -- see %CONVERSATION-UNITS -- are left out
until it fits, a note in their place. A :SYSTEM message and the newest unit are
never left out; if they alone are past the budget the request is sent anyway,
and the record says so. Pure: no I/O, and MESSAGES is not changed.

The record is (:OMITTED indices :TRUNCATED ((index :FROM n :TO m) ...) :SIZE n
:BUDGET b :RATIO r :OVER-BUDGET bool), indices being positions in MESSAGES,
:SIZE and :BUDGET in estimated tokens, and :FROM and :TO in characters."
  (let* ((cut '())
         (view (loop for message in messages
                     for index from 0
                     collect (let* ((text (and max-tool-result
                                               (eq (getf message :role) :tool)
                                               (content-text (getf message :content))))
                                    (kept (and text (%cut-text text max-tool-result))))
                               (cond ((and text (/= (length text) (length kept)))
                                      (push (list index :from (length text) :to max-tool-result)
                                            cut)
                                      (list* :content kept (a:remove-from-plist message :content)))
                                     (t message)))))
         (sizes (map 'vector #'%message-size view))
         (chars (+ reserved (reduce #'+ sizes)))
         (limit (and max-context (* max-context margin chars-per-token)))
         (droppable (butlast (%conversation-units view)))
         (note-size (length (format nil +omitted-note+ (length messages))))
         (omitted '()))
    (when limit
      (loop while (and droppable (> (+ chars (if omitted note-size 0)) limit))
            do (dolist (index (pop droppable))
                 (decf chars (aref sizes index))
                 (push index omitted))))
    (setf omitted (sort omitted #'<))
    (let* ((chars (+ chars (if omitted note-size 0)))
           (over-budget (and limit (> chars limit))))
      (if (not (or omitted cut over-budget))
          (values messages nil chars)
          (values (fit-view view omitted)
                  (list :omitted omitted :truncated (nreverse cut)
                        :size (ceiling chars chars-per-token) :budget max-context
                        :ratio chars-per-token :over-budget (and over-budget t))
                  chars)))))

(defun fit-view (view omitted)
  "VIEW without the messages at the indices OMITTED, a note standing in for
them ahead of the first one kept that is not a :SYSTEM message."
  (let ((noted (null omitted)) (out '())
        (gone (make-hash-table)))
    (dolist (index omitted) (setf (gethash index gone) t))
    (loop for message in view
          for index from 0
          unless (gethash index gone)
            do (unless (or noted (eq (getf message :role) :system))
                 (setf noted t)
                 (push (list :role :user
                             :content (format nil +omitted-note+ (length omitted)))
                       out))
               (push message out))
    (nreverse out)))

(defun calibrate (service reply)
  "Set SERVICE's characters per token from REPLY's prompt-token count over the
characters the request that drew it measured. A reply that reports no count, or
one that reads implausibly, leaves the last ratio."
  (let ((tokens (reply-prompt-tokens reply))
        (chars (%last-request-chars service)))
    (when (and tokens chars)
      (let ((ratio (/ chars tokens 1d0)))
        (when (<= +min-chars-per-token+ ratio +max-chars-per-token+)
          (setf (%chars-per-token service) ratio))))))

(defun conversation (service)
  "SERVICE's messages, oldest first, in a list of its own."
  (reverse (%messages service)))

(defun push-message (service message)
  (push message (%messages service)))

;;; --- the sink -----------------------------------------------------------

;;; Every event reaches the sink through AGENT-EVENTS: a function sink is
;;; called from the agent's emitter, which a sub-agent is handed as its own
;;; sink, so the whole tree calls it one event at a time, in order, and a sink
;;; that blocks never holds up HANDLE. :RUN-DONE is the last event it sees.

(defun agent-events (service)
  "Where SERVICE's events go: its emitter, or a process or emitter sink. Nil
when a function sink has no emitter running, so it is never called here."
  (let ((sink (agent-sink service)))
    (cond ((%emitter service))
          ((typep sink '(or m:process emitter)) sink))))

(defun retire-emitter (service)
  "Stop the emitter once it has delivered what it was sent, and kill it if
the sink has not taken that within *SINK-GRACE*."
  (a:when-let ((emitter (shiftf (%emitter service) nil)))
    (stop-emitter emitter)
    (reap-emitter emitter *sink-grace*)))

;;; --- a turn's stream ------------------------------------------------------

;;; The events a turn streams pass through one of these on their way to the
;;; sink. Closing it takes the same lock, so nothing from an abandoned turn
;;; reaches the sink after its :TURN-INTERRUPTED or :RUN-DONE, and the text
;;; kept is exactly the text the sink saw.

(defstruct (turn-stream (:constructor make-turn-stream ()))
  (lock (bt:make-lock :name "nyaa-turn-stream"))
  (text (make-string-output-stream))
  (superseded nil))

(defun turn-stream-sink (stream events)
  (lambda (event)
    (bt:with-lock-held ((turn-stream-lock stream))
      (unless (turn-stream-superseded stream)
        (when (eq (getf event :type) :text-delta)
          (write-string (getf event :text) (turn-stream-text stream)))
        (emit-event events event)))))

(defun close-turn-stream (service &optional last-event)
  "Close the turn's stream to further events, emit LAST-EVENT, if given, and
return the text it streamed. With no sink there is no stream, and nothing to
tell or keep."
  (let ((stream (shiftf (%turn-stream service) nil)))
    (if stream
        (bt:with-lock-held ((turn-stream-lock stream))
          (setf (turn-stream-superseded stream) t)
          (when last-event
            (emit-event (agent-events service) last-event))
          (get-output-stream-string (turn-stream-text stream)))
        "")))

(defun cancel-turn (service)
  "Stop the completion in flight, if any, rather than leave it to its own
timeout."
  (a:when-let ((token (shiftf (%turn-token service) nil)))
    (cancel token)))

(defun finish-run (service result)
  (cancel-deadline service)
  (cancel-retry service)
  (close-turn-stream service)
  (cancel-turn service)
  (setf (%running-p service) nil
        (%turn-in-flight service) nil
        (%pending service) nil
        (%pending-order service) nil
        (%queued service) nil
        (%call-tokens service) nil)
  ;; Invalidates any turn already in flight, so its late TURN-REPLY is
  ;; dropped rather than reopening a run that has already finished.
  (incf (%step-ref service))
  (emit-event (agent-events service)
              (run-done-event (m:agent-ref service)
                              (if (tool-error-p result)
                                  (tool-error result)
                                  (getf (second result) :stop-reason))))
  (retire-emitter service)
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

;;; The protocol's own :TEXT-DELTA / :TOOL-CALL-DELTA / :DONE pass through
;;; the turn's stream. These are the loop's own, all echoing :REF as the
;;; protocol events do.

(defun turn-event (ref n) (list :type :turn :ref ref :turn n))

(defun turn-retry-event (ref n attempt reason)
  (list :type :turn-retry :ref ref :turn n :attempt attempt :reason reason))

(defun turn-interrupted-event (ref n) (list :type :turn-interrupted :ref ref :turn n))

(defun tool-call-event (ref id name arguments)
  (list :type :tool-call :ref ref :id id :name name :arguments arguments))

(defun context-trimmed-event (ref n record)
  (list* :type :context-trimmed :ref ref :turn n record))

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

;;; The turn and tool calls in flight are replies a restore cannot bring
;;; back, so only their ids are recorded, under :IN-FLIGHT, for
;;; a caller to see the checkpoint was taken mid-run. RESTORE lands a
;;; not-running agent and ignores it. A call with no result yet is recorded
;;; closed as :INTERRUPTED, so the restored conversation is well-formed.

(defmethod snapshot ((service agent))
  (append (list :messages (append (conversation service) (pending-tool-messages service))
                :turns (%turns service))
          (when (%running-p service)
            (list :in-flight (list :turn (%turns service)
                                   :tool-calls (copy-list (%pending-order service)))))))

(defmethod restore ((service agent) state)
  (cancel-deadline service)
  (cancel-retry service)
  (close-turn-stream service)
  (cancel-turn service)
  (cancel-pending-calls service)
  (release-steer-claims service)
  (setf (%messages service) (reverse (getf state :messages))
        (%turns service) (getf state :turns)
        (%pending service) nil
        (%pending-order service) nil
        (%call-tokens service) nil
        (%steer-queue service) nil
        (%turn-in-flight service) nil
        (%running-p service) nil)
  ;; As FINISH-RUN does: the turn and tool calls just cancelled still reply
  ;; to this agent's process, so their late replies are made unmatchable --
  ;; each checks the step ref it was issued against.
  (incf (%step-ref service))
  t)
