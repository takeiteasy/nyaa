(in-package #:nyaa)

;;; The checkpoint tool: save, list and roll back generations of the
;;; harness's declared state (checkpoint.lisp, ~takeiteasy/nyaa#11).
;;;
;;; :trust :operator: writing and reverting the harness's own state is not
;;; something the default :agent trust level should reach. #12's gated
;;; self-modification tools are the intended caller of :save before a write,
;;; layered on top of this tool rather than reimplementing it.

(define-tool :tool-checkpoint
    (:trust :operator
     :summary "Save, list and roll back generations of the harness's declared state"
     :slots ((dir :initarg :dir :initform *generations-directory* :reader checkpoint-dir))
     :params ((:op (member :save :list :restore) :required t
               :doc "operation to perform")
              (:label string :doc "a note describing this generation, for :save")
              (:keep (integer 1) :doc "prune to this many newest generations, for :save")
              (:path string :doc "generation path to restore, for :restore")))
  (:invoke (op label keep path)
    (let ((context (m:service-context service)))
      (if (null context)
          (fail (list :error "not mounted under a context"))
          (case op
            (:save (op-checkpoint-save context (checkpoint-dir service) label keep))
            (:list (op-checkpoint-list (checkpoint-dir service)))
            (:restore (op-checkpoint-restore context path)))))))

(defun op-checkpoint-save (context dir label keep)
  (handler-case
      (ok :path (namestring (checkpoint (m:service-process context)
                                        :dir dir :label label :keep keep)))
    (file-error (e) (fail (list :error (princ-to-string e))))))

(defun op-checkpoint-list (dir)
  (ok :generations (generations :dir dir)))

(defun op-checkpoint-restore (context path)
  (cond
    ((null path) (bad-request ":path is required for :restore"))
    ((not (probe-file path)) (bad-request "no generation at ~a" path))
    (t (handler-case (rollback (m:service-process context) path)
         (error (e) (fail (list :error (princ-to-string e))))))))
