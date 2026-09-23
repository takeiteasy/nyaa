(in-package #:nyaa)

;;; One worker per id, so successive forms see the state the last one left.
;;; Workers start on first use; :pristine replaces one under the same id,
;;; and so does a lapsed deadline, which kills the worker it belongs to.
;;;
;;; A worker inherited through a saved core is stale: its session is reported
;;; lost once and starts empty on the next call.
;;;
;;; Trust posture: arbitrary evaluation. Trusted operator only, until the
;;; DSL gate (~takeiteasy/nyaa#6) can constrain what a form may do.
;;;
;;; TODO: meow runs one message at a time, so ids are isolated but not
;;; concurrent: a long evaluation on one blocks every other. Upgrade path:
;;; give each id its own process and delegate to it.
;;; Tracked in ~takeiteasy/nyaa#27.

(define-tool :tool-repl
    (:trust :operator
     :summary "Evaluate a Lisp form in a persistent worker, one per id"
     :slots ((workers :initform (make-hash-table :test #'equal) :reader repl-workers))
     :params ((:id string :default "default" :doc "session id")
              (:form string :required t :doc "source text of one form")
              (:pristine boolean :default nil
               :doc "restart the session's worker first")
              (:timeout (integer 1) :default +default-tool-timeout+
               :doc "kill the worker after this many milliseconds")))
  (:invoke (id form pristine timeout)
    (when pristine
      (drop-repl-worker service id))
    (let ((worker (repl-worker service id)))
      (cond
        ((null worker) (fail :unavailable))
        ((worker-stale-p worker)
         (drop-repl-worker service id)
         (fail (list :error "session lost to an image relaunch; it starts empty on the next call")))
        (t
         (let ((result (worker-eval worker form timeout)))
           ;; A worker that missed its deadline was killed; forget it so the
           ;; id starts empty rather than answering :unavailable for ever.
           (unless (worker-alive-p worker)
             (drop-repl-worker service id))
           result))))))

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
