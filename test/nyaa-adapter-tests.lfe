(defmodule nyaa-adapter-tests
  (behaviour ltest-unit)
  (export all))

(include-lib "ltest/include/ltest-macros.lfe")

;;; Model adapter convention + Ollama adapter (docs/adapters.md),
;;; exercised against an offline canned backend (`nyaa-fake-http`) so
;;; the whole suite stays network-free. One gated deftest talks to a
;;; real `ollama serve` when NYAA_TEST_LIVE_OLLAMA=1 is exported;
;;; otherwise it reports success as skipped.
;;;
;;; Repo-wide lessons baked in here: never match bare #m(...) patterns,
;;; maps:find misses are the bare atom 'error, decoded-JSON keys compare
;;; against #"" binaries, and the fake's answers are constructed via
;;; backquoted templates so computed slots actually evaluate.

;;; --- fixture ---------------------------------------------------------------

(defun with-apps (thunk)
  (application:stop 'nyaa)
  (application:stop 'patchbay)
  (let ((`#(ok ,_) (application:ensure_all_started 'nyaa)))
    (try
      (funcall thunk)
      (after
        (application:stop 'nyaa)
        (application:stop 'patchbay)
        (drain-all 100)))))

(defun drain-all (ms)
  (receive
    (_msg (drain-all ms))
    (after ms 'drained)))

(defun await-registered (name tries)
  (case (patchbay_registry:lookup name)
    (`#(ok ,_) 'ok)
    (_
     (if (=:= tries 0)
       (throw #(no-registration ,name))
       (progn
         (timer:sleep 25)
         (await-registered name (- tries 1)))))))

(defun mount-adapter (opts)
  (let ((`#(ok #(,ctx ,_)) (patchbay_registry:lookup 'nyaa-root)))
    (patchbay_context:mount ctx (nyaa-adapter-ollama:child_spec opts))
    (await-registered 'model-ollama 200)))

(defun mount-default-with-url (url)
  (mount-adapter
    `#m(base-url ,(iolist_to_binary (list url))
        model "fake-model")))

(defun call-complete (inner timeout-ms)
  (patchbay_service:call_service 'model-ollama `#(complete ,inner) timeout-ms))

;;; --- canned backend ----------------------------------------------------------

(defun ndjson-response ()
  `#(200
     #m("Content-Type" "application/x-ndjson")
     ,(ndjson-lines)))

(defun ndjson-lines ()
  (list
   "{\"message\":{\"role\":\"assistant\",\"content\":\"hel\"},\"done\":false}\n"
   "{\"message\":{\"role\":\"assistant\",\"content\":\"lo!\"},\"done\":false}\n"
   "{\"model\":\"fake-model\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\",\"eval_count\":42,\"total_duration\":9000}\n"))

(defun json-error-text ()
  "{\"error\":\"model \\\"fake-model\\\" not found\"}")

(defun matches (bin needle)
  (/= 'nomatch (binary:match bin needle)))

(defun fast-handler (_method _path body)
  (cond
    ((matches body #"missing-model")
     `#(404 #m("Content-Type" "application/json") ,(json-error-text)))
    ((matches body #"be-slow")
     (timer:sleep 1500)
     `#(200 #m() ""))
    ((matches body #"garbage-line")
     `#(200 #m("Content-Type" "application/x-ndjson")
        ,(list
          "{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"done\":false}\n"
          "<not json at all>\n"
          "{\"message\":{\"role\":\"assistant\",\"content\":\"x\"},\"done\":true}\n")))
    ('true
     (ndjson-response))))

(defun raw-partial-response ()
  ;;; hard mid-body drop: claims 100 bytes, sends a few, dies.
  `#(raw
     ,(iolist_to_binary
       (list "HTTP/1.1 200 OK\r\n"
             "Content-Type: application/x-ndjson\r\n"
             "Content-Length: 100\r\n"
             "Connection: close\r\n\r\n"
             "{\"message\":{\"role\":\"assis"))))

(defun raw-handler (method path body)
  (if (matches body #"die-mid")
    (raw-partial-response)
    (fast-handler method path body)))

(defun start-fast-server ()
  (let ((`#(ok ,srv) (nyaa-fake-http:start #'fast-handler/3)))
    srv))

(defun start-raw-server ()
  (let ((`#(ok ,srv) (nyaa-fake-http:start #'raw-handler/3)))
    srv))

;;; paced variant used by the genuine-streaming test

(defun paced-handler (method path body)
  (cond
    ((matches body #"missing-model")
     `#(404 #m("Content-Type" "application/json") ,(json-error-text)))
    ('true
     (fast-handler method path body))))

(defun start-paced-server ()
  (let ((`#(ok ,srv) (nyaa-fake-http:start-delayed #'paced-handler/3 180)))
    srv))

(defun T0-GLOBAL () 0)

(defun now-ms ()
  (erlang:monotonic_time 'milli_seconds))

;;; --- convention -----------------------------------------------------------

(deftest discoverable-via-kind-model
  (with-apps
    (lambda ()
      (start-fast-server)
      (mount-default-with-url "http://127.0.0.1")
      (let ((adapters
              (lists:filtermap
                (lambda (name)
                  (case (patchbay_registry:lookup name)
                    (`#(ok #(,_pid ,props))
                     (=:= '#(ok model) (maps:find 'kind props)))
                    (_ 'false)))
                (patchbay_registry:names))))
        (is-equal '(model-ollama) adapters)))))

(deftest describe-roundtrip-and-mount-config-visible
  (with-apps
    (lambda ()
      (let ((srv (start-fast-server)))
        (mount-default-with-url (nyaa-fake-http:url srv))
        ;; registration props come straight from metadata/0
        (case (patchbay_registry:lookup 'model-ollama)
          (`#(ok #(,_pid ,props))
           (is-equal (nyaa-adapter-ollama:metadata) props)))
        ;; a describe message reflects the mounted configuration
        (let ((desc (describe-via-message)))
          (is-equal 'model (maps:get 'kind desc))
          (is-equal #"fake-model" (maps:get 'model desc))
          (is (is_binary (maps:get 'base-url desc)))
          (is-equal 'true
                    (maps:get 'streaming
                              (maps:get 'capabilities desc))))))))

(defun describe-via-message ()
  (patchbay_service:call_service 'model-ollama 'describe 5000))

;;; --- blocking completion --------------------------------------------------

(deftest blocking-complete-happy-path
  (with-apps
    (lambda ()
      (let ((srv (start-fast-server)))
        (mount-default-with-url (nyaa-fake-http:url srv))
        (let ((result
                (call-complete #m(messages (#m(role user content #"hi")))
                               30000)))
          (is-match `#(ok ,_) result)
          (let ((m (element 2 result))
                (meta (maps:get 'meta (element 2 result))))
            (is-equal #"assistant" (maps:get 'role m))
            (is (=:= 'true (maps:get 'done m)))
            (is-equal #"hello!" (maps:get 'content m))
            (is-equal 42 (maps:get 'eval-count meta))
            (is-equal #"stop" (maps:get 'done-reason meta))))))))

(deftest outbound-request-is-normalized-and-overridable
  (with-apps
    (lambda ()
      (let ((srv (start-fast-server)))
        (mount-default-with-url (nyaa-fake-http:url srv))
        (call-complete
          #m(messages (#m(role system content "be nice")
                       #m(role user content #"hi"))
              temperature 0.5
              seed 7
              num_ctx 512)
          30000)
        (call-complete
          #m(messages (#m(role user content #"hi"))
              model "override-model")
          30000)
        ;;; give the sequential fake a beat to record both connections
        (await-requests srv 2 100)
        (let* ((reqs (nyaa-fake-http:requests srv))
               ;;; chronological order: first call is the head.
               (first-call (car reqs))
               (override-call (cadr-of-list reqs))
               (body1 (json:decode (maps:get 'body first-call)))
               (body2 (json:decode (maps:get 'body override-call))))
          (is-equal 2 (length reqs))
          (is-equal #"fake-model" (maps:get #"model" body1))
          (is (=:= 'true (maps:get #"stream" body1)))
          (let ((msgs (maps:get #"messages" body1)))
            (is-equal 2 (length msgs))
            (is-equal #"system" (maps:get #"role" (nth-of msgs 1)))
            (is-equal #"be nice" (maps:get #"content" (nth-of msgs 1)))
            (is-equal #"hi" (maps:get #"content" (nth-of msgs 2))))
          (let ((opts (maps:get #"options" body1)))
            (is-equal 0.5 (maps:get #"temperature" opts))
            (is-equal 7 (maps:get #"seed" opts))
            (is-equal 512 (maps:get #"num_ctx" opts)))
          ;; unknown keys never reach the wire...
          (is (=:= 'error (maps:find #"num-ctx-unused-passes-through-silently" body1)))
          ;; ...and the per-request override wins
          (is-equal #"override-model" (maps:get #"model" body2)))))))

(defun await-requests (srv n tries)
  (if (>= (length (nyaa-fake-http:requests srv)) n)
    'ok
    (if (=:= tries 0)
      (throw #(too-few-requests ,n))
      (progn
        (timer:sleep 50)
        (await-requests srv n (- tries 1))))))

(defun cadr-of-list (l)
  ;;; second element of a proper list -- element/2 is tuple-only.
  (car (lists:nthtail 1 l)))

(defun nth-of (l n)
  (lists:nth n l))

(defun catch-value (thunk)
  (catch (funcall thunk)))

(deftest validation-fails-fast-without-touching-the-backend
  (with-apps
    (lambda ()
      (let ((srv (start-fast-server)))
        (mount-default-with-url (nyaa-fake-http:url srv))
        (let ((cases
                (list
                  ;;; messages missing entirely
                  #m()
                  ;;; empty message list
                  #m(messages ())
                  ;;; non-map entry
                  #m(messages ("nope"))
                  ;;; unknown role
                  #m(messages (#m(role #"tool" content #"x"))))))
          (lists:foreach
            (lambda (req)
              (let ((result (call-complete req 5000)))
                (is-equal 'error (element 1 result))
                (is-equal 'bad_request
                          (element 1 (element 2 result)))))
            cases)
          (is-equal 0 (length (nyaa-fake-http:requests srv))))))))

;;; --- errors ----------------------------------------------------------------

(deftest non-ok-status-maps-to-backend-error-with-detail
  (with-apps
    (lambda ()
      (let ((srv (start-fast-server)))
        (mount-default-with-url (nyaa-fake-http:url srv))
        (let ((result
                (call-complete
                  #m(messages (#m(role user content #"hi"))
                      model "missing-model")
                  30000)))
          ;; canonical shape: #(error #(backend_error status detail))
          (is-equal 'error (element 1 result))
          (let ((inner (element 2 result)))
            (is-equal 'backend_error (element 1 inner))
            (is-equal 404 (element 2 inner))
            (is (matches (element 3 inner) #"not found"))))))))

;;; --- streaming ----------------------------------------------------------------

;;; a sink process that timestamps each token as it arrives and can be
;;; polled for a chronological snapshot afterwards.
(defun spawn-collector ()
  (spawn (lambda () (collector-loop '()))))

(defun collector-loop (acc)
  (receive
    (`#(get ,from)
     (! from `#(tokens ,(lists:reverse acc)))
     (collector-loop acc))
    ('#(stop-collector)
     'bye)
    (event
     (collector-loop (cons `#(at ,(now-ms) ,event) acc)))))

(defun snapshot (collector)
  (let ((me (self)))
    (! collector `#(get ,me))
    (receive
      (`#(tokens ,tokens) tokens)
      (after 1000 '#(error collector-unresponsive)))))

(deftest streaming-delivers-pieces-before-the-reply
  (with-apps
    (lambda ()
      (let ((srv (start-paced-server)))   ; 180 ms between body pieces
        (mount-default-with-url (nyaa-fake-http:url srv))
        (let ((sink (spawn-collector))
              (t0 (now-ms)))
          ;;; NB: computed slots force a *template* -- a bare #m( ,
          ;;; ) would embed literal (comma ...) junk (the classic LFE
          ;;; trap) and check-sink would rightly refuse it.
          (let ((result
                  (call-complete
                    `#m(messages (#m(role user content #"hi"))
                        stream ,sink
                        ref turn-7)
                    30000)))
            (let ((return-at (now-ms)))
              ;; the completion itself took at least two paced gaps.
              (is (> (- return-at t0) 300))
              (is-match `#(ok ,_) result)
              (let ((tokens (snapshot sink)))
                ;; exactly two textual deltas, ref echoed, left-to-right
                (is-equal 2 (length tokens))
                (is-equal #"hel" (token-chunk (car tokens)))
                (is-equal #"lo!" (token-chunk (cadr-of-list tokens)))
                (is-equal 'turn-7 (token-ref (car tokens)))
                ;; second token arrived before the call returned
                (is (< (token-at (cadr-of-list tokens)) return-at))))))))))

(defun token-chunk (entry) ;;; entry = #(...ts #(model-token ref chunk))
  (element 3 (element 3 entry)))
(defun token-ref (entry) (element 2 (element 3 entry)))
(defun token-at (entry) (element 2 entry))

(deftest no-stream-key-emits-no-token-events
  (with-apps
    (lambda ()
      (let ((srv (start-fast-server)))
        (mount-default-with-url (nyaa-fake-http:url srv))
        (let ((result
                (call-complete #m(messages (#m(role user content #"hi")))
                               30000)))
          (is-match `#(ok ,_) result)
          ;; nothing may linger in our mailbox after the reply
          (is-equal 'drained (drain-all 150)))))))

;;; --- transport failure taxonomy -----------------------------------------------

(deftest unreachable-backend-is-unavailable
  (with-apps
    (lambda ()
      (let ((srv (start-fast-server)))
        (let ((dead-url (nyaa-fake-http:url srv)))
          ;;; grab its port then tear the listener down: nothing listens.
          (nyaa-fake-http:stop srv)
          (mount-default-with-url dead-url)
          (is-match `#(error unavailable)
                    (call-complete
                      #m(messages (#m(role user content #"hi")))
                      10000)))))))

(deftest undecodable-stream-line-is-a-backend-error
  (with-apps
    (lambda ()
      (let ((srv (start-fast-server)))
        (mount-default-with-url (nyaa-fake-http:url srv))
        (let ((result
                (call-complete
                  #m(messages (#m(role user content #"garbage-line")))
                  30000)))
          (is-equal 'error (element 1 result))
          (let* ((inner (element 2 result)))
            (is-equal 'backend_error (element 1 inner))))))))

(deftest mid-body-disconnect-is-a-backend-error
  (with-apps
    (lambda ()
      (let ((srv (start-raw-server)))
        (mount-default-with-url (nyaa-fake-http:url srv))
        (let ((result
                (call-complete
                  #m(messages (#m(role user content #"die-mid")))
                  30000)))
          (is-equal 'error (element 1 result))
          (let* ((inner (element 2 result)))
            (is-equal 'backend_error (element 1 inner))))))))

(deftest per-request-deadline-yields-timeout
  (with-apps
    (lambda ()
      (let ((srv (start-fast-server)))
        (mount-default-with-url (nyaa-fake-http:url srv))
        (let ((t0 (now-ms)))
          ;;; request deadline 200 ms, canned handler sleeps 1500 ms.
          (let ((result
                  (call-complete
                    #m(messages (#m(role user content #"be-slow"))
                        timeout 200)
                    30000)))
            (is-match `#(error timeout) result)
            (is (< (- (now-ms) t0) 8000))))))))

;;; --- gated live smoke ----------------------------------------------------------

(deftest live-gated-ollama-end-to-end
  (let ((gated (os:getenv "NYAA_TEST_LIVE_OLLAMA")))
    (if (and (is_list gated) (/= gated "false") (/= gated ""))
      (live-body)
      ;;; not enabled -- report success so default runs stay green
      'skipped-live-ollama)))

(defun live-body ()
  (with-apps
    (lambda ()
      (let* ((model (or-empty->default (os:getenv "NYAA_TEST_MODEL")))
             (opts `#m(model ,(iolist_to_binary (list model)))))
        (mount-adapter opts)
        (let ((result
                (call-complete
                  #m(messages (#m(role user content #"Reply with exactly: ok")))
                  120000)))
          (is-match `#(ok ,_) result))))))

(defun or-empty->default (v)
  (if (orelse (=:= v "") (=:= v 'false))
    "llama3.2:3b"
    v))
