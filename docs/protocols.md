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
(m:defservice protocol-example () ()
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

A tool call's `:arguments` arrive as text split across deltas; the consumer
reassembles them. The `(:ok ...)` reply carries the whole turn regardless, so a
caller may ignore the sink entirely.

## Errors

The [tool error vocabulary](tools.md#results) applies, plus one shape protocols
add:

| Reason | Meaning |
|---|---|
| `(:backend-error status detail)` | The backend was reached and the exchange broke down: a non-OK status, a malformed payload, a stream cut short. |

`(:bad-request msg)` is pre-flight, so a malformed request never reaches the
network and "your ask was wrong" stays distinguishable from "the backend
misbehaved". `check-request` runs in `complete` and again in the handler, so a
protocol reached by a bare `m:call` sees the same checked request.
`tool-error-p` and `tool-error` take a result apart.

A protocol bounds its own work by the request's timeout and cancels what is in
flight, as tools do, so a wedged backend costs a timeout rather than a wedged
service.

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

`:provider-ollama` binds this protocol to a local backend with no key, so it is
testable end to end locally — see [providers](providers.md). The offline tests
run against the fake HTTP server; set `NYAA_OLLAMA_URL` (and optionally
`NYAA_OLLAMA_MODEL`) to run the live ones too.

## Discovery

```lisp
(nyaa:protocols)                       ; => (:protocol-openai)
(nyaa:describe-protocol :protocol-openai)
```

`protocols` scans registration props for `:kind :protocol`, the way `tools`
scans for `:kind :tool`. `complete` reaches a [provider](providers.md) by name
the same way, since a provider answers the same messages.

## Limitations

- The stream vocabulary has no error event. A stream that breaks down mid-turn
  ends as the call's `(:backend-error ...)` reply, so a consumer of the sink
  alone sees the events stop without a reason
  ([#31](https://todo.sr.ht/~takeiteasy/nyaa/31)).
- A completion in flight can only be abandoned at its deadline; there is no
  cancel message ([#32](https://todo.sr.ht/~takeiteasy/nyaa/32)).
- Rendering `:tools` onto a wire is each protocol's own work. A shared renderer
  waits until two protocols want the same one
  ([#33](https://todo.sr.ht/~takeiteasy/nyaa/33)).
- A completion abandoned at its deadline leaves its reader thread blocked until
  the backend answers or the connection drops
  ([#34](https://todo.sr.ht/~takeiteasy/nyaa/34)).
- A protocol service handles one completion at a time: meow's service loop runs
  one message to completion before the next, so concurrent turns queue
  ([#35](https://todo.sr.ht/~takeiteasy/nyaa/35)).
- A tool call naming a tool absent from the request's `:tools` has no schema to
  render its arguments by, and falls back to a heuristic
  ([#36](https://todo.sr.ht/~takeiteasy/nyaa/36)).
