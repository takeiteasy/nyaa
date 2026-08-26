# Model adapter plugins

Model adapters are standard `patchbay_service` callback modules (see
patchbay's `docs/plugins.md` for the base contract) that follow one
additional convention so callers -- including the future agent loop --
can talk to an LLM backend uniformly, without caring which backend is
mounted or how its HTTP API, auth, and streaming quirks differ.

They are the model-backend sibling of the tool/skill convention
([docs/tools.md](tools.md)): tools do local work on behalf of the agent,
adapters speak to the model that drives it.

The reference implementation lives in `src/adapters/nyaa-adapter-ollama.lfe`;
concrete-adapter tickets beyond it (OpenRouter, ...) implement this
same contract.

## The convention

A model adapter plugin:

1. **Registers under `'model-<name>`** (e.g. `'model-ollama`) with no
   dependencies, so mounting order never matters. Auth secrets and
   endpoint configuration belong to the adapter's mount-time options --
   callers never see them.
2. **Implements `metadata/0`** returning a map of the shape

   ```lfe
   #m(kind model
      name 'model-ollama
      summary "one-line description"
      base-url "http://127.0.0.1:11434"
      model "default model, or 'undefined if only settable per request"
      capabilities #m(streaming true tool-calling false)
      params #m(messages "description" ...))
   ```

   `patchbay_service` publishes this as the registration props, which
   makes adapters discoverable exactly like tools -- scan registrations
   for `kind == model`. `capabilities` advertises what the backend
   actually supports so callers can degrade gracefully; at minimum say
   whether `stream` is honored.
3. **Answers two messages** via `handle_message/2`:

   - `describe` -- replies with the same metadata map
   - `` `(complete ,req) `` -- performs one completion turn; replies
     `#(ok ,result)` or `#(error ,reason)` as defined below

### Request shape

```lfe
`#(complete
   #m(messages (#m(role "system" content "...")        ; required
                 #m(role "user"   content "..."))
      stream    ,sink-pid                              ; optional
      ref       ,opaque-tag                            ; optional, echoed
      timeout   120000                                 ; optional ms
      ; ... adapter-specific sampling params, advertised in params:
      model "override-mounted-default"
      temperature 0.7
      seed 42))
```

- `messages` is a list of maps with `role` and `content`. Roles are a
  closed set -- today `system`, `user`, `assistant` -- given as lower-case
  binaries (strings accepted and normalized; so are LFE role symbols).
  A message missing either field is a `bad_request`. Anything that would
  require *formatting* decisions the backend can't express belongs to a
  dedicated ticket, not silent mangling: there is deliberately **no
  convenience `system:` field** -- the agent composes its own messages.
- Backend-specific parameters (sampling knobs, model selection) are
  forwarded as-is to whatever the adapter maps them onto. Every adapter
  documents in `params` what it accepts; unknown keys are ignored, never
  errors, so a portable caller can offer a superset.
- Validation is pre-flight: a malformed request fails fast with
  `bad_request` **without touching the backend**, so you can tell "your
  ask was wrong" from "the backend misbehaved".

### Result shape

```lfe
#(ok #m(role "assistant"
        content "full text of this turn"
        done true
        meta #m(model "..." eval_count 42 total_duration 9000 ...)))
```

`meta` is adapter-specific extra context (usage stats, finish reasons,
backend ids). It is informational: programmatic dispatch should rely on
`role`/`content`/`done` only.

### Streaming

When `req` carries `stream <sink-pid>`, the adapter delivers token
deltas **as plain async messages** to that pid, before (and in addition
to) the `complete` call's own reply:

```lfe
;; to the sink, once per textual delta, strictly before the reply:
(sink ! `#(model-token ,ref ,chunk-binary))

;; the final result map still comes back through the call:
(patchbay_service:call_service 'model-ollama req 600000)
```

- `ref` is the caller's opaque tag (any term, default `'()`); sinks that
  serve several concurrent consumers correlate events by it.
- Tokens arrive ordered left-to-right within one completion. Mailbox
  FIFO guarantees they precede the final reply at the *calling* process;
  arbitrary sinks just see them in emission order.
- Deltas are the text pieces as received -- empty deltas are dropped;
  word-level gaps between adjacent chunks exist if the backend chopped
  there.
- Without `stream`, the call blocks silently until done, and no token
  events are ever emitted.

Two deliberate limits of this design (fine for nyaa's current
single-operator posture):

- Requests **serialize through the adapter's gen_server** while it pumps
  a completion. Concurrent completions queue up rather than interleave;
  when parallelism matters, the follow-up shape is worker-per-request
  behind the same external contract.
- The *caller* stays blocked, so choose the `complete` call timeout
  generously (`call_service/3`): a generation legitimately runs minutes.
  The adapter still bounds itself internally (see below) so a wedged
  backend costs a timeout, not a hang forever.

### Error surface

Adapters translate backend jargon into four canonical shapes:

| Shape                        | Meaning                                                  |
|------------------------------|----------------------------------------------------------|
| `#(error #(bad_request msg))`| Caller-side problem: malformed req, wrong types          |
| `#(error timeout)`           | The exchange blew past its deadline (adapter cancels its in-flight work before reporting) |
| `#(error unavailable)`       | Could not reach the backend at all: refused, DNS, TLS, died before responding |
| `#(error #(backend_error status detail))` | Reached it, protocol broke down: non-OK status, malformed payload, mid-stream disconnect |

Every adapter maps to these four; nobody dispatches on `econnrefused`
or a vendor's 4xx vocabulary. `detail` payloads are informational and
may vary between adapters.

As with tools, the adapter promises: **its work is bounded by its
timeout**. A hung or dead backend surfaces as `#(error timeout)`
promptly -- it never wedges the adapter service, and whatever
connection was in flight is cancelled.

## Discovery

Scan registrations for `kind == model`:

```lfe
(lists:filtermap
  (lambda (name)
    (case (patchbay_registry:lookup name)
      (`#(ok #(,_pid ,props))
       (=:= '#(ok model) (maps:find 'kind props)))
      (_ 'false)))
  (patchbay_registry:names()))
