# Protocols

A protocol is a [meow](https://github.com/takeiteasy/meow) service that
translates one neutral model contract onto one wire shape. Everything that
varies per backend — base URL, auth, model catalogue, quirks — is provider data
layered on top, so OpenRouter, Ollama, Groq, vLLM, LM Studio and
llama.cpp-server are provider definitions on one protocol rather than six
adapters.

| Layer | What it is | Where it lives |
|---|---|---|
| protocol | wire shape | a service, one per shape |
| provider | base URL, auth, catalogue, quirks | the [`define-provider`](providers.md) DSL |
| model | a bound provider and model id | named by the orchestrator |

## The convention

A protocol registers under `:protocol-<name>`, and its `metadata` plist carries
`:kind :protocol`, a `:summary`, and optionally `:params`:

```lisp
(m:defservice protocol-example (nyaa:completion-host) ()
  (:name :protocol-example))

(defmethod m:metadata ((service protocol-example))
  (list :kind :protocol
        :name :protocol-example
        :summary "One line on the wire shape"
        :params '((:temperature number :doc "sampling temperature"))))
```

`:params` is a typed [schema](schema.md) advertising the sampling parameters the
protocol understands. It is advertisement, for a provider to layer defaults on —
not a coercion gate, since a request may carry keys no protocol knows.

Use an explicit keyword for the name, as tools do: `defservice` otherwise
defaults to the class symbol, and names compare with `equal`.

It answers two messages, through `define-protocol-handler`:

- `(:describe)` — replies with the metadata plist
- `(:complete . plist)` — checks the request, then performs one turn

Meow intercepts the heads `%update-config`, `%effects` and `%timer-fire` before
`handle`, so a protocol must not use them.

## The request

```lisp
(nyaa:complete :protocol-openai
  :messages '((:role :system    :content "Be terse.")
              (:role :user      :content ((:type :text :text "list the files")))
              (:role :assistant :content nil
               :tool-calls ((:id "c1" :name :tool-shell :arguments (:cmd "ls"))))
              (:role :tool      :tool-call-id "c1" :content "a.lisp b.lisp"))
  :tools (list (nyaa:describe-tool :tool-shell))
  :stream sink :ref :turn-3
  :cancel token
  :timeout 30000
  :temperature 0.2)
```

Unknown keys are ignored rather than rejected, so a portable caller may offer a
superset and each protocol takes what it advertises. `:timeout` is in
milliseconds; `complete` waits longer than the protocol does, so the protocol's
own bounded `(:error :timeout)` is what a caller sees.

Roles are a closed set: `:system`, `:user`, `:assistant`, `:tool`.

## Staying neutral

The shape is chosen so both OpenAI chat completions and Anthropic Messages are
expressible:

- **Content is a list of typed blocks.** A flat string is the degenerate
  single-text-block case, which `normalize-content` expands and `content-text`
  flattens back. Only `:text` is defined here.
- **The system prompt is a `:system` role message.** A protocol needing it as a
  top-level parameter hoists leading system messages itself.
- **Tool results are `:tool` role messages** carrying `:tool-call-id`, the id of
  the call they answer. A protocol representing them as blocks inside a user
  message wraps them.
- **Streaming emits a neutral event vocabulary**, never raw provider chunks.

## The reply

```lisp
(:ok (:role :assistant :content <blocks> :tool-calls <calls>
      :done t :meta <plist>))
```

`:tool-calls` are `(:id "c1" :name :tool-shell :arguments (:cmd "ls"))`, ready
for `invoke-tool`. `:meta` is protocol-specific — usage counters, finish reason,
backend ids — and informational only. Dispatch on `:content`, `:tool-calls` and
`:done`.

## Streaming

A request's `:stream` sink is a function of one event, or a meow process the
events are sent to. `emit-event` takes either, and drops events when the sink is
nil. Every event echoes the request's `:ref`.

```lisp
(:type :text-delta      :ref r :text "...")
(:type :tool-call-delta :ref r :id "c1" :name :tool-shell :arguments "{\"cmd\"")
(:type :done            :ref r :reason :stop)
```

A streamed turn ends with exactly one `:done`, and nothing follows it. `:reason`
is the finish reason, or, when the exchange failed, the failed result the call
replies with:

```lisp
(:type :done :ref r :reason (:error :timeout))
(:type :done :ref r :reason (:error (:backend-error 429 "rate limited")))
```

`tool-error-p` tells the two apart. Every streaming request that reaches the
backend exchange ends this way — a refused connection, a non-OK status, a
stream cut short, a lapsed deadline — so a consumer of the sink alone can
watch for `:done`. A request rejected before the network with
`(:bad-request ...)` emits nothing.

A function sink is called from a thread of its own, one event at a time and in
order, so a sink that blocks never delays the exchange or its deadline. `complete`
returns once the sink has seen `:done`, except when the deadline lapsed: then
the reply does not wait on the sink. A sink that has not taken `:done` five
seconds past the deadline is stopped, and the events still queued for it are
dropped. A sink that signals an error loses that event and carries on.

A tool call's `:arguments` arrive as text split across deltas; the consumer
reassembles them. The `(:ok ...)` reply carries the whole turn regardless, so a
caller may ignore the sink entirely.

The [agent loop](agent.md) is this vocabulary's main consumer: these events
pass through to its own `:sink`, alongside the loop's own `:turn`,
`:tool-call`, `:tool-result` and `:run-done` events. A turn the loop abandons
for an interrupting steer is the one exception to a single closing `:done`:
the loop stops passing its events on and emits `:turn-interrupted` instead.

## Errors

The [tool error vocabulary](tools.md#results) applies, plus one shape protocols
add:

| Reason | Meaning |
|---|---|
| `(:backend-error status detail)` | The backend was reached and the exchange broke down: a non-OK status, a malformed payload, a stream cut short. |
| `:cancelled` | The request's `:cancel` token was cancelled. |

`(:bad-request msg)` is pre-flight, so a malformed request never reaches the
network and "your ask was wrong" stays distinguishable from "the backend
misbehaved". `check-request` runs in `complete` and again in the handler, so a
protocol reached by a bare `m:call` sees the same checked request.
`tool-error-p` and `tool-error` take a result apart.

A protocol bounds its own work by the request's timeout, as tools do, so a
wedged backend costs a timeout rather than a wedged service. The deadline
closes the connection, so the reader thread unwinds rather than waiting on the
backend.

## Concurrency

Each completion runs as a job on a shared [worker pool](#worker-pools), so a
protocol or provider answers `(:describe)` and further completions while one is
in flight. A service inherits `completion-host` and defines its handler with
`define-protocol-handler`, which runs the body as the job.

`:max-in-flight`, a mount option of every `completion-host`, caps how many of
a service's completions run at once; nil, the default, leaves them uncapped.
Past the cap a completion queues:

```lisp
(meow:mount *context* 'nyaa:protocol-openai :max-in-flight 4)
```

- Time spent queued counts against the request's `:timeout`: the body sees
  what is left, and one that runs out while queued answers `(:error
  :timeout)` without starting.
- Cancelling a queued completion's token answers `(:error :cancelled)` at
  once, and its body never runs.
- A body that signals answers `(:error (:error "text"))`.

Stopping a service cancels every completion it has in flight or queued: each
caller receives `(:error :cancelled)`.

### The exchange

A completion's exchange runs on the thread of the job that makes it, so it
takes no thread of its own. Its `:timeout`, kept by a timer every service
shares, or a cancel shuts the socket down and unwinds the exchange.

### Worker pools

Waiting completions run on pooled threads rather than one spawned per job.
There are two pools, or tiers, and a job only ever waits on a lower one, so a
full tier never waits on itself:

| Tier | Runs | Waits on |
|---|---|---|
| `:provider` | a provider's completions, when it rewrites or caps them | its protocol |
| `:protocol` | a protocol's completions | the backend |

An [agent](agent.md)'s turns and tool calls hold no thread while they wait: the
reply arrives as a message.

`*pool-sizes*` caps each tier's threads (`(:provider 64 :protocol 64)`), read
when a tier is first used. A thread idle for
`*pool-idle-seconds*` (30) exits, and one is started again as work arrives.
`(nyaa:pool-stats tier)` reports a tier's threads, idle threads, queued and
running jobs.

## Cancelling

A caller that no longer wants a completion passes a cancel token in the request
and cancels it from any thread:

```lisp
(let ((token (nyaa:make-cancel-token)))
  (bt:make-thread (lambda () (sleep 5) (nyaa:cancel token)))
  (nyaa:complete :protocol-openai ... :cancel token))
; => (:error :cancelled)
```

Cancelling shuts the connection down and ends the call at once with
`(:error :cancelled)`; a streamed turn ends with `(:type :done :reason (:error
:cancelled))`. A token already cancelled fails the call before it reaches the
network, and cancelling after the reply has arrived changes nothing.
`cancelled-p` reads the token, and `cancel` answers true the first time. A
provider passes `:cancel` through to its protocol. A
[tool call](tools.md#cancelling-a-call) takes the same token.

## The OpenAI protocol

`:protocol-openai` speaks chat completions: `POST <base-url>/chat/completions`,
with SSE when the request carries a `:stream` sink. One mounted service answers
for every backend of that shape — OpenRouter, Ollama, Groq, vLLM, LM Studio,
llama.cpp-server — so base URL, model and auth travel in the request rather than
in a config slot.

```lisp
(nyaa:complete :protocol-openai
  :base-url "http://127.0.0.1:11434/v1"
  :model "llama3.2"
  :headers '("authorization" "Bearer sk-...")
  :messages '((:role :user :content "hello"))
  :tools (list (nyaa:describe-tool :tool-shell))
  :stream sink :ref :turn-1
  :temperature 0.2)
```

| Key | Meaning |
|---|---|
| `:base-url` | required; the API root, http or https, with or without a trailing slash |
| `:model` | required; the model id the backend knows |
| `:headers` | a plist of request headers, where the provider's auth goes |

These are checked before the network, so a missing one is `(:bad-request ...)`
rather than a failed exchange. They are not in `:params`, which advertises the
sampling parameters — `:temperature`, `:top-p`, `:max-tokens`, `:stop` and
`:seed` — for a provider to layer defaults on.

`:meta` carries `:finish-reason`, the backend's `:id`, and `:usage` as a plist
of token counts.

Tool schemas render into the `tools` array through
[`schema->json-schema`](schema.md). A `tool_calls` reply comes back as
`:tool-calls` with a keyword name and a plist of arguments, read by the calling
tool's own schema, ready for `invoke-tool`.

Streaming reassembles what the wire splits: a tool call's id and name reach the
wire once, on the first fragment of an index, and every `:tool-call-delta`
repeats them, so a consumer of the sink alone needs no arrival order. The turn
ends on `data: [DONE]` or on a `finish_reason`; a stream that stops before
either is `(:backend-error ...)`.

Ollama serves this API at `/v1` alongside its native one, so it is testable
end to end against a local backend with no key — see
[providers](providers.md). The offline tests run against the fake HTTP
server; set `NYAA_OLLAMA_URL` (and optionally `NYAA_OLLAMA_MODEL`) to run the
live ones too.

## The Ollama protocol

`:protocol-ollama` speaks Ollama's native chat endpoint: `POST
<base-url>/api/chat`, with NDJSON streaming when the request carries a
`:stream` sink. Distinct from `:protocol-openai` because the wire shape
differs, not just the base URL — this is what carries the usage counters and
generation options the OpenAI-compatible `/v1` route drops.

```lisp
(nyaa:complete :protocol-ollama
  :base-url "http://127.0.0.1:11434"
  :model "llama3.2"
  :messages '((:role :user :content "hello"))
  :num-ctx 8192
  :temperature 0.2)
```

| Key | Meaning |
|---|---|
| `:num-ctx` | context window in tokens |
| `:num-predict` | cap on generated tokens |
| `:mirostat` | mirostat sampling mode |
| `:format` | response format: `json`, or a JSON schema |
| `:keep-alive` | how long to hold the model resident |

`:temperature`, `:top-p`, `:top-k`, `:stop` and `:seed` are the same sampling
knobs `:protocol-openai` advertises. On the wire, the sampling parameters nest
under an `"options"` object; `:format` and `:keep-alive` stay top-level, as
the native API has them.

`:meta` carries `:finish-reason` (from `done_reason`) and `:usage` — but
unlike OpenAI's single `usage` object, the native reply's counters
(`prompt_eval_count`, `eval_count`, `total_duration`, `load_duration`,
`prompt_eval_duration`, `eval_duration`) sit at the top level, and `:usage`
collects them the same way.

Streaming is newline-delimited JSON, not SSE: one bare object per line, no
`data:` prefix and no `[DONE]`. The turn ends on a line carrying `"done":
true`, which is also where the counters arrive — a stream cut before it is
`(:backend-error ...)`. A `tool_calls` array reaches the wire whole per
chunk rather than split into fragments, so there is no reassembly on the
receiving end. Native tool calls carry no id; one is synthesised per reply
(`call_0`, `call_1`, ...) so `:tool-calls` still satisfies the contract's own
`:id` requirement.

Tool schemas render into the `tools` array through the same renderer
`:protocol-openai` uses. A tool call's `arguments` travel as a JSON object in
both directions here, rather than the stringified form OpenAI's wire uses.

`:provider-ollama` binds this protocol to a local backend with no key — see
[providers](providers.md). Set `NYAA_OLLAMA_NATIVE_URL` (and optionally
`NYAA_OLLAMA_MODEL`) to run its live tests.

## Discovery

```lisp
(nyaa:protocols)                       ; => (:protocol-ollama :protocol-openai)
(nyaa:describe-protocol :protocol-openai)
```

`protocols` scans registration props for `:kind :protocol`, the way `tools`
scans for `:kind :tool`. `complete` reaches a [provider](providers.md) by name
the same way, since a provider answers the same messages.

## Limitations

- Each function sink's emitter is a process of its own, bounded only by the
  runs that make them
  ([#130](https://todo.sr.ht/~takeiteasy/nyaa/130)).
- An exchange stuck where neither the socket shutdown nor the interrupt
  reaches it holds its pooled thread
  ([#131](https://todo.sr.ht/~takeiteasy/nyaa/131)).
- A protocol whose body calls `complete` waits within its own tier, so a full
  tier stalls it until timeout
  ([#128](https://todo.sr.ht/~takeiteasy/nyaa/128)).
- A tool call naming a tool absent from the request's `:tools` has no schema to
  render its arguments by, and falls back to a heuristic
  ([#36](https://todo.sr.ht/~takeiteasy/nyaa/36)).
