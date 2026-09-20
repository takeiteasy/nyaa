(in-package #:nyaa)

;;; One worker per id, so successive forms see the state the last one left.
;;; Workers start on first use; :pristine replaces one under the same id,
;;; and so does a lapsed deadline, which kills the worker it belongs to.
;;;
;;; Trust posture: arbitrary evaluation. Trusted operator only, until the
;;; DSL gate (~takeiteasy/nyaa#6) can constrain what a form may do.
;;;
;;; TODO: meow runs one message at a time, so ids are isolated but not
;;; concurrent: a long evaluation on one blocks every other. Upgrade path:
;;; give each id its own process and delegate to it.
;;; Tracked in ~takeiteasy/nyaa#27.

(m:defservice tool-repl ()
  ((workers :initform (make-hash-table :test #'equal) :reader repl-workers))
  (:name :tool-repl))

(defmethod m:metadata ((service tool-repl))
  (list :kind :tool
        :name :tool-repl
        :trust :operator
        :summary "Evaluate a Lisp form in a persistent worker, one per id"
        :params `((:id string :default "default" :doc "session id")
                  (:form string :required t :doc "source text of one form")
                  (:pristine boolean :default nil
                   :doc "restart the session's worker first")
                  (:timeout (integer 1) :default ,+default-tool-timeout+
                   :doc "kill the worker after this many milliseconds"))))

(define-tool-handler tool-repl (service args)
  (let ((id (getf args :id)))
    (when (getf args :pristine)
      (drop-repl-worker service id))
    (let ((worker (repl-worker service id)))
      (if (null worker)
          (fail :unavailable)
          (let ((result (worker-eval worker (getf args :form)
                                     (getf args :timeout))))
            ;; A worker that missed its deadline was killed; forget it so the
            ;; id starts empty rather than answering :unavailable for ever.
            (unless (worker-alive-p worker)
              (drop-repl-worker service id))
            result)))))

(defun repl-worker (service id)
  "ID's worker, started on first use. Each is held as an effect, so stopping
the service kills every worker it has."
  (or (car (gethash id (repl-workers service)))
      (let ((worker (start-worker)))
        (when worker
          (setf (gethash id (repl-workers service))
                (cons worker
                      (m:effect service
                                (lambda () (lambda () (kill-worker worker)))
                                :label (list :repl-worker id))))
          worker))))

(defun drop-repl-worker (service id)
  (let ((entry (gethash id (repl-workers service))))
    (when entry
      (remhash id (repl-workers service))
      (funcall (cdr entry)))))
