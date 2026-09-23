(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; The worker protocol on its own, below the tools that use it: the
;;; handshake, one exchange, and what a lapsed deadline leaves behind.

(defmacro with-worker ((worker) &body body)
  `(let ((,worker (nyaa::start-worker)))
     (unwind-protect (progn (is (not (null ,worker))) ,@body)
       (nyaa::kill-worker ,worker))))

(test worker-round-trips-a-form
  (with-worker (w)
    (let ((result (nyaa::worker-eval w "(list 1 2)" 5000)))
      (is (equal "(1 2)" (getf (second result) :value))))))

(test worker-is-unavailable-when-it-cannot-start
  (let ((nyaa:*worker-command* (list "/nonexistent/lisp" "--eval")))
    (is (null (nyaa::start-worker)))))

(test worker-dies-with-its-deadline
  (with-worker (w)
    (is (eq :timeout (nyaa:tool-error (nyaa::worker-eval w "(loop)" 500))))
    (is (not (nyaa::worker-alive-p w)))
    ;; A dead worker answers, rather than blocking a caller that reuses it.
    (is (eq :unavailable (nyaa:tool-error (nyaa::worker-eval w "1" 500))))))

(test stale-worker-reads-dead-and-is-never-signalled
  (let* ((worker (nyaa::start-worker))
         (boot nyaa::*boot*))
    (unwind-protect
         (progn
           (setf nyaa::*boot* (list :later-boot))
           (is (nyaa::worker-stale-p worker))
           (is (not (nyaa::worker-alive-p worker)))
           (nyaa::kill-worker worker)
           (is (uiop:process-alive-p (nyaa::worker-process worker))))
      (setf nyaa::*boot* boot)
      (nyaa::terminate-process-group (nyaa::worker-process worker)))))

(test kill-live-workers-kills-each-registered-worker
  (let ((nyaa::*live-workers* '())
        (nyaa::*live-workers-lock* (bt:make-lock)))
    (let ((workers (list (nyaa::start-worker) (nyaa::start-worker))))
      (is (= 2 (length nyaa::*live-workers*)))
      (nyaa::kill-live-workers)
      (is (null nyaa::*live-workers*))
      (is (notany #'nyaa::worker-alive-p workers)))))
