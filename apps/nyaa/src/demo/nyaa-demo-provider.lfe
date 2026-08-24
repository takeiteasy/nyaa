(defmodule nyaa-demo-provider
  (export
    (child_spec 1)
    (service-name 0)
    (dependencies 0)
    (init 1)
    (ready 2)
    (handle-message 2)
    (terminate 2)))

;;; Half of the vertical-slice demo (see docs/plugins.md). Declares no
;;; dependencies, so nyc-service transitions it to 'ready right in
;;; init/1 -- there's no one to wait for.

(defun child_spec (reporter)
  `#m(id demo-provider
      start #(nyc-service start_link (nyaa-demo-provider ,reporter))
      restart transient
      shutdown 5000
      type worker
      modules (nyc-service)))

(defun service-name () 'demo-provider)
(defun dependencies () '())

(defun init (reporter)
  `#(ok #m(reporter ,reporter)))

(defun ready (_deps state)
  (erlang:send (maps:get 'reporter state) '#(provider ready))
  `#(ok ,state))

(defun handle-message
  (('ping state) `#(reply pong ,state))
  ((_msg state) `#(ok ,state)))

(defun terminate (reason state)
  (erlang:send (maps:get 'reporter state) `#(provider terminated ,reason))
  'ok)
