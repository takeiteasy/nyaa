(in-package #:nyaa)

;;; One session per id, so successive forms see the state the last one left.
;;; Each session is its own meow service, mounted under tool-repl's context,
;;; so a long evaluation on one id no longer blocks another: tool-repl only
;;; routes, handing its caller's reply cell to the session with
;;; M:DEFER-REPLY, and the session answers once its own worker replies.
;;; Calls on one id still run in order, since a session's own mailbox
;;; serialises them.
;;;
;;; Sessions start on first use; :pristine replaces one under the same id,
;;; and so does a lapsed deadline, which kills the worker it belongs to. A
;;; worker inherited through a saved core is stale: its session is reported
;;; lost once and starts empty on the next call.
;;;
;;; Trust posture: arbitrary evaluation. Trusted operator only, until the
;;; DSL gate (~takeiteasy/nyaa#6) can constrain what a form may do.

(defstruct worker-box
  "A session's current worker, boxed so tool-repl's cleanup can read and
kill it directly rather than asking the session -- which would queue behind
whatever call it is busy answering."
  worker)

;;; Unnamed, like an M:AGENT: several ids each mount one, and none is meant
;;; to be looked up by name. Unnamed children are invisible to CHECKPOINT
;;; (~takeiteasy/nyaa#11's %CONTEXT-ENTRIES), which is right -- a REPL
;;; session holds no state of its own worth snapshotting, only a worker.
(m:defservice repl-session ()
  ((box :initarg :box :reader session-box))
  (:default-initargs :name nil))

(defmethod m:dispose ((service repl-session) reason)
  (declare (ignore reason))
  (kill-worker (worker-box-worker (session-box service)))
  nil)

(defmethod m:handle ((service repl-session) message)
  ;; The only message a session receives: tool-repl's cast, carrying the
  ;; deferred reply cell for its own caller. If %SESSION-EVAL signals, the
  ;; session crashes and the cell is settled (:down ...) by the M:DEFER-REPLY
  ;; :UNTIL hook tool-repl installed -- no reply is dropped either way.
  (when (and (consp message) (eq (first message) :eval))
    (destructuring-bind (cell form pristine timeout) (rest message)
      (m:reply cell (%session-eval service form pristine timeout))))
  nil)

(defun %session-eval (service form pristine timeout)
  "Evaluate FORM in SERVICE's worker, started lazily and kept in its box
across calls."
  (let ((box (session-box service)))
    (when pristine
      (kill-worker (worker-box-worker box))
      (setf (worker-box-worker box) nil))
    (let ((worker (or (worker-box-worker box)
                      (setf (worker-box-worker box) (start-worker)))))
      (cond
        ((null worker) (fail :unavailable))
        ((worker-stale-p worker)
         ;; KILL-WORKER unregisters it without signalling it -- it belongs
         ;; to a process image that no longer exists here.
         (kill-worker worker)
         (setf (worker-box-worker box) nil)
         (fail (list :error "session lost to an image relaunch; it starts empty on the next call")))
        (t
         (let ((result (worker-eval worker form timeout)))
           ;; A worker that missed its deadline was killed; forget it so the
           ;; id starts empty rather than answering :unavailable for ever.
           (unless (worker-alive-p worker)
             (setf (worker-box-worker box) nil))
           result))))))

(define-tool :tool-repl
    (:trust :operator
     :summary "Evaluate a Lisp form in a persistent session, one per id"
     :slots ((sessions :initform (make-hash-table :test #'equal) :reader repl-sessions))
     :params ((:id string :default "default" :doc "session id")
              (:form string :required t :doc "source text of one form")
              (:pristine boolean :default nil
               :doc "restart the session's worker first")
              (:timeout (integer 1) :default +default-tool-timeout+
               :doc "kill the worker after this many milliseconds")))
  (:invoke (id form pristine timeout)
    (let ((session (repl-session-for service id)))
      (if (null session)
          (fail :unavailable)
          (m:cast session (list :eval (m:defer-reply :until session)
                                 form pristine timeout))))))

(defun repl-session-for (service id)
  "ID's session process, mounted on first use, or after its previous one
died. Each is held as an effect, so stopping the service kills every
session it has, and the worker each is holding along with it."
  (let ((entry (gethash id (repl-sessions service))))
    (when (and entry (not (m:process-alive-p (car entry))))
      (drop-repl-session service id)
      (setf entry nil))
    (or (and entry (car entry))
        (a:when-let* ((context (m:service-context service))
                      (process (m:service-process context)))
          (let* ((box (make-worker-box))
                 (session (m:mount process 'repl-session :box box :restart :temporary)))
            (setf (gethash id (repl-sessions service))
                  (cons session
                        (m:effect service
                                  (lambda ()
                                    (lambda ()
                                      (kill-worker (worker-box-worker box))
                                      (m:stop session)))
                                  :label (list :repl-session id))))
            session)))))

(defun drop-repl-session (service id)
  (let ((entry (gethash id (repl-sessions service))))
    (when entry
      (remhash id (repl-sessions service))
      (funcall (cdr entry)))))
