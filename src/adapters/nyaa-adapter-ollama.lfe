(defmodule nyaa-adapter-ollama
  (export
    (child_spec 0)
    (child_spec 1)
    (service_name 0)
    (dependencies 0)
    (metadata 0)
    (init 1)
    (handle_message 2)
    (terminate 2)))

;;; Model adapter plugin: Ollama. Speaks to a local Ollama server's
;;; POST /api/chat endpoint via the OTP stdlib HTTP client (inets) --
;;; NDJSON streaming mapped onto the adapter convention's completion
;;; interface (see docs/adapters.md): registers as 'model-ollama,
;;; answers #(describe) and #(complete req), delivers deltas as
;;; #(model-token ref chunk) events to the caller-supplied sink pid
;;; before the final reply, and normalizes every failure into the
;;; canonical #(error ...) surface (bad_request / timeout /
;;; unavailable / backend_error).
;;;
;;; Implementation notes:
;;; - httpc is driven in async mode ({sync false} {stream self}) for
;;;   both the blocking and streaming paths -- one code path, and the
;;;   overall exchange is bounded by the adapter's own monotonic
;;;   deadline (a hung backend costs #(error timeout), never a wedge;
;;;   the httpc request is cancelled on expiry).
;;; - Observed message shapes (verified on OTP 29): #(http #(rid
;;;   stream_start hdrs)), #(http #(rid stream chunk)),
;;;   #(http #(rid stream_end hdrs)); small non-200 responses arrive
;;;   fully buffered as #(http #(rid #(#("HTTP/1.x" code phrase)
;;;   hdrs body))); transport failures as #(http #(rid #(error
;;;   reason))).
;;; - Mount options (#m()) defaults: base-url "http://127.0.0.1:11434",
;;;   timeout-ms 120000; `model` has no sensible universal default and
;;;   must be supplied at mount or per request.
;;; - Streaming serializes through this gen_server (documented MVP
;;;   limitation, docs/adapters.md). Worker-per-request remains future
;;;   work behind the same external contract.

(defun child_spec ()
  (child_spec #m()))

(defun child_spec (opts)
  `#m(id model-ollama
      start #(patchbay_service start_link (nyaa-adapter-ollama ,opts))
      restart transient
      shutdown 5000
      type worker
      modules (patchbay_service)))

(defun service_name () 'model-ollama)
(defun dependencies () '())

;;; Static registration props (patchbay_service metadata/0): the
;;; mounted instance's base-url/model are additionally shown by its
;;; `(describe)` reply; the props keep discovery-shape facts only,
;;; since metadata/0 has no access to init args.
(defun metadata ()
  (list->props))

(defun or-default-unless-bin (v default)
  ;;; mount-time option → binary; a bare string/charlist is coerced,
  ;;; anything unusable falls back to the mounted default.
  (cond
    ((is_binary v) v)
    ((is_list v)
     (let ((coerced (unicode:characters_to_binary v 'utf8)))
       (if (is_binary coerced) coerced default)))
    ('true default)))

(defun or-unset (v)
  ;;; A malformed mount value degrades to unset (model must then be
  ;;; given per request).
  (if (=:= v 'bad) 'undefined v))

(defun opt-string (opts key)
  (case (maps:find key opts)
    (`#(ok ,v)
     (if (orelse (is_binary v) (is_list v))
       v
       'bad))
    ('error 'bad)))

(defun opt-pos-int (opts key default)
  (let ((given (maps:get key opts default)))
    (if (and (is_integer given) (> given 0)) given default)))

(defun merge-meta (base extra)
  (maps:merge base extra))

(defun init (args)
  ;;; Defensive: the nyaa app depends on inets, but adapters should
  ;;; also work mounted anywhere.
  (application:ensure_all_started 'inets)
  (let* ((opts (if (is_map args) args #m()))
         (base-url (or-default-unless-bin
                     (opt-string opts 'base-url)
                     #"http://127.0.0.1:11434"))
         (model (or-default-unless-bin
                  (opt-string opts 'model)
                  'bad))
         (timeout-ms (opt-pos-int opts 'timeout-ms 120000)))
    `#(ok #m(base-url ,base-url
             model ,(or-unset model)
             timeout-ms ,timeout-ms))))

(defun terminate (_reason _state) 'ok)

(defun default-capabilities ()
  #m(streaming true tool-calling false))

(defun param-docs ()
  #m(messages "list of #m(role content) maps; roles: system user assistant (required)"
     stream "sink pid receiving #(model-token ref chunk) deltas pre-reply"
     ref "opaque term echoed with each token event (default ())"
     timeout "per-request deadline override in ms"
     model "override the mounted default model"
     temperature "sampling temperature"
     seed "deterministic sampling seed"
     num_ctx "context window size (num-ctx accepted)"
     stop "list of stop sequences"
     format "response format passthrough (e.g. json)"))

(defun list->props ()
  `#m(kind model
      name 'model-ollama
      summary #"Local Ollama chat completions (/api/chat) with streamed deltas"
      capabilities ,(default-capabilities)
      params ,(param-docs)))

(defun configured-describe (state)
  (merge-meta
    (list->props)
    `#m(base-url ,(maps:get 'base-url state)
        model ,(maps:get 'model state))))

;;; --- complete --------------------------------------------------------

(defun handle_message
  (('describe state) `#(reply ,(configured-describe state) ,state))
  ((`#(complete ,req) state)
   (case (validate-request req state)
     (`#(ok ,body ,sink ,ref ,deadline-ms)
      ;;; base-url comes from the mounted state; everything else was
      ;;; normalized above.
      `#(reply ,(perform (maps:get 'base-url state) body sink ref deadline-ms)
                ,state))
     (`#(error ,reason)
      `#(reply #(error ,reason) ,state)))))

(defun validate-request (req state)
  ;;; Linear validation ladder via and-then: first failure short-
  ;;; circuits with its #(error reason); success threads the normalized
  ;;; value onward. Pre-flight -- nothing here touches the backend.
  (and-then
    (messages-step req)
    (lambda (norm-msgs)
      (and-then
        (model-step req state)
        (lambda (model)
          (and-then
            (sink-step req)
            (lambda (sink)
              (and-then
                (timeout-step req state)
                (lambda (timeout-ms)
                  `#(ok ,(build-body model norm-msgs req)
                        ,sink
                        ,(maps:get 'ref req '())
                        ,(+ timeout-ms (now-ms))))))))))))

(defun and-then (result next)
  (case result
    (`#(ok ,v) (funcall next v))
    (`#(error ,_) result)))

(defun messages-step (req)
  (validate-messages (maps:get 'messages req 'absent)))

(defun model-step (req state) (resolve-model req state))
(defun sink-step (req) (check-sink (maps:get 'stream req 'absent)))
(defun timeout-step (req state) (resolve-timeout req state))

(defun resolve-model (req state)
  (let ((mounted (maps:get 'model state))
        (override (maps:get 'model req 'absent)))
    (cond
      ((=:= override 'absent)
       (if (=:= mounted 'undefined)
         '#(error #(bad_request "no model: supply one at mount or per request"))
         `#(ok ,mounted)))
      ('true
       (case (normalize-string override)
         (`#(ok ,bin) `#(ok ,bin))
         (`#(error ,detail) `#(error #(bad_request ,detail))))))))

(defun check-sink (v)
  (cond
    ((=:= v 'absent) '#(ok 'undefined))
    ((is_pid v) `#(ok ,v))
    ('true '#(error #(bad_request "stream must be a sink pid")))))

(defun check-ref (_v)
  ;;; Any term passes through untouched: refs are opaque correlation
  ;;; tags. Kept as a hook so validation can grow if refs ever gain
  ;;; meaning internally.
  '#(ok passthrough))

(defun resolve-timeout (req state)
  (let ((given (maps:get 'timeout req 'absent)))
    (if (=:= given 'absent)
      `#(ok ,(maps:get 'timeout-ms state))
      (if (and (is_integer given) (> given 0))
        `#(ok ,given)
        '#(error #(bad_request "timeout must be positive integer ms"))))))

(defun validate-messages (msgs)
  (cond
    ((=:= msgs 'absent)
     '#(error #(bad_request "messages required")))
    ((not (is_list msgs))
     '#(error #(bad_request "messages must be a list")))
    ((=:= msgs '())
     '#(error #(bad_request "messages must be non-empty")))
    ('true
     (walk-messages msgs '()))))

(defun walk-messages (msgs acc)
  (cond
    ((=:= msgs '())
     `#(ok ,(lists:reverse acc)))
    ('true
     (if (not (is_map (car msgs)))
       '#(error #(bad_request "each message must be a map"))
       (let ((m (car msgs))
             (rest (cdr msgs)))
         (case (require-bin m 'role)
           (`#(error ,_) `#(error #(bad_request "message role must be a string")))
           (`#(ok ,role-bin)
            (case (require-bin m 'content)
              (`#(error ,_) `#(error #(bad_request "message content must be a string")))
              (`#(ok ,content-bin)
               (if (known-role role-bin)
                 (walk-messages rest
                                (cons `#m(role ,role-bin content ,content-bin) acc))
                 '#(error #(bad_request "unknown role"))))))))))))

(defun known-role (role-bin)
  (orelse (=:= role-bin #"system")
          (=:= role-bin #"user")
          (=:= role-bin #"assistant")))

(defun require-bin (map key)
  (case (maps:find key map)
    (`#(ok ,v) (normalize-string v))
    ('error `#(error #(bad_request "message missing key")))))

(defun normalize-string (v)
  ;;; Accept binaries and character lists; everything a caller might
  ;;; naturally write becomes a binary before it reaches JSON.
  (cond
    ((is_binary v) `#(ok ,v))
    ((is_list v)
     (case (unicode:characters_to_binary v 'utf8)
       (bin (when (is_binary bin)) `#(ok ,bin))
       (_ `#(error #(bad_request "unencodable character data")))))
    ((is_atom v) `#(ok ,(erlang:atom_to_binary v 'utf8)))
    ('true '#(error #(bad_request "expected string/binary")))))

;;; --- ollama request body ---------------------------------------------

(defun build-body (model norm-msgs req)
  (let* ((base `#m(model ,model
                   messages ,norm-msgs
                   stream true))
         (with-top-level (add-format base req))
         (final (add-options with-top-level req)))
    final))

(defun add-format (body req)
  (case (maps:find 'format req)
    (`#(ok ,f) (maps:put 'format f body))
    ('error body)))

(defun add-options (body req)
  (let* ((o1 (opt-into #m() req 'temperature 'temperature))
         (o2 (opt-into o1 req 'seed 'seed))
         (o3 (opt-into o2 req 'num_ctx 'num_ctx))
         (o4 (opt-into o3 req 'num-ctx 'num_ctx))
         (o5 (opt-into o4 req 'stop 'stop)))
    (if (> (maps:size o5) 0)
      (maps:put 'options o5 body)
      body)))

(defun opt-into (opts req req-key out-key)
  (case (maps:find req-key req)
    (`#(ok ,v) (maps:put out-key v opts))
    ('error opts)))

;;; --- transport ---------------------------------------------------------
;;;
;;; One code path for blocking and streaming: the request always opens
;;; as an async NDJSON stream bounded by an absolute monotonic deadline;
;;; without a sink the chunks are simply aggregated instead of emitted.

(defun perform (base-url body sink ref deadline)
  (case (safe-encode body)
    (`#(ok ,payload)
     (open-request base-url payload deadline sink ref))
    (`#(error ,detail)
     `#(error #(backend_error ,detail)))))

(defun safe-encode (body)
  (let ((result (catch (json:encode body))))
    (cond
      ((is_binary result)
       `#(ok ,result))
      ;;; json:encode is free to return deep iolists -- normalize.
      ((is_list result)
       `#(ok ,(iolist_to_binary result)))
      ('true
       `#(error "request payload could not be encoded")))))

(defun request-url (base-url)
  ;;; charlist URL: httpc's URL parsing is most reliable there.
  (lists:concat
    (list (unicode:characters_to_list base-url 'utf8) "/api/chat")))

(defun open-request (base-url payload deadline sink ref)
  (case (httpc:request
          'post
          (tuple (request-url base-url)
                 (list (tuple "content-type" "application/json"))
                 "application/json"
                 payload)
          (http-options deadline)
          ;;; NB: these are DATA tuples -- backquoted templates make the
          ;;; bare atoms evaluate to themselves; quoted forms would embed
          ;;; the reader's (quote ...) wrappers instead.
          (list `#(sync false) `#(stream self)))
    (`#(ok ,req-id) (pump req-id deadline (binary) '() #m() sink ref 'false))
    (`#(error ,reason) (transport-error reason))))

(defun http-options (deadline)
  (let ((budget (max 1000 (- deadline (now-ms)))))
    (list (tuple 'timeout budget)
          (tuple 'connect_timeout (min 10000 budget)))))

(defun now-ms ()
  (erlang:monotonic_time 'milli_seconds))

(defun cancel-request (req-id)
  ;;; On deadline expiry drop the in-flight request; noproc races are
  ;;; harmless here.
  (catch (httpc:cancel_request req-id))
  'ok)

(defun pump (req-id deadline buf acc meta sink ref done?)
  (let ((remaining (- deadline (now-ms))))
    (if (=< remaining 0)
      (progn (cancel-request req-id) '#(error timeout))
      (receive
        ((tuple 'http (tuple rid 'stream_start _hdrs))
         (when (=:= rid req-id))
         (pump req-id deadline buf acc meta sink ref done?))
        ((tuple 'http (tuple rid 'stream chunk))
         (when (and (=:= rid req-id) (is_binary chunk)))
         (ingest req-id deadline (iolist_to_binary (list buf chunk))
                 acc meta sink ref done?))
        ((tuple 'http (tuple rid 'stream_end _hdrs))
         (when (=:= rid req-id))
         (finalize buf acc meta))
        ((tuple 'http (tuple rid (tuple (tuple _vsn code _phrase) _hdrs body3)))
         (when (=:= rid req-id))
         
         (buffered-response code body3))
        ((tuple 'http (tuple rid (tuple 'error reason)))
         (when (=:= rid req-id))
         (transport-error reason))
        (_msg
         ;;; mailbox noise not addressed to this exchange: ignore.
         (pump req-id deadline buf acc meta sink ref done?))
        (after remaining
               (cancel-request req-id)
               '#(error timeout))))))

(defun buffered-response (code body)
  ;;; Small/error responses arrive fully buffered instead of streamed.
  (if (and (is_integer code) (< code 300))
    (ingest-whole body '() #m())
    (status-error code body)))

(defun status-error (code body)
  `#(error #(backend_error ,code ,(error-detail body))))

(defun error-detail (body)
  (cond
    ((not (is_binary body)) #"unknown backend failure")
    ('true
     (let ((decoded (safe-decode body)))
       (if (is_map decoded)
         (case (maps:find #"error" decoded)
           (`#(ok ,msg) (normalize-or-limit msg))
           ('error (limit-body body)))
         (limit-body body))))))

(defun normalize-or-limit (msg)
  (case (normalize-string msg)
    (`#(ok ,bin) bin)
    (`#(error ,_) (limit-body msg))))

(defun limit-body (body)
  (let ((size (erlang:byte_size body)))
    (if (> size 200)
      (erlang:binary_part body 0 200)
      body)))

(defun transport-error (reason)
  (cond
    ;;; never got past dialing the server
    ((match-connect-failure reason) '#(error unavailable))
    ;;; died once transfer had begun -- protocol-level breakdown
    ((match-mid-transfer-drop reason)
     '#(error #(backend_error "connection lost mid-response")))
    ('true
     `#(error #(backend_error ,(term-detail reason))))))

(defun match-connect-failure (reason)
  ;;; ordered branches keep each access legal (tuples before elements,
  ;;; everything runs even under eager interpreters).
  (cond
    ((not (or (is_tuple reason) (is_atom reason))) 'false)
    ((is_tuple reason)
     (=:= (element 1 reason) 'failed_connect))
    ('true
     (lists:member reason
                   '(econnrefused nxdomain ehostunreach enetunreach
                     etimedout econnreset)))))

(defun match-mid-transfer-drop (reason)
  (and (is_tuple reason) (=:= (tuple_size reason) 2)
       (=:= (element 1 reason) 'shutdown)))

(defun term-detail (reason)
  (let ((printed (catch (list_to_binary (io_lib:format "~200w" (list reason))))))
    (if (is_binary printed) printed #"unexpected transport failure")))

(defun safe-decode (bin)
  (let ((result (catch (json:decode bin))))
    (if (is_map result) result 'undecodable)))

;;; --- ndjson ingestion ---------------------------------------------------

(defun ingest (req-id deadline buf acc meta sink ref done?)
  (let* ((segments (binary:split buf #"\n" (list 'global)))
         (rev (lists:reverse segments))
         (rest (car rev))
         (complete (lists:reverse (cdr rev))))
    (feed-lines complete rest acc meta sink ref done?
                (lambda (new-acc new-meta new-done?)
                  (pump req-id deadline rest new-acc new-meta
                        sink ref new-done?)))))

(defun ingest-whole (whole acc meta)
  ;;; Buffered (non-streamed) success: parse the entire payload at once.
  (let* ((segments (binary:split whole #"\n" (list 'global)))
         (rev (lists:reverse segments))
         (rest (car rev))
         (complete (lists:reverse (cdr rev))))
    ;;; NB: the trailing segment is handed to finalize exactly once,
    ;;; which is why `k` finalizes with an empty buffer, not with rest.
    (feed-lines complete rest acc meta 'no-sink '() 'false
                (lambda (new-acc new-meta _new-done?)
                  (finalize (binary) new-acc new-meta)))))

;;; Continuation-passing walker: processes every complete line, emitting
;;; tokens to the sink as it goes, then hands the outcome to `k`, which
;;; continues the transport pump (or finalizes) with the trailing partial
;;; line still unprocessed in its buffer argument.
(defun feed-lines (lines rest acc meta sink ref done? k)
  (cond
    ((=:= lines '())
     (funcall k acc meta done?))
    ('true
     (case (feed-one (car lines) acc meta sink ref done?)
       (`#(continue ,acc2 ,meta2 ,done2)
        (feed-lines (cdr lines) rest acc2 meta2 sink ref done2 k))
       (`#(abort ,err) err)))))

(defun feed-one (raw-line acc meta sink ref done?)
  (cond
    ((all-space raw-line)
     `#(continue ,acc ,meta ,done?))
    ('true
     (let ((decoded (safe-decode raw-line)))
       (if (is_map decoded)
         (apply-turn decoded acc meta sink ref done?)
         '#(abort #(error #(backend_error "undecodable stream line"))))))))

(defun all-space (bin)
  (if (=:= bin (binary))
    'true
    (lists:all (lambda (ch) (orelse (=:= ch 32) (=:= ch 9) (=:= ch 13)))
               (binary_to_list bin))))

(defun apply-turn (decoded acc meta sink ref done?)
  (let* ((message (maps:get #"message" decoded #m()))
         (delta (maps:get #"content" message (binary)))
         (line-done (maps:get #"done" decoded 'false))
         (meta1 (merge-stats decoded meta)))
    (emit-token sink ref delta)
    (let ((acc2 (append-text acc delta)))
      (if (=:= line-done 'true)
        `#(continue ,acc2 ,(maps:put '__done 'true meta1) 'true)
        `#(continue ,acc2 ,meta1 ,done?)))))

(defun emit-token (sink ref delta)
  (if (and (is_pid sink) (/= delta (binary)))
    (! sink `#(model-token ,ref ,delta))
    'ok))

(defun append-text (acc delta)
  (if (=:= delta (binary))
    acc
    (cons delta acc)))

(defun merge-stats (decoded meta)
  (lists:foldl
    (lambda (pair m)
      (let ((bin-key (element 1 pair))
            (atom-key (element 2 pair)))
        (case (maps:find bin-key decoded)
          (`#(ok ,v) (maps:put atom-key v m))
          ('error m))))
    meta
    (stat-keys)))

(defun stat-keys ()
  ;;; ollama binaries -> meta atom whitelist: avoids binary_to_atom on
  ;;; attacker-controlled keys and keeps meta shape stable.
  (list `#(#"eval_count" eval-count)
        `#(#"prompt_eval_count" prompt-eval-count)
        `#(#"total_duration" total-duration)
        `#(#"load_duration" load-duration)
        `#(#"eval_duration" eval-duration)
        `#(#"prompt_eval_duration" prompt-eval-duration)
        `#(#"done_reason" done-reason)
        `#(#"model" model)))

(defun finalize (rest-buf acc meta)
  ;;; stream ended: a trailing partial line without its newline is one
  ;;; last NDJSON object; anything else missing is fatal per contract.
  (case (feed-one rest-buf acc meta 'no-sink '() 'false)
    (`#(continue ,acc2 ,meta2 ,_done2) (assemble acc2 meta2))
    (`#(abort ,err) err)))

(defun assemble (acc meta)
  (case (maps:find '__done meta)
    (`#(ok ,_v) (when (=:= _v 'true))
     `#(ok #m(role #"assistant"
              content ,(iolist_to_binary (lists:reverse acc))
              done true
              meta ,(maps:remove '__done meta))))
    (_
     '#(error #(backend_error "stream ended without completion marker")))))


