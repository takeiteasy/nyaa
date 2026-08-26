(defmodule nyaa-tool-tests
  (behaviour ltest-unit)
  (export all))

(include-lib "ltest/include/ltest-macros.lfe")

;;; Tool/skill plugin convention (docs/tools.md), exercised through the
;;; real registry + patchbay_service stack: discovery by registration
;;; props, the describe/invoke protocol, per-tool behaviour, sandbox
;;; enforcement, and the property that a misbehaving form or hung
;;; command never takes down (or wedges) the tool service itself.
;;;
;;; Note: assert on maps functionally (maps:get) rather than matching
;;; bare #m(...) patterns -- bare map literals do not survive as LFE
;;; patterns here (erl_lint rejects the generated map-assoc pattern),
;;; so map-shaped results are always taken apart with maps:get.

(defun with-apps (thunk)
  (application:stop 'nyaa)
  (application:stop 'patchbay)
  (let ((`#(ok ,_) (application:ensure_all_started 'nyaa)))
    (try
      (funcall thunk)
      (after
        (application:stop 'nyaa)
        (application:stop 'patchbay)
        ;; Same mailbox-hygiene reasoning as nyaa-demo-tests: teardown
        ;; noise must not leak into the next test.
        (drain ())))))

(defun drain (acc)
  (receive
    (msg (drain (cons msg acc)))
    (after 300 (lists:reverse acc))))

(defun mount-all ()
  ;;; Mounts the four standard tools onto the fresh root context and
  ;;; returns the fs sandbox root once every tool is registered -- the
  ;;; sandbox dir doubles as proof the child_spec arg plumbing works.
  (let ((`#(ok #(,ctx ,_)) (patchbay_registry:lookup 'nyaa-root))
        (tmpdir (make-sandbox-dir)))
    (patchbay_context:mount ctx (nyaa-tool-shell:child_spec))
    (patchbay_context:mount ctx (nyaa-tool-fs:child_spec tmpdir))
    (patchbay_context:mount ctx (nyaa-tool-eval:child_spec))
    (patchbay_context:mount ctx (nyaa-tool-repl:child_spec))
    (patchbay_context:mount ctx (nyaa-tool-http:child_spec))
    (each (lambda (name) (await-registered name))
          '(tool-shell tool-fs tool-eval tool-repl tool-http))
    tmpdir))

(defun each (f names)
  (if (=:= names '())
    'ok
    (progn (funcall f (car names)) (each f (cdr names)))))

(defun await-registered (name)
  (case (patchbay_registry:lookup name)
    (`#(error not_found)
     (progn (timer:sleep 25) (await-registered name)))
    (_ 'ok)))

(defun call-tool (name msg)
  (patchbay_service:call_service name msg))

(defun make-sandbox-dir ()
  (let ((dir (filename:join "/tmp"
                            (++ "nyaa-tool-test-"
                                (integer_to_list
                                  (erlang:unique_integer '(positive)))))))
    (filelib:ensure_path dir)
    dir))

(deftest tools-are-discoverable-via-props
  (with-apps
    (lambda ()
      (mount-all)
      ;; The convention: kind=tool in registration props, found via
      ;; names() + lookup -- no special registry API needed.
      (let ((tool-names
              (lists:filtermap
                (lambda (name)
                  (case (patchbay_registry:lookup name)
                    ;; #(ok Props) whose kind is exactly the atom tool:
                    (`#(ok #(,_pid ,props))
                     (=:= '#(ok tool) (maps:find 'kind props)))
                    (_ 'false)))
                (patchbay_registry:names))))
        (is-equal '(tool-eval tool-fs tool-http tool-repl tool-shell)
                  (lists:sort tool-names))))))

