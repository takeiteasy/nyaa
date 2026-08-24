(defmodule nyc-context
  (behaviour supervisor)
  (export
    (start_link 2)
    (mount 2)
    (unmount 2)
    (children 1))
  (export
    (init 1)))

;;; A context is a supervisor -- one per composition boundary (see
;;; docs/architecture.md). A context registers *itself* in nyc-registry
;;; under `name` during init/1, before start_link/2 returns to its
;;; caller, so nested contexts are discoverable exactly like any other
;;; service: mounting a child spec whose module is another nyc-context
;;; is all a nested context is. No separate mechanism needed.
;;;
;;; Restart strategy is one_for_one; individual child specs decide their
;;; own restart type (permanent/transient/temporary) -- see the callers
;;; in nyc-service and the demo plugin. `transient` is the recommended
;;; default, overridable per plugin via the child spec, not hardcoded here.

(defun start_link (name opts)
  (supervisor:start_link 'nyc-context `#(,name ,opts)))

(defun init
  ((`#(,name ,opts))
    (nyc-registry:register name (self) opts)
    (let ((sup-flags #m(strategy one_for_one
                         intensity 5
                         period 10)))
      `#(ok #(,sup-flags ())))))

(defun mount (ctx child-spec)
  (supervisor:start_child ctx child-spec))

(defun unmount (ctx id)
  (case (supervisor:terminate_child ctx id)
    ('ok (supervisor:delete_child ctx id))
    (other other)))

(defun children (ctx)
  (supervisor:which_children ctx))
