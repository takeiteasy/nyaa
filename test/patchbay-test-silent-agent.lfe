(defmodule patchbay-test-silent-agent
  (export
    (init 1)))

;;; Silent fixture for patchbay-agent-tests: declares no handle_message/2
;;; at all -- exercises the optional-callback default (a cast must be a
;;; harmless no-op, not a crash).

(defun init (_args) `#(ok #m()))
