(defmodule nyaa-demo-consumer
  (export
    (child_spec 1)
    (service_name 0)
    (dependencies 0)
    (init 1)
    (ready 2)
    (dep_down 3)
    (terminate 2)))

;;; The other half of the vertical-slice demo (see docs/plugins.md).
;;; Declares demo-provider as a dependency and can be mounted before,
;;; after, or independent of it -- that's the property being proven.

(defun child_spec (reporter)
  `#m(id demo-consumer
      start #(patchbay_service start_link (nyaa-demo-consumer ,reporter))
      restart transient
      shutdown 5000
      type worker
      modules (patchbay_service)))

(defun service_name () 'demo-consumer)
(defun dependencies () '(demo-provider))

(defun init (reporter)
  (erlang:send reporter '#(consumer waiting))
  `#(ok #m(reporter ,reporter)))

(defun ready (deps state)
  (let ((provider-pid (maps:get 'demo-provider deps)))
    (erlang:send (maps:get 'reporter state) `#(consumer ready ,provider-pid)))
  `#(ok ,state))

(defun dep_down (dep-name reason state)
  (erlang:send (maps:get 'reporter state) `#(consumer dep-down ,dep-name ,reason))
  `#(ok ,state))

(defun terminate (reason state)
  (erlang:send (maps:get 'reporter state) `#(consumer terminated ,reason))
  'ok)
