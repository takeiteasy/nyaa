(defmodule nyc-test-echo-agent
  (export
    (init 1)
    (handle-message 2)))

;;; Echo fixture for nyc-agent-tests. On the call path, #(echo Msg)
;;; replies with Msg. On the cast path there is no caller to reply to,
;;; so #(echo Msg) instead sends Msg directly to the parent pid passed
;;; in cbargs -- this is what exercises the cast path for real, since
;;; nyc-agent drops a cast handler's #(reply ...) on the floor.
;;; After #(finish Result) it decides it is done and returns
;;; #(done Result ...), which nyc-agent turns into the tagged
;;; #(nyc-agent done ref pid result) message.

(defun init (cbargs) `#(ok ,cbargs))

(defun handle-message
  ((`#(echo ,msg) state)
   (case (maps:find 'parent state)
     (`#(ok ,parent) (erlang:send parent msg))
     ('error 'ok))
    `#(reply ,msg ,state))
  ((`#(finish ,result) state) `#(done ,result ,state)))
