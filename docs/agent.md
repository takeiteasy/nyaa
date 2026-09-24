# The agent loop

An agent is a [meow](https://github.com/takeiteasy/meow) agent (`M:AGENT`)
that sends a conversation to a bound [model](providers.md), dispatches the
tool calls that come back through [`invoke-tool`](tools.md), feeds the
results in and goes round again. It registers under `:kind :agent`, the same
convention discovery uses for tools, protocols and providers.

It is message-driven rather than a blocking call: every model turn, tool
call and sub-agent is issued off the agent's own process and reported back as
a message, so the agent is never blocked waiting on one and stays responsive
between turns — `:cancel` and `:steer` land during a run, not just before
one.

## Running one

```lisp
(m:mount *ctx* 'nyaa:protocol-ollama)
(m:mount *ctx* 'nyaa:provider-ollama :model "llama3.2")
(m:mount *ctx* 'nyaa:tool-shell)

(nyaa:run-agent *ctx* :model :provider-ollama :tools '(:tool-shell)
                :messages '((:role :user :content "How many .lisp files are here?")))
```

`run-agent` is the one place nyaa reaches the loop synchronously: it
delegates an agent on `*ctx*` (a mounted context's process), runs it to
completion, and returns `(:ok plist)` or `(:error reason)`.

A mounted, named agent works the same way any tool or provider does, driven
by messages instead:

```lisp
(m:mount *ctx* 'nyaa:agent :name :assistant :model :provider-ollama)
(m:cast (m:lookup :assistant) '(:run :messages ((:role :user :content "hi"))))
```

Finishing a run exits the agent with reason `:done` (M:AGENT's own
convention), and mount's default restart is `:transient`, which restarts on
anything but `:normal` or `:shutdown` — so `:assistant` comes back as a
fresh instance under the same name, ready for another `:run`, but with no
memory of the last one. A caller wanting the conversation to continue passes
the previous result's `:messages` back in as the next `:run`'s, or, on an
agent that already holds a conversation (a [restored](checkpoints.md) one),
sends `:run` with `:continue t` to carry on from it. Mount with
`:restart :temporary` for a one-shot agent that stays gone after it finishes.

## Mount options

| Option | Default | Meaning |
|---|---|---|
| `:model` | required | a protocol or provider service name |
| `:tools` | `:default` | an allow-list of tool names, or `:default` |
| `:system` | none | a system prompt, hoisted into the first message |
| `:max-turns` | 16 | model turns before the run stops itself |
| `:turn-timeout` | 30000 | milliseconds for one `complete` call |
| `:deadline` | 300000 | milliseconds for the whole run |
| `:sub-agents` | nil | whether the model may delegate a task |
| `:max-parallel-tools` | nil | tool calls running at once, sub-agents included; nil is uncapped |
| `:max-tool-result` | nil | most characters of a tool result's text that reach the conversation; nil is uncapped |
| `:max-context` | nil | most tokens (estimated) a request carries, conversation and tool schemas; the oldest turns past it are left out of the request. nil is unbounded |
| `:chars-per-token` | 3 | characters per token the estimate starts from; recalibrated from each reply |
| `:turn-retries` | 0 | times a turn that failed transiently is sent again |
| `:retry-backoff` | 1000 | milliseconds before the first retry; each later one waits twice as long, plus up to 25% jitter |
| `:sink` | nil | a stream sink, as `complete` takes |
| `:sampling` | nil | a plist passed through to `complete`, e.g. `:temperature` |
| `:vault` | nil | record steering to the [vault](vault.md): nil is off, `t` the default log, a path to record there instead |

## The allow-list and trust

`:tools` defaults to every discovered tool whose [`:trust`](tools.md) is
`:agent` — `tool-fs`, `tool-plan`, `tool-image` and `tool-services` today;
`tool-shell`, `tool-http`, `tool-eval`, `tool-repl`, `tool-checkpoint` and
`tool-self` are all `:operator` and only reach the model when the mount
site names them explicitly:

```lisp
(m:mount *ctx* 'nyaa:agent :model :provider-ollama :tools '(:tool-shell))
```

A call naming a tool outside the allow-list, and a tool error of any kind,
both come back to the model as a `:tool` message rather than ending the run —
the model gets a chance to recover, the same way a backend error does not
end a plain `complete` turn early inside a working conversation.

## Messages

| Message | Effect |
|---|---|
| `(:describe)` | the metadata plist |
| `(:run . plist)` | start a run: `:messages` and any `complete` sampling keys. `:continue t` keeps the agent's current conversation and appends `:messages` to it; `:turns` and `:max-turns` still count from zero |
| `(:steer :content text)` | queue a `:user` message, folded in before the next turn -- even one queued before `:run`, or while the agent is idle. A steer queued during a turn that would end the run gets a turn of its own, unless `:max-turns` is spent |
| `(:steer :content text :interrupt t)` | as `:steer`, but a model turn or tool calls in flight are abandoned and the steer folds in at once |
| `(:cancel)` | finish the run now, reason `:cancelled` |

`:steer` takes an optional `:vault-id`, naming an entry already in the
[vault](vault.md) -- `tool-vault`'s `:restore` redelivers a steer this way
rather than recording a second entry for the same one. A caller queueing a
fresh steer never needs to pass it; when `:vault` is on, it is recorded and
consumed automatically.

An interrupting steer cancels the turn in flight and issues the next one
straight away. Text the turn had already streamed to the `:sink` is kept as
an assistant message ahead of the steer; a half-streamed tool call is
dropped, and with no `:sink` nothing is kept. The abandoned turn counts
against `:max-turns`, so an interrupt on the last allowed turn finishes the
run as `:max-turns` and leaves the steer queued.

With tool calls outstanding instead, an interrupting steer
[cancels](#cancelling-tool-calls) each call still running and closes it with
an `{"error":"interrupted"}` `:tool` message, keeps the results already in,
and issues the next turn with the steer folded in, without waiting on the
slowest call. Between turns or before `:run`, `:interrupt` does nothing extra
and the steer waits for the next turn.

The rest — `:step`, `:turn-reply`, `:tool-reply`, `:deadline` — are internal,
driving the machine between spawned work and the agent's own mailbox.

## The result

```lisp
(:ok (:messages <conversation> :content <blocks> :turns n :stop-reason r))
```

`:messages` is the whole conversation, ready to seed another run.
`:content` is the final assistant turn's content, when the run ended that
way. `:stop-reason` is one of:

| Reason | Meaning |
|---|---|
| `:stop` | the model finished without a tool call |
| `:max-turns` | `:max-turns` model turns were reached |
| `:timeout` | `:deadline` lapsed |
| `:cancelled` | `:cancel` was sent |

`:cancel` and `:deadline` also cancel the model turn in flight, closing its
connection rather than waiting out `:turn-timeout`.

A `:cancelled` or `:timeout` run [cancels](#cancelling-tool-calls) each tool
call still awaiting a result and closes it with an `{"error":"interrupted"}`
`:tool` message, so `:messages` is always well-formed to send back to a
model. Each closed call also emits a `:tool-result` event carrying `(:error
:interrupted)`.

### Cancelling tool calls

Each call is dispatched with a [cancel token](tools.md#cancelling-a-call) of
its own, cancelled when the call is closed unanswered. A call still queued
behind another on the same tool never runs; one already running stops as its
tool allows -- a shell command, HTTP exchange, worker or plan step is
abandoned, and a sub-agent is sent `:cancel`. A reply that arrives after its
call was closed is dropped, even when the next turn reuses its id.

### Capping tool calls

With `:max-parallel-tools`, calls past the cap wait, in order, and each starts
as a running one answers. A sub-agent holds its slot for its whole run; a call
refused by the allow-list answers at once and holds none. A call still waiting
when the calls are closed never runs, and closes as `interrupted` like any
other.

### Capping a tool result

With `:max-tool-result`, a `:tool` message in the request whose text is longer
is cut there, and a note says how much was dropped, so the model knows it saw
part of it:

```
{"text":"xxxxxxxx... [truncated: 211 characters, first 50 kept]
```

The cut is made on the request only. The conversation, the result's
`:messages` and the `:tool-result` event a sink sees carry the whole result,
and the [`:context-trimmed`](#events) event lists each cut. The cut text is
not valid JSON.

## Fitting the context

With `:max-context`, a request that would carry more than that many tokens
leaves out the oldest turns until it fits, and a note stands in for them:

```
[6 earlier messages omitted to fit the context budget]
```

| Kept | Left out |
|---|---|
| `:system` messages | the oldest turns first |
| the newest turn | an assistant turn with its tool calls and their `:tool` replies, always together |

If the system messages and the newest turn alone pass the budget, the request
is sent anyway and the event says `:over-budget t`.

The conversation is never shortened: the result's `:messages` and a
[checkpoint](checkpoints.md) hold the whole of it, and each request trims a
fresh view. A sink hears what a request left out or cut through
[`:context-trimmed`](#events).

### Counting tokens

The agent counts characters and converts at `:chars-per-token`[^ratio]:

| Step | Detail |
|---|---|
| First turn | the ratio is `:chars-per-token`, 3 unless set |
| After each reply | the ratio becomes the characters the request carried over the reply's prompt-token count (`:meta :usage :prompt-tokens`, see [protocols](protocols.md)) |
| A reply with no count | the last ratio stays |
| Margin | a request fills at most 90% of `:max-context` |
| Counted | messages and the tool schemas sent with them |

So a 4000-token budget at 4 characters per token fits 14,400 characters
(4000 × 0.9 × 4), less the tool schemas.

A sub-agent starts from its parent's ratio. A [checkpoint](checkpoints.md)
does not hold it: an agent restored elsewhere starts from `:chars-per-token`
again and recalibrates after one reply.

## Failed turns

A `complete` failure — `(:backend-error ...)`, `:timeout`, `:unavailable` —
ends the run as that same `(:error reason)`, unwrapped. So does a `:model`
nothing is registered under. With `:turn-retries`, a transient one is sent
again first:

| Failure | Retried |
|---|---|
| `:unavailable` | yes |
| `:backend-error` with status 408, 425, 429 or 5xx | yes |
| `:backend-error` with a 2xx status (a stream or payload cut short) | yes |
| other `:backend-error` statuses, `:timeout`, `:cancelled` | no |

A retry waits `:retry-backoff`, doubled each time, plus up to 25% jitter, and
emits `:turn-retry`. It is not a new turn: `:turns` and `:max-turns` do not
count it, and `:deadline` still bounds the run. What the failed attempt
streamed is dropped. A `:cancel`, `:deadline` or `:restore` during the wait
ends it. A `:steer` folds into the retry; with `:interrupt t` the retry
goes out at once.

A tool call is never retried; its side effects may not be safe to repeat.

## Events

`:sink` takes an event of one type per message, echoing `:ref` as
[protocols](protocols.md#streaming) do. The protocol's own `:text-delta`,
`:tool-call-delta` and `:done` pass straight through; the loop adds:

```lisp
(:type :turn        :ref r :turn n)
(:type :turn-interrupted :ref r :turn n)
(:type :turn-retry  :ref r :turn n :attempt 1 :reason (:backend-error 503 "..."))
(:type :tool-call   :ref r :id "c1" :name :tool-shell :arguments (:cmd "ls"))
(:type :tool-result :ref r :id "c1" :result (:ok (:out "...")))
(:type :run-done    :ref r :reason :stop)
(:type :context-trimmed :ref r :turn n :omitted (1 2 3) :truncated ((4 :from 900 :to 50))
       :size 240 :budget 250 :ratio 3.9 :over-budget nil)
```

`:context-trimmed` precedes a request that left out or cut anything, before
that turn's model call. `:omitted` and `:truncated` index into the whole
conversation, so a listener can tell which messages were affected; `:truncated`
entries are `(index :from characters :to kept)`. `:size` and `:budget` are
tokens, `:size` estimated at `:ratio` characters per token. A retried turn is built again
and reports again.

An interrupted turn ends with `:turn-interrupted` rather than a `:done`:
nothing it streams reaches the sink after it, and the next `:turn` follows.

A turn whose `complete` failed emits the protocol's `:done` with
`:reason (:error r)`, then `:turn-retry` if it is retried, or `:run-done` if not. A turn cut short by `:cancel` or
`:deadline` ends at `:run-done`, with no `:done` of its own.

A function sink is called on a pooled thread, one event at a time and in
order, and a sub-agent's events pass through the same queue. A
sink that blocks never holds up the agent: `:steer` and `:cancel` still land.
`:run-done` is the last event a function sink sees, though the parent can get
`:agent-done`, and `run-agent` return, before the sink has taken it. A sink that has not taken `:run-done` five seconds after
the run ends is stopped, and the events still queued for it are dropped. A
sink that signals an error loses that event and carries on.

## Sub-agents

With `:sub-agents t`, the model gets a reserved tool, `agent-task`, taking one
`:task` string. Calling it delegates a child agent — under meow's own agent
supervisor, via `m:delegate` — with this agent's model, allow-list,
`:max-parallel-tools` and `:vault`, runs it to completion, and returns its final answer as the tool
result. The child's `:ref`, echoed on its events, is a cons of an internal
step counter and the call id. A child does not itself get `:sub-agents`, so
delegation does not nest by default, and it is never registered under a name, so a steer
recorded against it carries no `:agent` (see [the vault](vault.md)).

Reaching the parent's `handle` from a delegated child needs
[`~takeiteasy/meow#59`](https://todo.sr.ht/~takeiteasy/meow/59): meow's
`%dispatch` dropped a service parent's `:agent-done`/`:agent-down` before
that fix, so a mounted or delegated `nyaa:agent` on an unpatched meow will
never see a sub-agent finish.

Which models and tool sets a child may be given beyond inheriting the
parent's is [`~takeiteasy/nyaa#22`](https://todo.sr.ht/~takeiteasy/nyaa/22)'s
policy (the orchestrator DSL), not this loop's.

## Checkpoints

An agent's `snapshot` keeps `:messages` and `:turns`, not the turn or tool
calls in flight — see [checkpoints](checkpoints.md). A checkpoint taken
mid-run keeps the conversation, closes each unanswered tool call as
`interrupted` and drops the abandoned turn; `restore` always lands a
not-running agent, ready for `(:run :continue t)`, and nothing more from the
abandoned turn reaches the sink.

## Limitations

- A request over `:max-context` drops old turns rather than summarising them
  ([#139](https://todo.sr.ht/~takeiteasy/nyaa/139)).
- A streamed turn on an OpenAI-style backend reports no prompt-token count,
  so it does not recalibrate the ratio
  ([#142](https://todo.sr.ht/~takeiteasy/nyaa/142)).
- The first turn is measured at the default ratio; an exact count before it
  needs a tokenizer ([#143](https://todo.sr.ht/~takeiteasy/nyaa/143)).
- A retry ignores a backend's `Retry-After` header
  ([#135](https://todo.sr.ht/~takeiteasy/nyaa/135)).

[^ratio]: The ratio is per agent, not per content type: code and JSON
    tokenise worse than prose, which the 10% margin absorbs. A reading under 1
    or over 8 characters per token is ignored. `:max-tool-result` stays in
    characters, as do `:from` and `:to` in `:context-trimmed`. `:max-context`
    is the prompt's share of the window; leave room below it for the reply.
