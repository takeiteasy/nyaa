# Client state

`nyaa/ui` folds an agent's [events](ui.md#events) into the state an operator
sees, and sends the operator's [commands](ui.md#commands) back. It draws
nothing: a renderer reads the state and never reads events itself.

```lisp
(ql:quickload :nyaa/ui)
(m:mount *ctx* 'nyaa:agent :name :assistant :model :provider-ollama)

(let ((client (nyaa/ui:attach :assistant :on-change #'redraw)))
  (nyaa/ui:run client "hi")
  (nyaa/ui:client-state client))
```

## Attaching

| Call | Effect |
|---|---|
| `(attach name &key on-change registry)` | subscribe to the agent mounted as `name` and return a client |
| `(detach client)` | unsubscribe; events already on their way may still arrive |
| `(client-state client)` | the state so far, an immutable snapshot |

`on-change` is called with each new state, from the thread that delivered the
event. A snapshot is safe to draw from any thread.

## Commands

| Call | Sends |
|---|---|
| `(run client text)` | `(:run :messages ...)` with `text` as the user's message |
| `(continue-run client text)` | `(:run :continue t :messages ...)` |
| `(steer client text &key interrupt)` | `(:steer :content text)` |
| `(cancel client)` | `(:cancel)` |

Each answers what the agent answers. The agent restarts after every run, so a
command waits up to `*command-timeout*` seconds (5) for it and then signals
`agent-unavailable`.

## State

`fold-event` takes a state and an event and returns the next state. It never
changes the state it is given and never signals, so a subscriber that joined
mid-run, or an event type it does not know, is folded as far as it makes sense.

| Reader | Meaning |
|---|---|
| `(state-status s)` | `:idle`, `:running` or `:done`, for the root agent |
| `(state-reason s)` | the last `:run-done` reason |
| `(state-turn s)` | the current turn |
| `(state-transcript s)` | the root's entries, oldest first |
| `(state-joined-mid-run s)` | true when the client attached during a run |
| `(state-root s)`, `(state-children s node)` | the agent tree, see [below](#agents) |

Each transcript entry has an `entry-kind`:

| Kind | From | Readers |
|---|---|---|
| `:message` | the messages of `:run-start` | `entry-role`, `entry-text` |
| `:steer` | `:steer` | `entry-text`, `entry-status` is `:interrupt` for an interrupting steer |
| `:text` | `:text-delta`, one entry per turn's run of text | `entry-text` |
| `:call` | tool call events | `entry-id`, `entry-name`, `entry-arguments`, `entry-status`, `entry-result` |
| `:notice` | retries, trims, interrupts, failed turns | `entry-name` is the kind, `entry-result` its detail |

A call's status is `:streaming` (its arguments are still arriving, and
`entry-text` holds them so far), `:running`, `:detached`, `:abandoned` or
`:done`.[^text]

### Agents

The root node holds the agent's own run. A sub-agent has a node of its own,
with its transcript, status and reason, listed by `state-children` under the
node whose call started it.[^tree]

```lisp
(let ((root (nyaa/ui:state-root state)))
  (dolist (child (nyaa/ui:state-children state root))
    (format t "~a: ~a~%" (nyaa/ui:node-call-id child) (nyaa/ui:node-status child))))
```

## Limitations

- `continue-run` carries on from the agent's conversation, which a named agent
  does not keep across its restart after a run
  ([#198](https://todo.sr.ht/~takeiteasy/nyaa/198)).
- A client that attaches mid-run has the status and turn but not the run so
  far ([#196](https://todo.sr.ht/~takeiteasy/nyaa/196)).
- Sub-agent nodes are found by call id, and cannot be steered or cancelled
  ([#200](https://todo.sr.ht/~takeiteasy/nyaa/200)).
- There is no state for operator approvals
  ([#199](https://todo.sr.ht/~takeiteasy/nyaa/199)).

[^text]: Streamed text is kept as chunks and joined by `entry-text`, so a long
    answer does not copy itself on every delta.

[^tree]: A sub-agent's events carry the ref `(step . call-id)` and a `:parent`
    key, and its node is keyed on that ref. The parent is the node whose
    transcript holds the call.
