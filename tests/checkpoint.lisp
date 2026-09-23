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
  ;; brings it back as a fresh, empty instance. The backend is slowed down
  ;; to hold that window open, and the whole context is checkpointed, then
  ;; rolled back, while :running-p is still t on the very same process.
  ;; protocol-openai is blocked for the run's own 0.3s, so this also shows
  ;; CHECKPOINT does not queue behind it.
  (let* ((registry (make-instance 'm:registry))
         (m:*registry* registry)
         (context (m:start-service (make-instance 'm:context :name :agents)
                                   :registry registry))
         (server (start-fake-http (lambda (&rest r) (declare (ignore r))
                                    (sleep 0.3) (json-response +hello-reply+)))))
    (unwind-protect
         (with-generations-directory (dir)
           (m:mount context 'nyaa:protocol-openai)
           (apply #'m:mount context (first (keyed)) :base-url (fake-http-url server) (rest (keyed)))
           (m:mount context 'nyaa:agent :name :assistant :model :provider-test-keyed)
           (m:cast (m:lookup :assistant) (list :run :messages '((:role :user :content "hi"))))
           (let ((mid-run (wait-for-agent-turns :assistant 1 1.0)))
             (is (eql 1 (getf mid-run :turns)))
             (is (search "hi" (prin1-to-string (getf mid-run :messages))))
             (is (equal '(:turn 1 :tool-calls nil) (getf mid-run :in-flight)))
             (multiple-value-bind (path interrupted) (nyaa:checkpoint context :dir dir)
               (is (equal '(:assistant) interrupted))
               (is (equal '(:assistant) (getf (first (nyaa:generations :dir dir)) :interrupted)))
               (is (equal '(:assistant)
                          (getf (second (nyaa:rollback context path)) :interrupted)))
               (let ((restored (agent-snapshot :assistant)))
                 (is (equal (getf mid-run :messages) (getf restored :messages)))
                 (is (eql 1 (getf restored :turns)))
                 (is (null (getf restored :in-flight))))
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

;;; --- unavailable services -------------------------------------------------

(m:defservice slow-thing () ((value :initform 5 :accessor slow-value))
  (:name :slow-thing))

(defmethod m:handle ((service slow-thing) message)
  (case (first message)
    (:snapshot (sleep 1) (list :value (slow-value service)))
    (:restore (setf (slow-value service) (getf (second message) :value)) t)
    (:get (slow-value service))
    (:set (setf (slow-value service) (second message)))
    (t nil)))

(test a-service-that-misses-the-deadline-is-unavailable-and-left-alone
  (with-checkpoints (dir)
    (m:mount *ckpt-context* 'slow-thing)
    (set-thing 3)
    (let ((start (get-internal-real-time)))
      (multiple-value-bind (path interrupted unavailable)
          (nyaa:checkpoint *ckpt-context* :dir dir :timeout 0.3)
        (is (< (- (get-internal-real-time) start) (* 0.8 internal-time-units-per-second)))
        (is (null interrupted))
        (is (equal '(:slow-thing) unavailable))
        (is (equal '(:slow-thing) (getf (first (nyaa:generations :dir dir)) :unavailable)))
        (m:call (m:lookup :slow-thing) '(:set 9))
        (set-thing 0)
        (let ((result (second (nyaa:rollback *ckpt-context* path))))
          (is (equal '(:slow-thing) (getf result :unavailable)))
          (is (not (member :slow-thing (getf result :restored)))))
        (is (eql 3 (thing)) "the service that answered is restored")
        (is (eql 9 (m:call (m:lookup :slow-thing) '(:get))) "the unavailable one is untouched")))))

(test a-slow-service-does-not-delay-the-others
  (with-checkpoints (dir)
    (m:mount *ckpt-context* 'slow-thing)
    (set-thing 3)
    (let ((path (nyaa:checkpoint *ckpt-context* :dir dir :timeout 0.3)))
      (let ((entries (getf (nyaa::%read-generation path) :services)))
        (is (equal '(:value 3)
                   (getf (find :stateful-thing entries
                               :key (lambda (e) (getf e :name)))
                         :state)))))))

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

(test tool-checkpoint-save-marks-itself-unavailable-rather-than-hanging
  ;; :save runs inside the tool's own process, so snapshotting it is a
  ;; deadlock M:CALL-ALL refuses at once.
  (with-checkpoints (dir)
    (let* ((start (get-internal-real-time))
           (save (nyaa:invoke-tool :tool-checkpoint :op :save)))
      (is (< (- (get-internal-real-time) start) (* 5 internal-time-units-per-second)))
      (is (eq :ok (first save)))
      (is (equal '(:tool-checkpoint) (getf (second save) :unavailable)))
      (is (null (getf (second save) :interrupted))))))

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

;;; --- cross-process log lock (~takeiteasy/nyaa#84) --------------------------

(defmacro with-foreign-log-flock ((path) &body body)
  "BODY run while another file description holds PATH's sidecar flock, as
another process would."
  `(let ((fd (sb-posix:open (format nil "~a.lock" (nyaa::%log-key ,path))
                            (logior sb-posix:o-creat sb-posix:o-rdwr) #o644)))
     (unwind-protect
          (progn (nyaa::%flock-exclusive fd) ,@body)
       (sb-posix:close fd))))

(defun blocks-on-foreign-flock-p (path thunk)
  "True when THUNK, run on a thread, waits for PATH's flock and then finishes
once it is released."
  (let (thread finished-early)
    (with-foreign-log-flock (path)
      (setf thread (bt:make-thread thunk))
      (sleep 0.3)
      (setf finished-early (not (bt:thread-alive-p thread))))
    (bt:join-thread thread)
    (not finished-early)))

(test appending-waits-for-a-lock-held-by-another-process
  (with-generations-directory (dir)
    (let ((path (format nil "~aa.log" dir)))
      (nyaa::%append-log path '(:kind :first))
      (is-true (blocks-on-foreign-flock-p path (lambda () (nyaa::%append-log path '(:kind :x)))))
      (is (equal '((:kind :first) (:kind :x)) (nyaa::%read-log path))))))

(test the-lock-sidecar-sits-beside-the-log
  (with-generations-directory (dir)
    (let ((path (format nil "~aa.log" dir)))
      (nyaa::%append-log path '(:kind :x))
      (is-true (probe-file (format nil "~a.lock" (nyaa::%log-key path)))))))
