(defmodule nyc-agent-tests
  (behaviour ltest-unit)
  (export all))

(include-lib "ltest/include/ltest-macros.lfe")

;;; Tests for the sub-agent delegation layer: the nyc-agent-sup dynamic
;;; supervisor and nyc-agent gen_server. Each test starts a fresh nyc +
;;; nyaa application pair, starts an nyc-agent-sup under the nyaa root
;;; context's supervision, delegates sub-agents, and asserts on the
;;; tagged done message and/or monitor DOWN arriving in the parent
;;; (test) process's mailbox.
;;;
;;; Fixture agents are nyc-test-echo-agent, nyc-test-crash-agent and
;;; nyc-test-silent-agent in this app's test/ directory.

(defun with-apps (thunk)
  (application:stop 'nyaa)
  (application:stop 'nyc)
  (let ((`#(ok ,_) (application:ensure_all_started 'nyaa)))
    (funcall thunk)
    (application:stop 'nyaa)
    (application:stop 'nyc)
    ;; Stopping the apps tears down every mounted service; drain any
    ;; trailing terminate/DOWN messages so they don't leak into the
    ;; next test's mailbox (ltest runs deftests serially).
    (drain ())))

(defun start-agent-sup ()
  ;; Child of the nyaa root context so it dies with the app; named
  ;; uniquely per call to avoid local-registration collisions across
  ;; tests (the supervisor itself uses a `local` via_name).
  (let ((name (erlang:list_to_atom
                (lists:concat (list "test-agents-" (erlang:unique_integer)))))
        (`#(ok #(,root ,_)) (nyc-registry:lookup 'nyaa-root)))
    (let ((`#(ok ,pid)
           (supervisor:start_child root
                                   `#m(id name
                                       start #(nyc-agent-sup start_link (,name))
                                       restart temporary
                                       shutdown 5000
                                       type supervisor
                                       modules (nyc-agent-sup)))))
      pid)))

(defun delegate (sup fixture cbargs ref)
  (nyc-agent-sup:delegate sup fixture cbargs ref #m()))

(defun delegate-named (sup fixture cbargs ref name)
  (nyc-agent-sup:delegate sup fixture cbargs ref `#m(name ,name)))

(defun drain (acc)
  (receive
    (msg (drain (cons msg acc)))
    (after 300 (lists:reverse acc))))

(defun recv-one (timeout)
  (receive
    (m m)
    (after timeout 'timeout)))

;;; ------------------------------------------------------------------
;;; tests
;;; ------------------------------------------------------------------

(deftest delegate-starts-a-live-agent
  (with-apps
    (lambda ()
      (let ((`#(ok ,pid ,_mon) (delegate (start-agent-sup) 'nyc-test-echo-agent #m() 'ref-1)))
        (is (erlang:is_process_alive pid))))))

(deftest opt-in-name-registers-and-unregisters-the-agent
  (with-apps
    (lambda ()
      (let* ((sup (start-agent-sup))
             (`#(ok ,pid ,_mon) (delegate-named sup 'nyc-test-echo-agent #m() 'ref-1 'test-echo-1)))
        (is-match `#(ok #(,pid ,_props)) (nyc-registry:lookup 'test-echo-1))
        (is-equal 'ok (nyc-agent-sup:stop sup pid))
        (is-equal '#(error not-found) (nyc-registry:lookup 'test-echo-1))))))

(deftest delegate-without-name-never-touches-the-registry
  (with-apps
    (lambda ()
      (let ((`#(ok ,_pid ,_mon) (delegate (start-agent-sup) 'nyc-test-echo-agent #m() 'ref-1)))
        (is-equal '#(error not-found) (nyc-registry:lookup 'test-echo-1))))))

(deftest duplicate-name-registration-fails-the-second-start
  (with-apps
    (lambda ()
      (let* ((sup (start-agent-sup))
             (`#(ok ,_pid ,_mon) (delegate-named sup 'nyc-test-echo-agent #m() 'ref-1 'test-echo-dup)))
        (is-match `#(error ,_reason) (delegate-named sup 'nyc-test-echo-agent #m() 'ref-2 'test-echo-dup))))))

(deftest cast-prompt-delivers-and-call-prompt-replies
  (with-apps
    (lambda ()
      (let* ((sup (start-agent-sup))
            (`#(ok ,pid ,_mon) (delegate sup 'nyc-test-echo-agent `#m(parent ,(self)) 'ref-1)))
        ;; Fire-and-forget: a cast handler's #(reply ...) is dropped, so
        ;; the fixture instead sends the echoed value to `parent`
        ;; (supplied via cbargs) as a bare message.
        (nyc-agent:prompt pid '#(echo hello))
        (is-equal 'hello (recv-one 500))
        ;; Blocking: the reply is the return value.
        (is-equal 'world (nyc-agent:prompt-wait pid '#(echo world)))))))

(deftest done-on-call-path-sends-tagged-done-and-replies-ok
  (with-apps
    (lambda ()
      (let* ((sup (start-agent-sup))
            (`#(ok ,pid ,_mon) (delegate-named sup 'nyc-test-echo-agent #m() 'ref-42 'test-echo-done)))
        (is-equal 'ok (nyc-agent:prompt-wait pid '#(finish all-done)))
        (is-match `#(nyc-agent done ref-42 ,pid all-done) (recv-one 500))
        ;; The agent stopped normally after deciding it was done...
        (timer:sleep 50)
        (is-not (erlang:is_process_alive pid))
        ;; ...and its registration is gone.
        (is-equal '#(error not-found) (nyc-registry:lookup 'test-echo-done))))))

(deftest done-on-cast-path-sends-tagged-done
  (with-apps
    (lambda ()
      (let* ((sup (start-agent-sup))
            (`#(ok ,pid ,_mon) (delegate sup 'nyc-test-echo-agent #m() 'ref-7)))
        (nyc-agent:prompt pid '#(finish cast-done))
        (is-match `#(nyc-agent done ref-7 ,pid cast-done) (recv-one 500))
        (timer:sleep 50)
        (is-not (erlang:is_process_alive pid))))))

(deftest supervisor-survives-sub-agent-crash-and-still-delegates
  (with-apps
    (lambda ()
      (let* ((sup (start-agent-sup))
            (`#(ok ,pid ,_mon) (delegate sup 'nyc-test-crash-agent #m() 'ref-1)))
        (nyc-agent:prompt pid '#(boom))
        ;; Wait for the crash to land before asserting on liveness.
        (timer:sleep 100)
        (is-not (erlang:is_process_alive pid))
        (is (erlang:is_process_alive sup))
        (let ((`#(ok ,pid2 ,_mon2) (delegate sup 'nyc-test-echo-agent #m() 'ref-2)))
          (is (erlang:is_process_alive pid2)))))))

(deftest delegate-monitor-yields-down-on-crash
  (with-apps
    (lambda ()
      (let* ((sup (start-agent-sup))
             (`#(ok ,pid ,mon) (delegate sup 'nyc-test-crash-agent #m() 'ref-1)))
        (nyc-agent:prompt pid '#(boom))
        (is-match `#(DOWN ,mon process ,pid ,_reason) (recv-one 500))))))

(deftest explicit-stop-runs-the-disposer-and-unregisters
  (with-apps
    (lambda ()
      (let* ((sup (start-agent-sup))
             (`#(ok ,pid ,_mon) (delegate-named sup 'nyc-test-echo-agent #m() 'ref-1 'test-echo-stop)))
        (is-equal 'ok (nyc-agent-sup:stop sup pid))
        (is-not (erlang:is_process_alive pid))
        (is-equal '#(error not-found) (nyc-registry:lookup 'test-echo-stop))))))

(deftest missing-handle-message-callback-is-a-no-op-default
  (with-apps
    (lambda ()
      (let* ((sup (start-agent-sup))
            (`#(ok ,pid ,_mon) (delegate sup 'nyc-test-silent-agent #m() 'ref-1)))
        ;; Cast is fire-and-forget: no crash even though the fixture has
        ;; no handle-message/2 at all.
        (nyc-agent:prompt pid '#(ignored))
        (is (erlang:is_process_alive pid))))))

(deftest done-message-ref-matches-the-delegation-ref
  (with-apps
    (lambda ()
      ;; Two concurrent delegations from one parent are distinguishable
      ;; by their refs -- that is the whole point of the tagged message.
      (let* ((sup (start-agent-sup))
             (`#(ok ,a ,_mon-a) (delegate sup 'nyc-test-echo-agent #m() 'ref-a))
             (`#(ok ,b ,_mon-b) (delegate sup 'nyc-test-echo-agent #m() 'ref-b)))
        (nyc-agent:prompt-wait b '#(finish from-b))
        (is-match `#(nyc-agent done ref-b ,b from-b) (recv-one 500))
        (drain ())))))

(deftest two-concurrently-named-agents-of-the-same-module-coexist
  (with-apps
    (lambda ()
      ;; The registry collision this used to have: two live sub-agents
      ;; of the same callback module, distinctly named, must not
      ;; clobber each other's registration.
      (let* ((sup (start-agent-sup))
             (`#(ok ,a ,_mon-a) (delegate-named sup 'nyc-test-echo-agent #m() 'ref-a 'test-echo-a))
             (`#(ok ,b ,_mon-b) (delegate-named sup 'nyc-test-echo-agent #m() 'ref-b 'test-echo-b)))
        (is-match `#(ok #(,a ,_props-a)) (nyc-registry:lookup 'test-echo-a))
        (is-match `#(ok #(,b ,_props-b)) (nyc-registry:lookup 'test-echo-b))))))
