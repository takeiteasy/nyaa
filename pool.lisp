(in-package #:nyaa)

;;; Shared worker pools. Work that only waits -- a completion -- runs on a
;;; pooled thread rather than one spawned for it, and each tier caps how many
;;; threads it keeps. A job may carry a key and a limit: no more than LIMIT
;;; jobs of one key run at once, and a job held back by its key waits in the
;;; queue without holding a thread.
;;;
;;; The tiers are ordered :PROVIDER > :PROTOCOL, and a job only ever waits on
;;; work in a lower tier, so a full tier can never be waiting on itself. See
;;; docs/protocols.md.

(defparameter *pool-sizes* '(:provider 64 :protocol 64)
  "The most threads each tier keeps, read when the tier's pool is first
used. Nil for a tier leaves it uncapped.")

(defparameter *pool-idle-seconds* 30
  "Seconds a pooled thread waits for work before it exits.")

(defstruct (pool (:constructor %make-pool (tier max-threads)))
  tier max-threads
  (lock (bt:make-lock :name "nyaa-pool"))
  (cv (bt:make-condition-variable))
  (queue '())
  (threads 0) (idle 0) (starting 0) (spawned 0)
  (running-by-key (make-hash-table :test 'eq))
  retiring)

(defstruct (pool-job (:constructor make-pool-job
                         (function &key key limit (registry m:*registry*))))
  function key limit registry pool (state :queued))

(defvar *pools* (make-hash-table :test 'eq))
(defvar *pools-lock* (bt:make-lock :name "nyaa-pools"))

(defun tier-pool (tier)
  (bt:with-lock-held (*pools-lock*)
    (or (gethash tier *pools*)
        (setf (gethash tier *pools*) (%make-pool tier (getf *pool-sizes* tier))))))

(defun %key-running (pool key)
  (if key (gethash key (pool-running-by-key pool) 0) 0))

(defun %runnable-p (pool job)
  (let ((limit (pool-job-limit job)))
    (or (null limit) (< (%key-running pool (pool-job-key job)) limit))))

(defun %runnable-count (pool)
  "How many queued jobs could start now, each key counted up to its limit."
  (let ((taken '()))
    (count-if (lambda (job)
                (let* ((key (pool-job-key job))
                       (limit (pool-job-limit job))
                       (cell (or (assoc key taken)
                                 (car (push (cons key (%key-running pool key)) taken)))))
                  (when (or (null limit) (< (cdr cell) limit))
                    (incf (cdr cell)))))
              (pool-queue pool))))

(defun %room-p (pool)
  (let ((max (pool-max-threads pool)))
    (or (null max) (< (pool-threads pool) max))))

(defun pool-submit (pool job)
  "Queue JOB on POOL and wake or start a thread for it. Never blocks. True
when JOB cannot start at once: its key is at its limit or the tier is full."
  (bt:with-lock-held ((pool-lock pool))
    (setf (pool-job-pool job) pool
          (pool-queue pool) (append (pool-queue pool) (list job)))
    (not (and (%runnable-p pool job)
              ;; A thread still starting will scan the queue too.
              (cond ((<= (%runnable-count pool) (+ (pool-idle pool) (pool-starting pool)))
                     (bt:condition-notify (pool-cv pool))
                     t)
                    ((%room-p pool)
                     (%spawn-pool-worker pool)
                     t))))))

(defun pool-withdraw (job)
  "Take JOB off its queue. True only when it had not started, so exactly one
of withdrawing it and running it ever happens."
  (a:when-let ((pool (pool-job-pool job)))
    (bt:with-lock-held ((pool-lock pool))
      (when (eq (pool-job-state job) :queued)
        (setf (pool-job-state job) :withdrawn
              (pool-queue pool) (remove job (pool-queue pool)))
        t))))

(defun %spawn-pool-worker (pool)
  "Called holding POOL's lock."
  (incf (pool-threads pool))
  (incf (pool-starting pool))
  (incf (pool-spawned pool))
  (m:spawn (lambda () (pool-worker-loop pool))
           :name (format nil "nyaa-pool-~(~a~)" (pool-tier pool))))

(defun %take-job (pool)
  "The first queued job its key lets start, marked running. Called holding
POOL's lock."
  (a:when-let ((job (find-if (lambda (job) (%runnable-p pool job)) (pool-queue pool))))
    (setf (pool-job-state job) :running
          (pool-queue pool) (remove job (pool-queue pool)))
    (a:when-let ((key (pool-job-key job)))
      (incf (gethash key (pool-running-by-key pool) 0)))
    job))

(defun %next-job (pool)
  "Wait for a job to run, or nil once this thread should exit: idle past
*POOL-IDLE-SECONDS*, retiring, or over a lowered cap. An exiting thread is
uncounted here, under the lock, so a lowered cap sheds exactly the excess."
  (bt:with-lock-held ((pool-lock pool))
    (flet ((leave () (decf (pool-threads pool)) nil))
      (loop
        (when (and (pool-max-threads pool) (> (pool-threads pool) (pool-max-threads pool)))
          ;; Pass on a wakeup this thread may have taken for a job.
          (bt:condition-notify (pool-cv pool))
          (return (leave)))
        (a:when-let ((job (%take-job pool)))
          (return job))
        (when (pool-retiring pool)
          (return (leave)))
        (incf (pool-idle pool))
        (let ((woken (bt:condition-wait (pool-cv pool) (pool-lock pool)
                                        :timeout *pool-idle-seconds*)))
          (decf (pool-idle pool))
          (unless (or woken (find-if (lambda (job) (%runnable-p pool job))
                                     (pool-queue pool)))
            (return (leave))))))))

(defun %finish-job (pool job)
  (bt:with-lock-held ((pool-lock pool))
    (a:when-let ((key (pool-job-key job)))
      (when (zerop (decf (gethash key (pool-running-by-key pool))))
        (remhash key (pool-running-by-key pool))))
    ;; A job its key held back may start now.
    (bt:condition-notify (pool-cv pool))))

(defun pool-worker-loop (pool)
  (let ((job nil))
    (bt:with-lock-held ((pool-lock pool))
      (decf (pool-starting pool)))
    (unwind-protect
         (loop while (setf job (%next-job pool))
               do (let ((m:*registry* (pool-job-registry job)))
                    (handler-case (funcall (pool-job-function job))
                      (error () nil)))
                  (%finish-job pool (shiftf job nil)))
      ;; Killed mid-job rather than leaving through %NEXT-JOB.
      (when job
        (%finish-job pool job)
        (bt:with-lock-held ((pool-lock pool))
          (decf (pool-threads pool)))))))

(defun pool-stats (tier)
  (let ((pool (tier-pool tier)))
    (bt:with-lock-held ((pool-lock pool))
      (list :threads (pool-threads pool) :idle (pool-idle pool)
            :queued (length (pool-queue pool))
            :running (- (pool-threads pool) (pool-idle pool))
            :spawned (pool-spawned pool)))))

(defun retire-idle-workers (&key (timeout 5))
  "Have every idle pooled thread exit, waiting at most TIMEOUT seconds. The
next job starts a thread again."
  (let ((pools (bt:with-lock-held (*pools-lock*) (a:hash-table-values *pools*)))
        (deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (dolist (pool pools)
      (bt:with-lock-held ((pool-lock pool))
        (setf (pool-retiring pool) t)
        (bt:condition-broadcast (pool-cv pool))))
    (unwind-protect
         (loop until (or (every (lambda (pool)
                                  (bt:with-lock-held ((pool-lock pool))
                                    (zerop (pool-idle pool))))
                                pools)
                         (> (get-internal-real-time) deadline))
               do (sleep 0.01))
      (dolist (pool pools)
        (bt:with-lock-held ((pool-lock pool))
          (setf (pool-retiring pool) nil))))))

(defun forget-pools ()
  "Start a new process image's pools empty: the threads the old ones counted
did not survive the save."
  (bt:with-lock-held (*pools-lock*)
    (setf *pools* (make-hash-table :test 'eq))))
