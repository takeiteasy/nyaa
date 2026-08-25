(defmodule patchbay-test-echo-agent
  (export
    (init 1)
    (handle_message 2)))

;;; Echo fixture for patchbay-agent-tests. On the call path, #(echo Msg)
;;; replies with Msg. On the cast path there is no caller to reply to,
;;; so #(echo Msg) instead sends Msg directly to the parent pid passed
;;; in cbargs -- this is what exercises the cast path for real, since
;;; patchbay_agent drops a cast handler's #(reply ...) on the floor.
;;; After #(finish Result) it decides it is done and returns
;;; #(done Result ...), which patchbay_agent turns into the tagged
;;; #(patchbay_agent done ref pid result) message.

(defun init (cbargs) `#(ok ,cbargs))

(defun handle_message
  ((`#(echo ,msg) state)
   (case (maps:find 'parent state)
     (`#(ok ,parent) (erlang:send parent msg))
     ('error 'ok))
   `#(reply ,msg ,state))
  ((`#(finish ,result) state) `#(done ,result ,state)))