```

### Invocation

Blocking:

```lfe
(patchbay_service:call_service
  'model-ollama
  `#(complete #m(messages (#m(role user content #"Explain aliases"))))
  600000)
```

Streaming to the caller itself (tokens land in the mailbox, ordered
before the reply because of gen_server-call FIFO):

```lfe
(let* ((me (self))
       (req `#(complete #m(messages (#m(role user content #"hi"))
                           stream ,me
                           ref 'turn-1))))
  (case (patchbay_service:call_service 'model-ollama req 600000)
    (`#(ok ,result)
     ;; drain #(...)model-token events..., then inspect result
     'ok)
    (err err)))
```

Use the timeout variant: gen_server's 5s default will abort the caller
long before most models finish thinking.

## Trust posture

An adapter is an exfiltration surface by nature: everything handed to
`complete` flows outward to wherever the backend lives. Local-only
adapters (Ollama) keep conversation data on the node; remote adapters
place it under someone else's terms. That is orthogonal to the prompt
surface question: feeding what comes *back* into `tool-eval`/REPL
evaluation remains gated by the constrained DSL decision (see
"Security & trust" in docs/getting-started.md, and #14).

## Reference: Ollama adapter

`src/adapters/nyaa-adapter-ollama.lfe`, registered as `'model-ollama`,
speaks to a local Ollama server's `/api/chat` endpoint over the OTP
stdlib HTTP client (`inets` -- no third-party dependencies).

- **Mount-time options** (`child_spec opts`): `base-url` (default
  `http://127.0.0.1:11434`), `model` (mounted default, no sensible
  universal one -- bring your own), `timeout-ms` (default 120000).
- **Per-request extras**: `model`, `temperature`, `seed`, `num_ctx`
  (`num-ctx` accepted), `stop`, `format` -- the first four travel as
  Ollama chat `options`, the rest top-level. Streaming is NDJSON off
  `/api/chat` with `stream: true`; deltas become `model-token` events.
- **Diagnostics**: non-OK replies are unpacked (`{"error": ...}` bodies
  decoded where present); the final `done` line's usage counters
  (`eval_count`, `prompt_eval_count`, `total_duration`, `load_duration`)
  land in `meta`, along with `model` and `done_reason`.
- **Health**: unreachable server yields `#(error unavailable)`, unknown
  model name a 404 (so `#(error #(backend_error 404 ...))`), both easy
  to distinguish from bad requests.

Recommended local model for nyaa development on modest hardware (8 GB
RAM class): `ollama pull llama3.2:3b` (~2 GB disk, ~3 GB resident) --
small enough to leave headroom, coherent enough to drive the agent loop.

Quick end-to-end check against a real server:

```erlang
%% ollama serve & pulled model required; see getting-started.md
{ok, {Ctx, _}} = patchbay_registry:lookup('nyaa-root'),
patchbay_context:mount(Ctx, 'nyaa-adapter-ollama':child_spec()),
timer:sleep(100),
patchbay_service:call_service('model-ollama',
    {complete, #{messages => [#{role => user, content => <<"say hi">>}]}},
    60000).
```

## Adding a new adapter

Implement the three-convention callback module above, mount it like any
plugin, and cover it in tests following `test/nyaa-adapter-tests.lfe`:
discovery, describe fidelity, a happy-path `complete` against a canned
backend, and each canonical error shape your transport can produce.
The offline canned-HTTP harness (`test/nyaa-fake-http.lfe`) speaks plain
enough HTTP/1.1 to stand in for most backends -- extend it rather than
pointing tests at real services; gated live-smoke tests are welcome
additions, not replacements.
