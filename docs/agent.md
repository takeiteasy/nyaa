# The agent loop

An agent is a [meow](https://github.com/takeiteasy/meow) agent (`M:AGENT`)
that sends a conversation to a bound [model](providers.md), dispatches the
tool calls that come back through [`invoke-tool`](tools.md), feeds the
results in and goes round again. It registers under `:kind :agent`, the same
convention discovery uses for tools, protocols and providers.

It is message-driven rather than a blocking call: every model turn, tool
call and sub-agent is issued from a spawned process and reported back as a
message, so the agent is never blocked waiting on one and stays responsive
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
the previous result's `:messages` back in as the next `:run`'s. Mount with
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
| `:sink` | nil | a stream sink, as `complete` takes |
| `:sampling` | nil | a plist passed through to `complete`, e.g. `:temperature` |

## The allow-list and trust

`:tools` defaults to every discovered tool whose [`:trust`](tools.md) is
`:agent` — `tool-fs`, `tool-plan`, `tool-image` and `tool-services` today;
`tool-shell`, `tool-http`, `tool-eval` and `tool-repl` are all `:operator`
and only reach the model when the mount site names them explicitly:

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
| `(:run . plist)` | start a run: `:messages` and any `complete` sampling keys |
| `(:steer :content text)` | queue a `:user` message, folded in before the next turn |
| `(:cancel)` | finish the run now, reason `:cancelled` |

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

A `complete` failure — `(:backend-error ...)`, `:timeout`, `:unavailable` —
ends the run as that same `(:error reason)`, unwrapped.

## Events

`:sink` takes an event of one type per message, echoing `:ref` as
[protocols](protocols.md#streaming) do. The protocol's own `:text-delta`,
`:tool-call-delta` and `:done` pass straight through, since the sink is
handed down in the request unchanged; the loop adds:

```lisp
(:type :turn        :ref r :turn n)
(:type :tool-call   :ref r :id "c1" :name :tool-shell :arguments (:cmd "ls"))
(:type :tool-result :ref r :id "c1" :result (:ok (:out "...")))
(:type :run-done    :ref r :reason :stop)
```

## Sub-agents

With `:sub-agents t`, the model gets a reserved tool, `agent-task`, taking one
`:task` string. Calling it delegates a child agent — under meow's own agent
supervisor, via `m:delegate` — with this agent's model and allow-list, runs
it to completion, and returns its final answer as the tool result. A child
does not itself get `:sub-agents`, so delegation does not nest by default.

Reaching the parent's `handle` from a delegated child needs
[`~takeiteasy/meow#59`](https://todo.sr.ht/~takeiteasy/meow/59): meow's
`%dispatch` dropped a service parent's `:agent-done`/`:agent-down` before
that fix, so a mounted or delegated `nyaa:agent` on an unpatched meow will
never see a sub-agent finish.

Which models and tool sets a child may be given beyond inheriting the
parent's is [`~takeiteasy/nyaa#22`](https://todo.sr.ht/~takeiteasy/nyaa/22)'s
policy (the orchestrator DSL), not this loop's.

## Limitations

- Conversation growth is unbounded: there is no context-window accounting or
  compaction, so a long run eventually overruns the model's window
  ([#39](https://todo.sr.ht/~takeiteasy/nyaa/39)).
- A tool result is rendered whole with no size cap, so one large result can
  fill the context ([#40](https://todo.sr.ht/~takeiteasy/nyaa/40)).
- One thread per outstanding model turn and tool call; no pooling or
  concurrency cap ([#41](https://todo.sr.ht/~takeiteasy/nyaa/41)).
- No retry or backoff on a transient backend error — the run ends on the
  first one ([#42](https://todo.sr.ht/~takeiteasy/nyaa/42)).
- `:cancel` and `:deadline` end the run at once, but the `complete` call
  already in flight keeps running to its own timeout
  ([#32](https://todo.sr.ht/~takeiteasy/nyaa/32)).
