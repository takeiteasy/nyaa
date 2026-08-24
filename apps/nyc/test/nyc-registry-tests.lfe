(defmodule nyc-registry-tests
  (behaviour ltest-unit)
  (export all))

(include-lib "ltest/include/ltest-macros.lfe")

;;; nyc-registry is a singleton registered under the fixed local name
;;; 'nyc-registry (its client API hardcodes that name), so tests share
;;; one instance rather than running isolated. with-registry/1 gives
;;; each test a fresh instance and guarantees teardown via try/after, so
;;; a crashing test doesn't leave a stale registration wedging every
;;; test that runs after it. It also drains the calling process's own
;;; mailbox after teardown: ltest runs every deftest body in the same
;;; process, not one process per test, so a subscription a test forgot
;;; to unsubscribe (or a notification still in flight when the test
;;; finished) would otherwise bleed into the next test's first receive.

(defun drain (acc)
  (receive
    (msg (drain (cons msg acc)))
    (after 50 (lists:reverse acc))))

(defun with-registry (thunk)
  (case (erlang:whereis 'nyc-registry)
    ('undefined 'ok)
    (pid (catch (gen_server:stop pid))))
  (nyc-registry:start_link)
  (try
    (funcall thunk)
    (after
      (catch (gen_server:stop 'nyc-registry))
      (drain ()))))

(deftest register-lookup-unregister-roundtrip
  (with-registry
    (lambda ()
      (is-equal 'ok (nyc-registry:register 'svc (self) #m(k v)))
      (is-equal `#(ok #(,(self) #m(k v))) (nyc-registry:lookup 'svc))
      (is-equal 'ok (nyc-registry:unregister 'svc))
      (is-equal '#(error not-found) (nyc-registry:lookup 'svc)))))

(deftest duplicate-registration-of-live-pid-is-an-error
  (with-registry
    (lambda ()
      (nyc-registry:register 'svc (self) #m())
      (is-match `#(error #(already-registered ,_)) (nyc-registry:register 'svc (self) #m())))))

;;; --- await ---------------------------------------------------------

(deftest await-returns-immediately-when-already-present
  (with-registry
    (lambda ()
      (nyc-registry:register 'svc (self) #m())
      (is-equal `#(ok ,(self)) (nyc-registry:await 'svc 1000)))))

(deftest await-timeout-leaves-no-leak
  (with-registry
    (lambda ()
      (is-equal '#(error timeout) (nyc-registry:await 'nope 100))
      (let ((state (sys:get_state 'nyc-registry)))
        (is-equal #m() (maps:get 'waiters state))
        (is-equal #m() (maps:get 'timer-waiter state))
        (is-equal #m() (maps:get 'callermon-waiter state))))))

(deftest await-caller-death-is-reaped
  (with-registry
    (lambda ()
      (let ((caller (spawn (lambda () (nyc-registry:await 'nope-yet 5000)))))
        (timer:sleep 50)
        (exit caller 'kill)
        (timer:sleep 50)
        (let ((state (sys:get_state 'nyc-registry)))
          (is-equal #m() (maps:get 'waiters state))
          (is-equal #m() (maps:get 'callermon-waiter state))
          (is-equal #m() (maps:get 'timer-waiter state)))))))

;;; --- subscribe -------------------------------------------------------

(deftest subscribe-replays-existing-registration-immediately
  (with-registry
    (lambda ()
      (nyc-registry:register 'svc (self) #m())
      (nyc-registry:subscribe 'svc)
      (receive
        (`#(nyc-registry registered svc ,pid) (is-equal (self) pid))
        (after 200 (is 'false))))))

(deftest subscribe-to-absent-name-sends-nothing-until-registered
  (with-registry
    (lambda ()
      (nyc-registry:subscribe 'svc)
      (receive
        (_ (is 'false))
        (after 100 (is 'true)))
      (nyc-registry:register 'svc (self) #m())
      (receive
        (`#(nyc-registry registered svc ,pid) (is-equal (self) pid))
        (after 200 (is 'false))))))

(deftest subscriber-death-drops-its-subscriptions
  (with-registry
    (lambda ()
      (let ((sub (spawn (lambda () (nyc-registry:subscribe 'svc) (timer:sleep 5000)))))
        (timer:sleep 50)
        (exit sub 'kill)
        (timer:sleep 50)
        (let ((state (sys:get_state 'nyc-registry)))
          (is-equal #m() (maps:get 'subs state))
          (is-equal #m() (maps:get 'sub-mon state))
          (is-equal #m() (maps:get 'mon-sub state)))))))

;;; --- unregistered-pid-death cleans up the registration too ----------

(deftest registered-pid-death-deregisters-and-notifies-subs
  (with-registry
    (lambda ()
      ;; Subscribe before registering, so the only replay we get is the
      ;; real registration -- not subscribe's immediate-replay path
      ;; (already covered above), which would otherwise be the first
      ;; message in the mailbox and mask the one this test is about.
      (nyc-registry:subscribe 'svc)
      (let ((svc-pid (spawn (lambda () (receive (_ 'ok))))))
        (nyc-registry:register 'svc svc-pid #m())
        (receive
          (`#(nyc-registry registered svc ,pid) (is-equal svc-pid pid))
          (after 200 (is 'false)))
        (exit svc-pid 'kill)
        (receive
          (`#(nyc-registry unregistered svc ,reason) (is-equal 'killed reason))
          (after 500 (is 'false)))
        (is-equal '#(error not-found) (nyc-registry:lookup 'svc))))))

;;; --- re-registration racing the old pid's DOWN ----------------------
;;;
;;; A supervisor restarting a dead child can complete -- and the new
;;; child can call register/3 -- before the registry has processed its
;;; own monitor DOWN for the old pid (both are independent, async signal
;;; paths triggered by the same kill). do-register-fresh must handle
;;; this regardless of which message wins the race, or the eventual
;;; stale DOWN tears down the live new registration and wrongly
;;; broadcasts `unregistered` for a process that's still alive. This is
;;; forced deterministically with sys:suspend/resume rather than relying
;;; on the ordinary timing (which happened, in practice, to almost
;;; always favor DOWN-first and mask the bug during manual testing).

(deftest re-registration-survives-a-losing-race-against-old-down
  (with-registry
    (lambda ()
      (let ((old-pid (spawn (lambda () (receive (_ 'ok))))))
        (nyc-registry:register 'svc old-pid #m())
        (nyc-registry:subscribe 'svc)
        (receive (`#(nyc-registry registered svc ,_) 'ok) (after 200 (is 'false)))
        (let ((new-pid (spawn (lambda () (receive (_ 'ok))))))
          (sys:suspend 'nyc-registry)
          ;; Both now queue up behind the suspend, in this order: the
          ;; new registration lands in the mailbox first, the old pid's
          ;; DOWN second -- the losing order for the naive implementation.
          (spawn (lambda () (nyc-registry:register 'svc new-pid #m())))
          (timer:sleep 50)
          (exit old-pid 'kill)
          (timer:sleep 50)
          (sys:resume 'nyc-registry)
          (timer:sleep 100)
          (is-equal `#(ok #(,new-pid #m())) (nyc-registry:lookup 'svc))
          (let ((state (sys:get_state 'nyc-registry)))
            (is-equal 1 (maps:size (maps:get 'mon-reg state)))
            (is-equal 1 (maps:size (maps:get 'reg-mon state))))
          ;; No spurious `unregistered` for the still-live new pid.
          (receive
            (`#(nyc-registry unregistered svc ,_) (is 'false))
            (after 200 (is 'true))))))))
