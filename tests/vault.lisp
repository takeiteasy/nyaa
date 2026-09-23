(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; The vault (~takeiteasy/nyaa#14): the log's own record/consume/fold API,
;;; AGENT's use of it through :VAULT and :STEER, and TOOL-VAULT.

(defun make-vault-log-path ()
  (format nil "~anyaa-vault-test-~36r.log"
          (namestring (uiop:temporary-directory))
          (random (expt 2 64) (make-random-state t))))

(defmacro with-vault-path ((path) &body body)
  `(let ((,path (make-vault-log-path)))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file ,path)))))

(defun wait-for-vault-status (path status &optional (deadline 3.0))
  "PATH's entries once the first one reaches STATUS, or its current entries
once DEADLINE elapses -- for asserting on a fold that lands asynchronously,
after the message that triggered it has already returned."
  (loop repeat (ceiling deadline 0.05)
        for entries = (nyaa:vault-entries path)
        when (eq (getf (first entries) :status) status) return entries
        do (sleep 0.05)
        finally (return (nyaa:vault-entries path))))

;;; --- the log API ---------------------------------------------------------

(test vault-record-then-consume-updates-status
  (with-vault-path (path)
    (let ((id (nyaa:vault-record path :assistant "keep going")))
      (let ((entries (nyaa:vault-entries path)))
        (is (eql 1 (length entries)))
        (is (equal id (getf (first entries) :id)))
        (is (eq :assistant (getf (first entries) :agent)))
        (is (equal "keep going" (getf (first entries) :content)))
        (is (eq :pending (getf (first entries) :status))))
      (nyaa:vault-consume path id :folded)
      (let ((entry (first (nyaa:vault-entries path))))
        (is (eq :folded (getf entry :status)))
        (is (stringp (getf entry :consumed-at)))))))

(test vault-entries-defaults-a-fresh-record-to-pending
  (with-vault-path (path)
    (nyaa:vault-record path nil "hi")
    (is (eq :pending (getf (first (nyaa:vault-entries path)) :status)))))

(test a-malformed-vault-line-is-skipped
  (with-vault-path (path)
    (nyaa:vault-record path :assistant "one")
    (with-open-file (stream path :direction :output :if-exists :append)
      (write-string "(not-even-balanced" stream)
      (terpri stream))
    ;; The malformed line ends the read rather than being skipped mid-stream
    ;; -- READ signals on it and %READ-LOG stops there -- so only the entry
    ;; written ahead of it survives.
    (is (eql 1 (length (nyaa:vault-entries path))))))

(test vault-log-reading-never-evaluates
  ;; *READ-EVAL* is nil around the read, the same guard a generation's own
  ;; read and tool-self's log both apply: a #. line fails to read rather
  ;; than running, ending the read there without signalling out.
  (with-vault-path (path)
    (nyaa:vault-record path :assistant "before")
    (with-open-file (stream path :direction :output :if-exists :append)
      (write-string "(:kind :steer :id \"evil\" :at \"t\" :agent nil :content #.(error \"read-eval ran\"))"
                    stream)
      (terpri stream))
    (is (equal '("before") (mapcar (lambda (e) (getf e :content)) (nyaa:vault-entries path))))))

;;; --- the agent's own use of the vault -------------------------------------

(test a-steer-mid-run-is-recorded-then-folded-and-consumed
  (let ((n 0))
    (with-vault-path (path)
      (with-agent ((lambda (&rest request)
                     (declare (ignore request))
                     (incf n)
                     (if (= n 1)
                         (tool-call-reply "c1" "tool-echo" "{\"text\":\"hi\"}")
                         (final-reply "done")))
                  'tool-echo)
        (m:with-process (runner)
          (let ((child (m:delegate *ctx* 'nyaa:agent :model :provider-test-keyed
                                   :tools '(:tool-echo) :vault path)))
            (m:cast child (list :run :messages '((:role :user :content "go"))))
            (m:cast child (list :steer :content "also do this"))
            (multiple-value-bind (message received) (m:receive :timeout 5)
              (is-true received)
              (is (eq :agent-done (first message)))))))
      (let ((entries (nyaa:vault-entries path)))
        (is (eql 1 (length entries)))
        (is (equal "also do this" (getf (first entries) :content)))
        (is (eq :folded (getf (first entries) :status)))))))

(test a-steer-after-the-last-turn-stays-pending
  ;; The backend replies to the one and only turn with no tool call, so the
  ;; run finishes as soon as it returns -- a steer queued while that request
  ;; is still in flight is never folded, and stays :pending in the vault.
  (with-vault-path (path)
    (with-agent ((lambda (&rest request)
                   (declare (ignore request))
                   (sleep 0.3)
                   (final-reply "done")))
      (m:with-process (runner)
        (let ((child (m:delegate *ctx* 'nyaa:agent :model :provider-test-keyed :vault path)))
          (m:cast child (list :run :messages '((:role :user :content "go"))))
          ;; A moment for :RUN's own :STEP to fold the (empty) queue and
          ;; spawn the request -- so this steer queues into a run already
          ;; past its only fold point, and finish-run never revisits it.
          (sleep 0.05)
          (m:cast child (list :steer :content "too late"))
          (multiple-value-bind (message received) (m:receive :timeout 5)
            (is-true received)
            (is (eq :agent-done (first message)))))))
    (let ((entries (nyaa:vault-entries path)))
      (is (eql 1 (length entries)))
      (is (eq :pending (getf (first entries) :status))))))

(test a-steer-before-run-is-folded-after-the-seed
  (with-vault-path (path)
    (with-agent ((final-reply "done"))
      (m:with-process (runner)
        (let ((child (m:delegate *ctx* 'nyaa:agent :model :provider-test-keyed :vault path)))
          (m:cast child (list :steer :content "queued early"))
          (m:cast child (list :run :messages '((:role :user :content "go"))))
          (multiple-value-bind (message received) (m:receive :timeout 5)
            (is-true received)
            (is (eq :agent-done (first message)))
            (is (find "queued early" (getf (second (fourth message)) :messages)
                     :key (lambda (m) (nyaa:content-text (getf m :content)))
                     :test #'equal)))))
      (is (eq :folded (getf (first (nyaa:vault-entries path)) :status))))))

(test with-no-vault-option-steering-records-nothing
  (with-agent ((final-reply "done"))
    (m:with-process (runner)
      (let ((child (m:delegate *ctx* 'nyaa:agent :model :provider-test-keyed)))
        (m:cast child (list :steer :content "hi"))
        (m:cast child (list :run :messages '((:role :user :content "go"))))
        (multiple-value-bind (message received) (m:receive :timeout 5)
          (is-true received)
          (is (eq :agent-done (first message)))))))
  ;; Vault-off never resolves the lazy default path -- checked directly,
  ;; since there is otherwise no path to read the (non-)entries back from.
  (is (null nyaa::*vault-log*)))

;;; --- tool-vault ------------------------------------------------------

(defun vault (op &rest args)
  (apply #'nyaa:invoke-tool :tool-vault op args))

(test tool-vault-is-operator-trusted
  (with-vault-path (path)
    (with-agent (nil)
      (m:mount *ctx* 'nyaa:tool-vault :path path)
      (is (eq :operator (nyaa:tool-trust (nyaa:describe-tool :tool-vault)))))))

(test tool-vault-list-filters-by-status
  (with-vault-path (path)
    (with-agent (nil)
      (m:mount *ctx* 'nyaa:tool-vault :path path)
      (let ((pending-id (nyaa:vault-record path :assistant "a"))
            (folded-id (nyaa:vault-record path :assistant "b")))
        (nyaa:vault-consume path folded-id :folded)
        (let ((pending (getf (second (vault :op :list)) :entries)))
          (is (eql 1 (length pending)))
          (is (equal pending-id (getf (first pending) :id))))
        (let ((all (getf (second (vault :op :list :status :all)) :entries)))
          (is (eql 2 (length all))))))))

(test tool-vault-restore-delivers-into-a-named-agent-and-consumes-it
  (let ((n 0))
    (with-vault-path (path)
      (with-agent ((lambda (&rest request)
                     (declare (ignore request))
                     (incf n)
                     (final-reply "done")))
        (m:mount *ctx* 'nyaa:tool-vault :path path)
        (m:mount *ctx* 'nyaa:agent :name :assistant :model :provider-test-keyed :vault path)
        (let ((id (nyaa:vault-record path :assistant "restored")))
          (let ((result (vault :op :restore :id id)))
            (is (eq :ok (first result)))
            (is (eq :assistant (getf (second result) :agent))))
          ;; Not consumed until the target actually folds it in.
          (is (eq :pending (getf (first (nyaa:vault-entries path)) :status)))
          (is (eq :ok (m:call (m:lookup :assistant)
                              (list :run :messages '((:role :user :content "go"))))))
          ;; :RUN answers :OK once START-RUN itself is done, before its own
          ;; :STEP -- which folds the queue -- has necessarily been
          ;; processed, so the fold is awaited rather than checked at once.
          (is (eq :folded (getf (first (wait-for-vault-status path :folded)) :status))))))))

(test tool-vault-restore-requires-an-agent-when-none-was-recorded
  (with-vault-path (path)
    (with-agent (nil)
      (m:mount *ctx* 'nyaa:tool-vault :path path)
      (let ((id (nyaa:vault-record path nil "no agent")))
        (is (equal :bad-request (first (nyaa:tool-error (vault :op :restore :id id)))))))))

(test tool-vault-restore-rejects-an-unknown-id
  (with-vault-path (path)
    (with-agent (nil)
      (m:mount *ctx* 'nyaa:tool-vault :path path)
      (is (equal :bad-request (first (nyaa:tool-error (vault :op :restore :id "nope"))))))))

(test tool-vault-discard-marks-an-entry-discarded
  (with-vault-path (path)
    (with-agent (nil)
      (m:mount *ctx* 'nyaa:tool-vault :path path)
      (let ((id (nyaa:vault-record path :assistant "drop me")))
        (is (eq :ok (first (vault :op :discard :id id))))
        (is (eq :discarded (getf (first (nyaa:vault-entries path)) :status)))))))

(test tool-vault-discard-rejects-an-already-consumed-id
  (with-vault-path (path)
    (with-agent (nil)
      (m:mount *ctx* 'nyaa:tool-vault :path path)
      (let ((id (nyaa:vault-record path :assistant "drop me")))
        (vault :op :discard :id id)
        (is (equal :bad-request (first (nyaa:tool-error (vault :op :discard :id id)))))))))
