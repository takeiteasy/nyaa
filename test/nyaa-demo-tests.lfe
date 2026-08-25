(defmodule nyaa-demo-tests
  (behaviour ltest-unit)
  (export all))

(include-lib "ltest/include/ltest-macros.lfe")

;;; The vertical-slice test: a plugin mounted before its dependency
;;; exists does not crash, does not block, and becomes ready on its own
;;; once the dependency appears -- the demand-driven dependency injection
;;; property this runtime exists to provide (see docs/registry.md). Both
;;; mount orders are tested, since the
;;; provider-first order is the one that exercises subscribe's replay
;;; of an already-existing registration (see patchbay_registry.lfe) rather
;;; than a live #(patchbay_registry registered ...) message.
;;;
;;; Each test starts its own patchbay + nyaa application pair and drains a
;;; reporter mailbox rather than depending on message arrival order
;;; between unrelated services -- the provider always sends its own
;;; {provider, ready} on every (re)start regardless of what the
;;; consumer is doing, so asserting order across both would be asserting
;;; on a race that isn't actually part of the contract.

(defun with-apps (thunk)
  (application:stop 'nyaa)
  (application:stop 'patchbay)
  (let ((`#(ok ,_) (application:ensure_all_started 'nyaa)))
    (try
      (funcall thunk)
      (after
        (application:stop 'nyaa)
        (application:stop 'patchbay)
        ;; Stopping the apps tears down every mounted service, which
        ;; fires their terminate/2 disposers -- those send their own
        ;; {X, terminated, _} messages to this same reporter process a
        ;; moment later. Tests share one process (ltest runs deftest
        ;; bodies serially, not one-process-per-test), so without this
        ;; flush that trailing noise lands in the *next* test's mailbox
        ;; instead of this one's.
        (drain ())))))

(defun root-ctx ()
  (let ((`#(ok #(,pid ,_)) (patchbay_registry:lookup 'nyaa-root)))
    pid))

(defun drain (acc)
  (receive
    (msg (drain (cons msg acc)))
    (after 300 (lists:reverse acc))))

(defun expect (msg timeout)
  (receive
    (m (is-equal msg m))
    (after timeout (is-equal msg 'timeout))))

(deftest consumer-mounted-before-provider-becomes-ready
  (with-apps
    (lambda ()
      (let* ((ctx (root-ctx))
             (reporter (self))
             (`#(ok ,_) (patchbay_context:mount ctx (nyaa-demo-consumer:child_spec reporter))))
        (expect '#(consumer waiting) 500)
        (let ((`#(ok ,_) (patchbay_context:mount ctx (nyaa-demo-provider:child_spec reporter))))
          'ok)
        (let ((msgs (drain ())))
          (is (lists:any (match-lambda ((`#(consumer ready ,_)) 'true) ((_) 'false)) msgs))
          (is (lists:member '#(provider ready) msgs)))))))

(deftest provider-mounted-before-consumer-becomes-ready
  (with-apps
    (lambda ()
      (let* ((ctx (root-ctx))
             (reporter (self))
             (`#(ok ,_) (patchbay_context:mount ctx (nyaa-demo-provider:child_spec reporter))))
        (expect '#(provider ready) 500)
        (let ((`#(ok ,_) (patchbay_context:mount ctx (nyaa-demo-consumer:child_spec reporter))))
          'ok)
        (let ((msgs (drain ())))
          (is (lists:member '#(consumer waiting) msgs))
          (is (lists:any (match-lambda ((`#(consumer ready ,_)) 'true) ((_) 'false)) msgs)))))))

(deftest provider-kill-triggers-dep-down-then-re-ready
  (with-apps
    (lambda ()
      (let* ((ctx (root-ctx))
             (reporter (self))
             (`#(ok ,_) (patchbay_context:mount ctx (nyaa-demo-consumer:child_spec reporter)))
             (`#(ok ,_) (patchbay_context:mount ctx (nyaa-demo-provider:child_spec reporter))))
        (drain ()) ; discard the initial waiting/ready/ready messages
        (let ((`#(ok #(,prov-pid ,_)) (patchbay_registry:lookup 'demo-provider)))
          (exit prov-pid 'kill))
        (let ((msgs (drain ())))
          (is (lists:member '#(consumer dep-down demo-provider killed) msgs))
          (is (lists:any (match-lambda ((`#(consumer ready ,_)) 'true) ((_) 'false)) msgs)))))))

(deftest unmount-fires-the-disposer-and-deregisters
  (with-apps
    (lambda ()
      (let* ((ctx (root-ctx))
             (reporter (self))
             (`#(ok ,_) (patchbay_context:mount ctx (nyaa-demo-consumer:child_spec reporter))))
        (drain ())
        (is-equal 'ok (patchbay_context:unmount ctx 'demo-consumer))
        (is-equal '#(consumer terminated shutdown) (recv-one 500))
        (is-equal '#(error not_found) (patchbay_registry:lookup 'demo-consumer))))))

(defun recv-one (timeout)
  (receive
    (m m)
    (after timeout 'timeout)))
