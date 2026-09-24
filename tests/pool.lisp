(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; The shared worker pools: thread reuse, each tier's cap, and withdrawing a
;;; job that has not started.

(defun pool-threads ()
  (remove-if-not (lambda (thread) (search "nyaa-pool" (or (bt:thread-name thread) "")))
                 (bt:all-threads)))

(test the-pool-reuses-threads
  (with-protocol
    (apply #'nyaa:complete :protocol-echo (hello))
    (let ((spawned (getf (nyaa:pool-stats :protocol) :spawned)))
      (dotimes (i 10)
        (is (eq :ok (first (apply #'nyaa:complete :protocol-echo (hello))))))
      (is (<= (- (getf (nyaa:pool-stats :protocol) :spawned) spawned) 1)))))

(test a-tier-never-exceeds-its-size
  (with-pool-sizes (:protocol 2)
    (with-protocol
      (let* ((peak 0)
             (done nil)
             (poller (bt:make-thread
                      (lambda ()
                        (loop until done
                              do (setf peak (max peak (getf (nyaa:pool-stats :protocol) :threads)))
                                 (sleep 0.01)))))
             (start (get-internal-real-time))
             (results (concurrently 5 (lambda ()
                                        (apply #'nyaa:complete :protocol-echo
                                               (hello :delay 0.3))))))
        (setf done t)
        (bt:join-thread poller)
        (is (every (lambda (result) (eq :ok (first result))) results))
        (is (<= peak 2))
        (is (>= (elapsed-since start) 0.85))))))

(test one-thread-per-tier-does-not-deadlock
  (with-pool-sizes (:tool 1 :turn 1 :provider 1 :protocol 1)
    (call-with-echo-provider
     (lambda (context)
       (let* ((agent (in-thread (lambda ()
                                  (nyaa:run-agent context :model :provider-test-echo
                                                          :tools '()
                                                          :messages '((:role :user :content "hi"))))))
              (results (concurrently 3 (lambda () (turn :provider-test-echo :delay 0.1)))))
         (is (every (lambda (result) (eq :ok (first result))) results))
         (is (eq :stop (getf (second (bt:join-thread agent)) :stop-reason))))))))

(test withdrawing-is-exact
  (let* ((pool (nyaa::%make-pool :test 1))
         (release (bt:make-semaphore))
         (blocker (nyaa::make-pool-job (lambda () (bt:wait-on-semaphore release :timeout 5))))
         (queued (nyaa::make-pool-job (lambda ()))))
    (unwind-protect
         (progn
           (is-false (nyaa::pool-submit pool blocker))
           (is-true (eventually (lambda () (eq :running (nyaa::pool-job-state blocker)))))
           (is-true (nyaa::pool-submit pool queued))
           (is-true (nyaa::pool-withdraw queued))
           (is-false (nyaa::pool-withdraw queued))
           (is-false (nyaa::pool-withdraw blocker)))
      (bt:signal-semaphore release)
      (bt:with-lock-held ((nyaa::pool-lock pool))
        (setf (nyaa::pool-retiring pool) t)
        (bt:condition-broadcast (nyaa::pool-cv pool))))
    (is-true (eventually (lambda () (zerop (nyaa::pool-threads pool)))))))

(test a-key-at-its-limit-holds-no-thread
  (let* ((pool (nyaa::%make-pool :test 4))
         (release (bt:make-semaphore))
         (jobs (loop repeat 3
                     collect (nyaa::make-pool-job
                              (lambda () (bt:wait-on-semaphore release :timeout 5))
                              :key :k :limit 1))))
    (unwind-protect
         (progn
           (dolist (job jobs) (nyaa::pool-submit pool job))
           (sleep 0.1)
           (is (= 1 (nyaa::pool-threads pool)))
           (is (= 2 (length (nyaa::pool-queue pool)))))
      (dotimes (i 3) (bt:signal-semaphore release))
      (is-true (eventually (lambda () (null (nyaa::pool-queue pool)))))
      (bt:with-lock-held ((nyaa::pool-lock pool))
        (setf (nyaa::pool-retiring pool) t)
        (bt:condition-broadcast (nyaa::pool-cv pool))))))

(test idle-threads-retire
  (with-protocol
    (apply #'nyaa:complete :protocol-echo (hello)))
  (nyaa::retire-idle-workers)
  (is-true (eventually (lambda () (null (pool-threads))))))