(deftest describe-returns-convention-metadata
  (with-apps
    (lambda ()
      (mount-all)
      (let ((desc (call-tool 'tool-shell 'describe)))
        (is-equal 'tool (maps:get 'kind desc))
        (is (is_binary (maps:get 'summary desc)))
        (is (is_map (maps:get 'params desc)))))))

(deftest shell-runs-a-command-and-captures-output
  (with-apps
    (lambda ()
      (mount-all)
      ;; LFE string literal (char list) input, binary output:
      (let* ((result (call-tool 'tool-shell
                                `#(invoke #m(cmd "echo hello"))))
             (`#(ok ,out-map) result))
        (is (=:= 0 (maps:get 'exit out-map)))
        (is (=:= #"hello\n" (maps:get 'out out-map)))))))

(deftest shell-enforces-its-timeout-and-stays-alive
  (with-apps
    (lambda ()
      (mount-all)
      ;; A hung command must come back as an error promptly, and the
      ;; service must still answer afterwards:
      (let* ((t0 (erlang:monotonic_time 'milli_seconds))
             (result (call-tool 'tool-shell
                                `#(invoke #m(cmd "sleep 30" timeout 300))))
             (elapsed (- (erlang:monotonic_time 'milli_seconds) t0)))
        (is-match `#(error timeout) result)
        (is (< elapsed 5000))
        (let ((`#(ok ,out-map)
               (call-tool 'tool-shell
                          `#(invoke #m(cmd "echo still-here")))))
          (is (=:= 0 (maps:get 'exit out-map)))
          (is (=:= #"still-here\n" (maps:get 'out out-map))))))))

(deftest fs-read-write-list-delete-inside-the-root
  (with-apps
    (lambda ()
      ;; the sandbox root itself isn't needed directly -- every path is
      ;; relative to wherever mount-all mounted it:
      (mount-all)
      (is-equal 'ok
                (call-tool 'tool-fs
                           `#(invoke #m(op write path "a/b.txt"
                                        data #"hello fs"))))
      (let ((read-back (call-tool 'tool-fs
                                  `#(invoke #m(op read path "a/b.txt")))))
        (is-equal #"hello fs" (maps:get 'data (tl-with-ok read-back))))
      (let ((listing (call-tool 'tool-fs
                                `#(invoke #m(op list path ".")))))
        (is (lists:member "a" (maps:get 'files (tl-with-ok listing)))))
      (is-equal 'ok
                (call-tool 'tool-fs
                           `#(invoke #m(op delete path "a/b.txt")))))))

(defun tl-with-ok (result)
  ;;; #(ok Map) -> Map; keeps assertions readable without map patterns.
  (let (((tuple 'ok m) result)) m))

(deftest fs-rejects-path-escapes
  (with-apps
    (lambda ()
      (mount-all)
      ;; ../ escape:
      (is-match `#(error #(forbidden "path escapes sandbox root"))
                (call-tool 'tool-fs
                           `#(invoke #m(op read path "../outside.txt"))))
      ;; absolute path elsewhere on the box:
      (is-match `#(error #(forbidden "path escapes sandbox root"))
                (call-tool 'tool-fs
                           `#(invoke #m(op read path "/etc/passwd"))))
      ;; sibling-directory prefix trick:
      (is-match `#(error #(forbidden "path escapes sandbox root"))
                (call-tool 'tool-fs
                           `#(invoke #m(op list
                                        path "../sandbox-root-evil")))))))

(deftest eval-computes-values
  (with-apps
    (lambda ()
      (mount-all)
      (is-match `#(ok 6)
                (call-tool 'tool-eval `#(invoke #m(form (* 2 3))))))))

(deftest eval-crash-does-not-take-down-the-tool
  (with-apps
    (lambda ()
      (mount-all)
      ;; A form that explodes must surface as an error, not kill the
      ;; service gen_server -- and a hung form is bounded by its
      ;; timeout rather than wedging the service forever:
      (is-match `#(error ,_any)
                (call-tool 'tool-eval
                           `#(invoke #m(form (erlang:error boom)))))
      (is-match `#(error timeout)
                (call-tool 'tool-eval
                           `#(invoke #m(form (progn (timer:sleep 60000))
                                     timeout 200))))
      (is-match `#(ok 4)
                (call-tool 'tool-eval `#(invoke #m(form (+ 2 2))))))))

(deftest repl-tool-roundtrip-with-state-and-pristine
  (with-apps
    (lambda ()
      (mount-all)
      ;; Lazily creates the REPL, then state sticks across invocations:
      (is-match `#(ok 10)
                (call-tool 'tool-repl
                           `#(invoke #m(id t1 form (set n 10)))))
      (is-match `#(ok 11)
                (call-tool 'tool-repl
                           `#(invoke #m(id t1 form (+ n 1)))))
      ;; pristine=true discards t1 and evaluates against a fresh one:
      (is-match `#(error ,_)
                (call-tool 'tool-repl
                           `#(invoke #m(id t1 form n pristine true))))
      ;; The fresh t1 still works:
      (is-match `#(ok 3)
                (call-tool 'tool-repl
                           `#(invoke #m(id t1 form (+ 1 2))))))))

(deftest repl-tool-rejects-bad-requests
  (with-apps
    (lambda ()
      (mount-all)
      (is-match `#(error #(bad_request "id required"))
                (call-tool 'tool-repl `#(invoke #m(form (+ 1 2)))))
      (is-match `#(error #(bad_request "form required"))
                (call-tool 'tool-repl `#(invoke #m(id x)))))))

;;; --- tool-http (#15): single-shot HTTP via stdlib httpc -----------------
;;;
;;; Exercised against the same offline nyaa-fake-http used by the
;;; adapter suite; network-free and deterministic.

(defun http-fake-handler (_method path body)
  (cond
    ((=:= path #"/echo")
     `#(200 #m("Content-Type" "text/plain") ,body))
    ((=:= path #"/slow")
     (timer:sleep 1500)
     `#(200 #m() ""))
    ((=:= path #"/gone")
     '#(#(404 #m() "nope")))
    ('true
     `#(404 #m("Content-Type" "application/json") "{\"error\":\"nf\"}"))))

(defun start-http-fake ()
  (let ((`#(ok ,srv)
         (nyaa-fake-http:start #'http-fake-handler/3)))
    srv))

(deftest http-get-roundtrip-canned-body
  (with-apps
    (lambda ()
      (mount-all)
      (let ((base (nyaa-fake-http:url (start-http-fake))))
        (let* ((result
                 (call-tool 'tool-http
                            `#(invoke #m(url ,(iolist_to_binary (list base "/echo?x=1"))))))
              (m (element 2 result)))
          (is-match `#(ok ,_) result)
          (is-equal 200 (maps:get 'status m))
          (is (is_map (maps:get 'headers m)))
          (is-equal `#(ok #"text/plain") (maps:find #"content-type" (maps:get 'headers m))))))))

(deftest http-post-sends-body-and-headers
  (with-apps
    (lambda ()
      (mount-all)
      (let* ((srv (start-http-fake))
             (base (nyaa-fake-http:url srv))
             (result
               (call-tool 'tool-http
                          `#(invoke #m(url ,(iolist_to_binary (list base "/echo"))
                                       method "POST"
                                       headers #m("X-Tag" "abc")
                                       body #"payload=1")))))
        (is-match `#(ok ,_) result)
        ;; echo endpoint returns the request body verbatim
        (is-equal #"payload=1" (maps:get 'body (element 2 result)))))))

(deftest http-post-honors-caller-content-type
  (with-apps
    (lambda ()
      (mount-all)
      (let* ((srv (start-http-fake))
             (base (nyaa-fake-http:url srv))
             (result
               (call-tool 'tool-http
                          `#(invoke #m(url ,(iolist_to_binary (list base "/echo"))
                                       method "POST"
                                       headers #m("Content-Type" "application/json")
                                       body #"{\"a\":1}")))))
        (is-match `#(ok ,_) result)
        (let ((requests (nyaa-fake-http:requests srv)))
          (is-equal 1 (length requests))
          ;; caller's explicit content-type must survive, not be
          ;; clobbered to application/octet-stream.
          (is-equal #"application/json"
                     (maps:get 'content-type (car requests))))))))

(deftest http-rejects-missing-url-without-hitting-the-wire
  (with-apps
    (lambda ()
      (mount-all)
      (let ((srv (start-http-fake)))
        (is-match `#(error #(bad_request ,_))
                  (call-tool 'tool-http `#(invoke #m(method GET))))
        (is-equal 0 (length (nyaa-fake-http:requests srv)))))))

(deftest http-timeout-is-bounded-and-surfaces-as-error
  (with-apps
    (lambda ()
      (mount-all)
      (let ((srv (start-http-fake)))
        (let ((base (nyaa-fake-http:url srv)))
          (is-match `#(error timeout)
                    (call-tool
                      'tool-http
                      `#(invoke #m(url ,(iolist_to_binary (list base "/slow"))
                                   timeout 200)))))))))

(deftest http-non-ok-status-passes-through
  (with-apps
    (lambda ()
      (mount-all)
      (let ((base (nyaa-fake-http:url (start-http-fake))))
        (let ((result
                (call-tool 'tool-http
                           `#(invoke #m(url ,(iolist_to_binary (list base "/nope")))))))
          ;; the tool is a plain client: status passes through untouched.
          (is-equal 404 (maps:get 'status (element 2 result))))))))

(deftest http-unreachable-host-is-unavailable
  (with-apps
    (lambda ()
      (mount-all)
      (let ((srv (start-http-fake)))
        (let ((dead (nyaa-fake-http:url srv)))
          (nyaa-fake-http:stop srv)
          (is-match `#(error unavailable)
                    (call-tool 'tool-http
                               `#(invoke #m(url ,(iolist_to_binary (list dead "/x")))))))))))
