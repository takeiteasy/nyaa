(in-package #:nyaa)

;;; Evaluate one form in a worker that is started for it and killed after
;;; it. No state survives a call.
;;;
;;; Trust posture: arbitrary evaluation. Trusted operator only, until the
;;; DSL gate (~takeiteasy/nyaa#6) can constrain what a form may do.

(m:defservice tool-eval () ()
  (:name :tool-eval))

(defmethod m:metadata ((service tool-eval))
  (list :kind :tool
        :name :tool-eval
        :trust :operator
        :summary "Evaluate a Lisp form in a single-use worker process"
        :params '(:form "source text of one form"
                  :timeout "kill the worker after this many milliseconds")))

(define-tool-handler tool-eval (service args)
  (let ((source (arg-string (getf args :form)))
        (timeout (arg-timeout args)))
    (cond
      ((null source) (bad-request "form required, a string"))
      ((null timeout) (bad-request "timeout must be a positive number of ms"))
      (t (let ((worker (start-worker)))
           (if (null worker)
               (fail :unavailable)
               (unwind-protect (worker-eval worker source timeout)
                 (kill-worker worker))))))))
