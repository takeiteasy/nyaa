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
       (ignore-errors (delete-file ,path))
       (ignore-errors (delete-file (format nil "~a.lock" ,path))))))

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

;;; --- compaction (~takeiteasy/nyaa#67) ---------------------------------------

(defun append-raw-vault-line (path form)
  (with-open-file (stream path :direction :output :if-exists :append :if-does-not-exist :create)
    (let ((*package* (find-package "KEYWORD")) (*print-case* :downcase))
      (prin1 form stream)
      (terpri stream))))

(defun record-old-consumed (path id at)
  "A steer at PATH consumed at the iso8601 time AT."
  (append-raw-vault-line path (list :kind :steer :id id :at at :agent :assistant :content id))
  (append-raw-vault-line path (list :kind :consumed :id id :at at :how :folded)))

(test vault-compact-drops-only-consumed-entries-past-max-age
  (with-vault-path (path)
    (record-old-consumed path "old" "2020-01-01T00:00:00Z")
    (let ((recent (nyaa:vault-record path :assistant "recent"))
          (pending (nyaa:vault-record path :assistant "pending")))
      (nyaa:vault-consume path recent :folded)
      (is (equal '(1 2) (multiple-value-list (nyaa:vault-compact path :max-age 3600))))
      (is (equal (list recent pending)
                 (mapcar (lambda (e) (getf e :id)) (nyaa:vault-entries path))))
      (is (eq :folded (getf (first (nyaa:vault-entries path)) :status)))
      (is (eq :pending (getf (second (nyaa:vault-entries path)) :status))))))

(test vault-compact-keeps-a-pending-entry-consumable
  (with-vault-path (path)
    (record-old-consumed path "old" "2020-01-01T00:00:00Z")
    (let ((id (nyaa:vault-record path :assistant "pending")))
      (nyaa:vault-compact path)
      (nyaa:vault-consume path id :discarded)
      (is (eq :discarded (getf (first (nyaa:vault-entries path)) :status))))))

(test vault-compact-max-age-zero-drops-every-consumed-entry
  (with-vault-path (path)
    (let ((a (nyaa:vault-record path :assistant "a"))
          (b (nyaa:vault-record path :assistant "b")))
      (nyaa:vault-consume path a :folded)
      (is (equal '(1 1) (multiple-value-list (nyaa:vault-compact path :max-age 0))))
      (is (equal (list b) (mapcar (lambda (e) (getf e :id)) (nyaa:vault-entries path)))))))

(test vault-compact-refuses-a-malformed-log
  (with-vault-path (path)
    (record-old-consumed path "old" "2020-01-01T00:00:00Z")
    (with-open-file (stream path :direction :output :if-exists :append)
      (write-string "(torn" stream))
    (let ((before (uiop:read-file-string path)))
      (is (null (nyaa:vault-compact path)))
      (is (equal before (uiop:read-file-string path))))))

(test appending-past-the-size-threshold-compacts
  (with-vault-path (path)
    (record-old-consumed path "old" "2020-01-01T00:00:00Z")
    (let ((nyaa:*vault-compact-size* 1))
      (nyaa:vault-record path :assistant "new"))
    (is (equal '("new") (mapcar (lambda (e) (getf e :content)) (nyaa:vault-entries path))))))

(test tool-vault-compact-answers-counts
  (with-vault-path (path)
    (with-agent (nil)
      (m:mount *ctx* 'nyaa:tool-vault :path path)
      (let ((id (nyaa:vault-record path :assistant "a")))
        (nyaa:vault-record path :assistant "b")
        (vault :op :discard :id id)
        (let ((result (vault :op :compact :max-age 0)))
          (is (eq :ok (first result)))
          (is (eql 1 (getf (second result) :dropped)))
          (is (eql 1 (getf (second result) :kept))))))))

(test tool-vault-compact-reports-a-malformed-log
  (with-vault-path (path)
    (with-agent (nil)
      (m:mount *ctx* 'nyaa:tool-vault :path path)
      (nyaa:vault-record path :assistant "a")
      (with-open-file (stream path :direction :output :if-exists :append)
        (write-string "(torn" stream))
      (is (equal :bad-request (first (nyaa:tool-error (vault :op :compact))))))))

;;; --- atomic discard (~takeiteasy/nyaa#85) -------------------------------------

(test vault-consume-pending-answers-the-existing-status
  (with-vault-path (path)
    (let ((id (nyaa:vault-record path :assistant "a")))
      (is (eq :unknown (nyaa:vault-consume-pending path "nope" :discarded)))
      (is (eq :consumed (nyaa:vault-consume-pending path id :discarded)))
      (is (eq :discarded (nyaa:vault-consume-pending path id :folded))))))

(test concurrent-discards-of-one-id-consume-it-once
  (with-vault-path (path)
    (let* ((id (nyaa:vault-record path :assistant "a"))
           (results '())
           (rlock (bt:make-lock))
           (threads (loop repeat 8
                          collect (bt:make-thread
                                   (lambda ()
                                     (let ((r (nyaa:vault-consume-pending path id :discarded)))
                                       (bt:with-lock-held (rlock) (push r results))))))))
      (mapc #'bt:join-thread threads)
      (is (eql 1 (count :consumed results)))
      (is (eql 2 (length (nyaa::%read-log path)))))))

;;; --- cross-process lock (~takeiteasy/nyaa#84) ---------------------------------

(test vault-compact-waits-for-a-lock-held-by-another-process
  (with-vault-path (path)
    (nyaa:vault-record path :assistant "a")
    (is-true (blocks-on-foreign-flock-p path (lambda () (nyaa:vault-compact path :max-age 0))))))

(test vault-consume-pending-waits-for-a-lock-held-by-another-process
  (with-vault-path (path)
    (let ((id (nyaa:vault-record path :assistant "a")))
      (is-true (blocks-on-foreign-flock-p
                path (lambda () (nyaa:vault-consume-pending path id :discarded))))
      (is (eq :discarded (getf (first (nyaa:vault-entries path)) :status))))))

;;; --- single-delivery restore (~takeiteasy/nyaa#87) ----------------------------

(defun wait-for-claimed (path &optional (deadline 3.0))
  (loop repeat (ceiling deadline 0.05)
        for entries = (nyaa:vault-entries path)
        when (getf (first entries) :claimed) return entries
        do (sleep 0.05)
        finally (return (nyaa:vault-entries path))))

(test concurrent-claims-of-one-id-succeed-once
  (with-vault-path (path)
    (let* ((id (nyaa:vault-record path :assistant "a"))
           (results '())
           (rlock (bt:make-lock))
           (threads (loop repeat 8
                          collect (bt:make-thread
                                   (lambda ()
                                     (let ((r (nyaa:vault-claim-pending path id)))
                                       (bt:with-lock-held (rlock) (push r results))))))))
      (mapc #'bt:join-thread threads)
      (is (eql 1 (count :claimed results)))
      (is (eql 7 (count :held results))))))

(test tool-vault-restore-of-a-claimed-entry-is-refused
  (with-vault-path (path)
    (with-agent ((lambda (&rest request) (declare (ignore request)) (final-reply "done")))
      (m:mount *ctx* 'nyaa:tool-vault :path path)
      (m:mount *ctx* 'nyaa:agent :name :assistant :model :provider-test-keyed :vault path)
      (let ((id (nyaa:vault-record path :assistant "once")))
        (is (eq :ok (first (vault :op :restore :id id))))
        (is (eq :bad-request (first (nyaa:tool-error (vault :op :restore :id id)))))
        (is (eq :bad-request (first (nyaa:tool-error (vault :op :discard :id id)))))
        (is (eq :pending (getf (first (nyaa:vault-entries path)) :status)))
        (is-true (getf (first (nyaa:vault-entries path)) :claimed))))))

(test a-restore-is-delivered-once
  (let ((n 0))
    (with-vault-path (path)
      (with-agent ((lambda (&rest request)
                     (declare (ignore request))
                     (incf n)
                     (final-reply "done")))
        (m:mount *ctx* 'nyaa:tool-vault :path path)
        (m:mount *ctx* 'nyaa:agent :name :assistant :model :provider-test-keyed :vault path)
        (let ((id (nyaa:vault-record path :assistant "once")))
          (vault :op :restore :id id)
          (vault :op :restore :id id)
          (m:call (m:lookup :assistant) (list :run :messages '((:role :user :content "go"))))
          (wait-for-vault-status path :folded)
          (is (eql 1 (length (remove-if-not (lambda (e) (eq (getf e :kind) :consumed))
                                            (nyaa::%read-log path))))))))))

(test a-queued-steer-is-claimed-until-it-folds
  (with-vault-path (path)
    (with-agent ((lambda (&rest request) (declare (ignore request)) (final-reply "done")))
      (m:mount *ctx* 'nyaa:agent :name :assistant :model :provider-test-keyed :vault path)
      (m:cast (m:lookup :assistant) '(:steer :content "queued"))
      (is-true (getf (first (wait-for-claimed path)) :claimed))
      (m:call (m:lookup :assistant) (list :run :messages '((:role :user :content "go"))))
      (let ((entry (first (wait-for-vault-status path :folded))))
        (is (eq :folded (getf entry :status)))
        (is-false (getf entry :claimed))))))

(test rolling-an-agent-back-releases-its-queued-claims
  (with-vault-path (path)
    (with-agent (nil)
      (m:mount *ctx* 'nyaa:tool-vault :path path)
      (m:mount *ctx* 'nyaa:agent :name :assistant :model :provider-test-keyed :vault path)
      (m:cast (m:lookup :assistant) '(:steer :content "queued"))
      (is-true (getf (first (wait-for-claimed path)) :claimed))
      (m:call (m:lookup :assistant) (list :restore '(:messages nil :turns 0)))
      (is-false (getf (first (nyaa:vault-entries path)) :claimed))
      (is (eq :ok (first (vault :op :discard :id (getf (first (nyaa:vault-entries path)) :id))))))))

(test restoring-into-an-agent-with-no-vault-folds-into-the-tools-log
  (with-vault-path (path)
    (with-agent ((lambda (&rest request) (declare (ignore request)) (final-reply "done")))
      (m:mount *ctx* 'nyaa:tool-vault :path path)
      (m:mount *ctx* 'nyaa:agent :name :assistant :model :provider-test-keyed)
      (let ((id (nyaa:vault-record path :assistant "hi")))
        (vault :op :restore :id id)
        (m:call (m:lookup :assistant) (list :run :messages '((:role :user :content "go"))))
        (is (eq :folded (getf (first (wait-for-vault-status path :folded)) :status)))))))
