(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; Checkpoints and rollback (~takeiteasy/nyaa#11): SNAPSHOT/RESTORE across
;;; the shared convention, the generation file on disk, drift reporting, the
;;; agent's own state trimming, and TOOL-CHECKPOINT.

;;; A stub service with real declared state, driven only through messages --
;;; the mechanism under test never touches another process's slots directly.

(m:defservice stateful-thing () ((value :initform 0 :accessor thing-value))
  (:name :stateful-thing))

(defmethod nyaa:snapshot ((service stateful-thing))
  (list :value (thing-value service)))

(defmethod nyaa:restore ((service stateful-thing) state)
  (setf (thing-value service) (getf state :value))
  t)

(defmethod m:handle ((service stateful-thing) message)
  (case (first message)
    (:set (setf (thing-value service) (second message)))
    (:get (thing-value service))
    (:snapshot (nyaa:snapshot service))
    (:restore (nyaa:restore service (second message)))
    (t nil)))

;;; --- the harness --------------------------------------------------------

(defvar *ckpt-context* nil "The running context, bound by WITH-CHECKPOINTS.")

(defun make-generations-directory ()
  (format nil "~anyaa-generations-test-~36r/"
          (namestring (uiop:temporary-directory))
          (random (expt 2 64) (make-random-state t))))

(defmacro with-generations-directory ((dir) &body body)
  `(let ((,dir (make-generations-directory)))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree (uiop:ensure-directory-pathname ,dir)
                                   :validate t :if-does-not-exist :ignore))))

(defun call-with-checkpoints (dir body)
  (let* ((registry (make-instance 'm:registry))
         (m:*registry* registry)
         (context (m:start-service (make-instance 'm:context :name :tools)
                                   :registry registry)))
    (setf *ckpt-context* context)
    (unwind-protect
         (progn
           (m:mount context 'stateful-thing)
           (m:mount context 'nyaa:tool-fs :root (make-sandbox-directory))
           (m:mount context 'nyaa:tool-checkpoint :dir dir)
           (funcall body))
      (m:stop context))))

(defmacro with-checkpoints ((dir) &body body)
  `(with-generations-directory (,dir) (call-with-checkpoints ,dir (lambda () ,@body))))

(defun thing () (m:call (m:lookup :stateful-thing) '(:get)))
(defun set-thing (value) (m:call (m:lookup :stateful-thing) (list :set value)))

;;; --- the generation file --------------------------------------------------

(test generation-file-round-trips
  (with-generations-directory (dir)
    (ensure-directories-exist dir)
    (let ((path (merge-pathnames "x.generation" dir))
          (form (list :nyaa-generation 1 :created "2026-01-01T00:00:00Z"
                      :label "t"
                      :services (list (list :name :a :class "a" :state (list :x 1))))))
      (nyaa::%write-generation path form)
      (is (equal form (nyaa::%read-generation path))))))

(test reading-a-generation-never-evaluates
  ;; *READ-EVAL* is nil around the read, the same guard tool-eval's worker
  ;; applies to a submitted form.
  (with-generations-directory (dir)
    (ensure-directories-exist dir)
    (let ((path (merge-pathnames "evil.generation" dir)))
      (with-open-file (stream path :direction :output)
        (write-string "(:nyaa-generation 1 :services (#.(error \"read-eval ran\")))"
                      stream))
      (signals error (nyaa::%read-generation path)))))

;;; --- checkpoint / rollback ------------------------------------------------

(test checkpoint-and-rollback-round-trip-a-services-own-state
  (with-checkpoints (dir)
    (set-thing 42)
    (let ((path (nyaa:checkpoint *ckpt-context* :dir dir)))
      (set-thing 0)
      (is (eql 0 (thing)))
      (nyaa:rollback *ckpt-context* path)
      (is (eql 42 (thing))))))

(test a-service-with-no-snapshot-method-restores-cleanly
  ;; tool-fs takes the default NIL SNAPSHOT/RESTORE; the round trip must not
  ;; error just because there is nothing to carry.
  (with-checkpoints (dir)
    (let ((path (nyaa:checkpoint *ckpt-context* :dir dir)))
      (is (member :tool-fs (getf (second (nyaa:rollback *ckpt-context* path)) :restored))))))

(test rollback-reports-a-service-missing-since-the-checkpoint
  (with-checkpoints (dir)
    (let ((path (nyaa:checkpoint *ckpt-context* :dir dir)))
      (m:unmount *ckpt-context* :stateful-thing)
      (is (equal '(:stateful-thing)
                 (getf (second (nyaa:rollback *ckpt-context* path)) :missing))))))

(test rollback-reports-a-class-mismatch-and-does-not-restore-it
  (with-checkpoints (dir)
    (set-thing 9)
    (let ((path (nyaa:checkpoint *ckpt-context* :dir dir)))
      (m:unmount *ckpt-context* :stateful-thing)
      ;; A different class mounted under the same name now.
      (m:mount *ckpt-context* 'nyaa:tool-fs :name :stateful-thing :root (make-sandbox-directory))
      (let ((mismatched (getf (second (nyaa:rollback *ckpt-context* path)) :mismatched)))
        (is (eql 1 (length mismatched)))
        (is (equal :stateful-thing (getf (first mismatched) :name)))))))

(test checkpoint-keep-prunes-the-oldest-generations
  (with-checkpoints (dir)
    (nyaa:checkpoint *ckpt-context* :dir dir)
    (sleep 1.1)
    (nyaa:checkpoint *ckpt-context* :dir dir)
    (sleep 1.1)
    (nyaa:checkpoint *ckpt-context* :dir dir :keep 2)
    (is (eql 2 (length (nyaa:generations :dir dir))))))

;;; --- the agent's own snapshot ---------------------------------------------

(defun agent-snapshot (name)
  (m:call (m:lookup name) '(:snapshot)))

(defun wait-for-agent-turns (name n &optional (deadline 3.0))
  (loop repeat (ceiling deadline 0.05)
        for snap = (agent-snapshot name)
        when (>= (getf snap :turns 0) n) return snap
        do (sleep 0.05)
        finally (return (agent-snapshot name))))

(test agent-checkpoint-restores-mid-run-state-and-lands-not-running
  ;; A snapshot is only interesting taken mid-run: finishing a run exits the
  ;; agent (M:AGENT's own convention), and the mount's default :restart
  ;; brings it back as a fresh, empty instance -- there is no conversation
  ;; left to see afterwards, from CHECKPOINT or otherwise. The backend is
  ;; slowed down to hold that window open, and the checkpoint is taken, then
  ;; rolled back, while :running-p is still t on the very same process.
  ;;
  ;; The agent is checkpointed through its own nested context, holding only
  ;; itself: CHECKPOINT walks a context's children serially, one SNAPSHOT
  ;; call at a time (~takeiteasy/nyaa#51), and protocol-openai is
  ;; itself blocked for the run's own 0.3s while its one HTTP exchange is in
  ;; flight -- a checkpoint of the whole :agents context would queue behind
  ;; it and only reach :assistant after the run had already finished.
  (let* ((registry (make-instance 'm:registry))
         (m:*registry* registry)
         (context (m:start-service (make-instance 'm:context :name :agents)
                                   :registry registry))
         (server (start-fake-http (lambda (&rest r) (declare (ignore r))
                                    (sleep 0.3) (json-response +hello-reply+))))
         (agent-context (m:mount context 'm:context :name :agent-only)))
    (unwind-protect
         (with-generations-directory (dir)
           (m:mount context 'nyaa:protocol-openai)
           (apply #'m:mount context (first (keyed)) :base-url (fake-http-url server) (rest (keyed)))
           (m:mount agent-context 'nyaa:agent :name :assistant :model :provider-test-keyed)
           (m:cast (m:lookup :assistant) (list :run :messages '((:role :user :content "hi"))))
           (let ((mid-run (wait-for-agent-turns :assistant 1 1.0)))
             (is (eql 1 (getf mid-run :turns)))
             (is (search "hi" (prin1-to-string (getf mid-run :messages))))
             (let ((path (nyaa:checkpoint agent-context :dir dir)))
               (nyaa:rollback agent-context path)
               (let ((restored (agent-snapshot :assistant)))
                 (is (equal mid-run restored)))
               ;; RESTORE always lands a not-running agent: a further :run
               ;; is accepted at once rather than refused as already
               ;; running. START-RUN answers synchronously, before the
               ;; backend is even asked, so this does not wait out the
               ;; 0.3s delay or the exit-and-restart that finishing it
               ;; would trigger.
               (is (eq :ok (m:call (m:lookup :assistant)
                                   (list :run :messages '((:role :user :content "second")))))))))
      (m:stop context)
      (stop-fake-http server))))

;;; --- tool-checkpoint --------------------------------------------------

(test tool-checkpoint-is-operator-trusted
  (with-checkpoints (dir)
    (is (eq :operator (nyaa:tool-trust (nyaa:describe-tool :tool-checkpoint))))))

(test tool-checkpoint-saves-lists-and-restores
  (with-checkpoints (dir)
    (set-thing 7)
    (let* ((save (nyaa:invoke-tool :tool-checkpoint :op :save :label "seven"))
           (path (getf (second save) :path)))
      (is (eq :ok (first save)))
      (let ((listed (getf (second (nyaa:invoke-tool :tool-checkpoint :op :list)) :generations)))
        (is (find path listed :key (lambda (g) (getf g :path)) :test #'equal))
        (is (equal "seven" (getf (find path listed :key (lambda (g) (getf g :path))
                                       :test #'equal)
                                 :label))))
      (set-thing 0)
      (nyaa:invoke-tool :tool-checkpoint :op :restore :path path)
      (is (eql 7 (thing))))))

(test tool-checkpoint-restore-requires-a-path
  (with-checkpoints (dir)
    (is (equal :bad-request
               (first (nyaa:tool-error (nyaa:invoke-tool :tool-checkpoint :op :restore)))))))

(test tool-checkpoint-restore-rejects-an-unknown-path
  (with-checkpoints (dir)
    (is (equal :bad-request
               (first (nyaa:tool-error
                       (nyaa:invoke-tool :tool-checkpoint :op :restore
                                        :path "/nonexistent/x.generation")))))))

;;; --- per-path log locks (~takeiteasy/nyaa#65) -----------------------------

(test one-file-under-two-spellings-shares-a-lock
  (with-generations-directory (dir)
    (ensure-directories-exist (format nil "~asub/" dir))
    (let ((a (format nil "~ax.log" dir))
          (b (format nil "~asub/../x.log" dir)))
      (is (eq (nyaa::%log-lock a) (nyaa::%log-lock b)))
      (is (not (eq (nyaa::%log-lock a) (nyaa::%log-lock (format nil "~ay.log" dir))))))))

(test appending-to-one-log-does-not-wait-on-another
  (with-generations-directory (dir)
    (let* ((a (format nil "~aa.log" dir))
           (b (format nil "~ab.log" dir))
           (lock (nyaa::%log-lock a))
           (done nil))
      (bt:with-lock-held (lock)
        (bt:make-thread (lambda ()
                          (nyaa::%append-log b '(:kind :x))
                          (setf done t)))
        (loop repeat 100 until done do (sleep 0.05))
        (is-true done))
      (is (equal '((:kind :x)) (nyaa::%read-log b))))))

(test read-log-reports-a-torn-tail
  (with-generations-directory (dir)
    (let ((path (format nil "~aa.log" dir)))
      (nyaa::%append-log path '(:kind :x))
      (is (eq t (nth-value 1 (nyaa::%read-log path))))
      (with-open-file (s path :direction :output :if-exists :append)
        (write-string "(broken" s))
      (is (equal '((:kind :x)) (nyaa::%read-log path)))
      (is (null (nth-value 1 (nyaa::%read-log path)))))))
