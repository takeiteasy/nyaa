(defmodule nyc-test-crash-agent
  (export
    (init 1)
    (handle-message 2)))

;;; Crash fixture for nyc-agent-tests: any prompt crashes it -- for the
;;; crash-isolation test (a dead sub-agent must not take down its
;;; nyc-agent-sup, which is temporary-restart so it won't even retry).

(defun init (_args) `#(ok #m()))

(defun handle-message (_msg _state) (erlang:error 'boom))
