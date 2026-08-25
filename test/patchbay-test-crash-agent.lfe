(defmodule patchbay-test-crash-agent
  (export
    (init 1)
    (handle_message 2)))

;;; Crash fixture for patchbay-agent-tests: any prompt crashes it -- for
;;; the crash-isolation test (a dead sub-agent must not take down its
;;; patchbay_agent_sup, which is temporary-restart so it won't even retry).

(defun init (_args) `#(ok #m()))

(defun handle_message (_msg _state) (erlang:error 'boom))
