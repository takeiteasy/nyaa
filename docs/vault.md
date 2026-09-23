# Vault: the steering message log

An append-only s-expression log of [steering](agent.md#messages) messages,
each marked consumed once it has been folded into a run or discarded. It
backs an agent's own in-memory steer queue, so a steer survives past the
run it was sent to, a crash, or a restart -- not just the next turn. See
[~takeiteasy/nyaa#14](https://todo.sr.ht/~takeiteasy/nyaa/14).

```lisp
(m:mount *ctx* 'nyaa:agent :name :assistant :model :provider-ollama :vault t)
(m:mount *ctx* 'nyaa:tool-vault)

(m:cast (m:lookup :assistant) '(:steer :content "focus on the tests"))
(nyaa:invoke-tool :tool-vault :op :list)
;; => (:ok (:entries ((:id "..." :agent :assistant :content "focus on the tests"
;;                      :status :pending ...)) :total 1))
```

## `:vault`, the agent mount option

Off (`nil`) by default: steering stays in-memory only, exactly as before
this landed. `t` records to the default log, `~/.nyaa/vault.log`, resolved
lazily so mounting an agent never touches the filesystem on its own. A
string or pathname records there instead.

A steer records before it queues, and is marked `:folded` at the point
`issue-turn` actually pushes it onto the conversation -- not when `:steer`
is sent. A steer queued while a turn is already in flight, with no further
turn to fold it into before the run ends, stays `:pending`: nothing marks
it consumed, so it is still there to restore later.

A delegated sub-agent (agent.lisp's `agent-task`) inherits its parent's
`:vault`, the same way it inherits the model and allow-list. It has no
registered name, though (checkpoint.lisp's `%context-entries` skips it the
same way), so a steer recorded against it carries `:agent nil` -- restoring
one needs an explicit `:agent` at the tool.

`:steer` also now folds in even when it was queued before `:run`: starting
a run no longer clears the queue, only the turn/tool-call state that
belongs to the run itself. A steer sent to an idle agent waits and folds in
after the seed messages, on the first turn.

## The log

```lisp
(:kind :steer    :id "20260923-140501-822931" :at "2026-09-23T14:05:01Z"
 :agent :assistant :content "focus on the tests")
(:kind :consumed :id "20260923-140501-822931" :at "2026-09-23T14:05:03Z"
 :how :folded)
```

`vault-entries` folds the log into current state, the same way
[`generations`](checkpoints.md) derives its list from files on disk rather
than an index. `:how` is `:folded` or `:discarded`. Read with `*read-eval*`
bound to nil, the same guard a generation and
[`tool-self`'s log](self.md#checkpoint-and-log) both apply, through the
same shared `%append-log`/`%read-log` helpers checkpoint.lisp declares -- so
a vault entry can never run code merely by being read back. Appends to one
log file serialise behind a lock of their own, keyed by the file's canonical
name, so different logs never wait on each other.

## Compaction

`(nyaa:vault-compact path :max-age seconds)` rewrites the log without the
steers consumed more than `max-age` seconds ago (default `*vault-max-age*`,
7 days; `0` drops every consumed steer) and their `:consumed` lines.
Pending steers are always kept. It answers the steers dropped and kept.

An append also compacts once the file passes `*vault-compact-size*` (1 MiB)
and has doubled since the last attempt. A log with a malformed entry is
never rewritten -- that would lose everything past the entry -- so
`vault-compact` answers nil and the file is left as it is.

## `tool-vault`

`:trust :operator`: restoring injects a `:user`-role message into whichever
agent is named, and listing surfaces operator-written steering text -- the
same posture as [`tool-checkpoint`](checkpoints.md#tool-checkpoint)'s own
writes to harness state.

| `:op` | Params | Answers |
|---|---|---|
| `:list` | `:status` (default `:pending`), `:limit` | `:entries`, `:total` |
| `:restore` | `:id` (required), `:agent` | `:agent`, `:id` |
| `:discard` | `:id` (required) | `:id` |
| `:compact` | `:max-age` (seconds, default `*vault-max-age*`) | `:dropped`, `:kept` |

```lisp
(m:mount *ctx* 'nyaa:tool-vault)
(nyaa:invoke-tool :tool-vault :op :restore :id "20260923-140501-822931")
```

`:restore` casts `(:steer :content ... :vault-id id)` at the named agent --
the id travels with it, so the agent's own fold marks the *original* entry
consumed rather than this tool recording a second one for the same steer.
It is not consumed at the point of the call; only once the target agent
actually folds it in. `:agent`, a string, picks the target: the entry's own
recorded agent by default, or an override -- required when the entry was
recorded with no agent, as a delegated sub-agent's always is. Restoring or
discarding an id that is unknown or already consumed is a
`(:bad-request ...)`. `:discard` checks and consumes under the log's lock,
so concurrent discards of one id consume it once.

`:path` is a mount option (default nil, meaning the same default an
agent's `:vault t` uses), read once at mount time.

## Limitations

- Compaction is safe within one process only; another process appending
  during a compaction loses its entry
  ([#84](https://todo.sr.ht/~takeiteasy/nyaa/84)).
- `:restore` checks an entry is pending, then casts it; two concurrent
  calls on one id can both deliver it
  ([#87](https://todo.sr.ht/~takeiteasy/nyaa/87)).
