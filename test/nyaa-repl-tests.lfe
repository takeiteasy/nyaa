(defmodule nyaa-repl-tests
  (behaviour ltest-unit)
  (export all))

(include-lib "ltest/include/ltest-macros.lfe")

;;; Ephemeral scratch REPLs (#2): lifecycle, cross-eval state, pristine
;;; resets, isolation between REPLs, and resilience -- a crashing or
;;; looping form must never take down or wedge a REPL. Exercises the
;;; real registry + patchbay_context stack by starting the nyaa app.
;;;
;;; Assertion notes: bare map literals do not survive as LFE patterns
;;; here, and a bare _ inside a backquoted template compiles to junk
;;; atoms rather than wildcards -- so tuples are taken apart with
;;; explicit (tuple ...) patterns throughout.

(defun with-apps (thunk)
  (application:stop 'nyaa)
  (application:stop 'patchbay)
  (let ((`#(ok ,_) (application:ensure_all_started 'nyaa)))
    (try
      (funcall thunk)
      (after
        (application:stop 'nyaa)
        (application:stop 'patchbay)
        ;; Same mailbox-hygiene reasoning as nyaa-tool-tests: teardown
        ;; noise must not leak into the next test.
        (drain ())))))

(defun drain (acc)
  (receive
    (msg (drain (cons msg acc)))
    (after 300 (lists:reverse acc))))

(deftest eval-roundtrip-lazily-creates-the-repl
  (with-apps
    (lambda ()
      ;; First eval against an unknown id spawns the REPL:
      (is-match (tuple 'ok 5) (nyaa-repl:eval 'lazy '(+ 2 3)))
      ;; ...and it is now registered with kind=repl props:
      (let (((tuple 'ok (tuple _pid props))
             (patchbay_registry:lookup (tuple 'repl 'lazy))))
        (is (=:= '#(ok repl) (maps:find 'kind props)))
        (is (=:= '#(ok lazy) (maps:find 'id props)))))))

(deftest set-persists-across-evals
  (with-apps
    (lambda ()
      (is-match (tuple 'ok 10) (nyaa-repl:eval 's '(set x 10)))
      (is-match (tuple 'ok 15) (nyaa-repl:eval 's '(+ x 5))))))

(deftest defun-persists-across-evals
  (with-apps
    (lambda ()
      (is-match (tuple 'ok 'double)
                (nyaa-repl:eval 'f '(defun double (n) (* 2 n))))
      (is-match (tuple 'ok 42) (nyaa-repl:eval 'f '(double 21))))))

(deftest defmacro-persists-across-evals
  (with-apps
    (lambda ()
      ;; Macro definitions enter the env during expansion, so a macro
      ;; defined by one eval is usable in the next:
      (is-match (tuple 'ok 'inc)
                (nyaa-repl:eval 'm '(defmacro inc (x) `(+ ,x 1))))
      (is-match (tuple 'ok 43) (nyaa-repl:eval 'm '(inc 42))))))

(deftest pristine-resets-state
  (with-apps
    (lambda ()
      (nyaa-repl:eval 'p '(set x 10))
      ;; A pristine eval spawns fresh, so x is gone (unbound symbol =>
      ;; error), and afterwards the REPL answers normally again:
      (let ((result (nyaa-repl:eval 'p 'x #m(pristine true))))
        (is-match (tuple 'error _) result))
      (is-match (tuple 'ok 2) (nyaa-repl:eval 'p '(+ 1 1))))))

(deftest crashing-form-errors-without-killing-the-repl
  (with-apps
    (lambda ()
      (nyaa-repl:eval 'c '(set y 7))
      (is-match (tuple 'error _)
                (nyaa-repl:eval 'c '(erlang:error boom)))
      ;; State intact, process still answering:
      (is-match (tuple 'ok 7) (nyaa-repl:eval 'c 'y)))))

(deftest looping-form-bounded-by-timeout
  (with-apps
    (lambda ()
      (nyaa-repl:eval 't '(set z 1))
      (let* ((t0 (erlang:monotonic_time 'milli_seconds))
             (result (nyaa-repl:eval 't
                                      '(timer:sleep 60000)
                                      #m(timeout 300)))
             (elapsed (- (erlang:monotonic_time 'milli_seconds) t0)))
        (is-match (tuple 'error 'timeout) result)
        (is (< elapsed 5000))
        ;; Untouched env, live process:
        (is-match (tuple 'ok 1) (nyaa-repl:eval 't 'z))))))

(deftest concurrent-repls-are-isolated
  (with-apps
    (lambda ()
      (nyaa-repl:eval 'a '(set v 1))
      (nyaa-repl:eval 'b '(set v 2))
      (is-match (tuple 'ok 1) (nyaa-repl:eval 'a 'v))
      (is-match (tuple 'ok 2) (nyaa-repl:eval 'b 'v))
      (is (=:= '(a b) (lists:sort (nyaa-repl:list-repls)))))))

(deftest duplicate-start-fails
  (with-apps
    (lambda ()
      (is-match (tuple 'ok _) (nyaa-repl:start 'dup))
      (is-match (tuple 'error (tuple 'already_registered 'dup))
                (nyaa-repl:start 'dup)))))

(deftest stop-unregisters-and-is-idempotent
  (with-apps
    (lambda ()
      (is-match (tuple 'ok _) (nyaa-repl:start 'gone))
      (is (=:= 'ok (nyaa-repl:stop 'gone)))
      ;; Registry entry dropped once the process is down:
      (is-match '#(error not_found)
                (patchbay_registry:lookup (tuple 'repl 'gone)))
      ;; Stopping again (or an id that never existed) is not an error:
      (is (=:= 'ok (nyaa-repl:stop 'gone)))
      (is (=:= 'ok (nyaa-repl:stop 'never-was))))))

(deftest eval-after-stop-gets-a-fresh-repl
  (with-apps
    (lambda ()
      (nyaa-repl:eval 'fresh '(set w 99))
      (nyaa-repl:stop 'fresh)
      ;; Lazy creation hands back a brand-new, empty REPL:
      (is-match (tuple 'error _) (nyaa-repl:eval 'fresh 'w)))))
