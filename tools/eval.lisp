(in-package #:nyaa)

;;; Evaluate one form in a worker that is started for it and killed after
;;; it. No state survives a call.
;;;
;;; Trust posture: arbitrary evaluation. Trusted operator only, until the
;;; DSL gate (~takeiteasy/nyaa#6) can constrain what a form may do.

(define-tool :tool-eval
    (:trust :operator
     :summary "Evaluate a Lisp form in a single-use worker process"
     :params ((:form string :required t :doc "source text of one form")
              (:timeout (integer 1) :default +default-tool-timeout+
               :doc "kill the worker after this many milliseconds")))
  (:invoke (form timeout)
    (let ((worker (start-worker)))
      (if (null worker)
          (fail :unavailable)
          (unwind-protect
               (worker-eval worker form timeout)
            (kill-worker worker))))))
