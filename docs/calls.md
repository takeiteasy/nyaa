# The call log

Every tool call an agent dispatches is recorded in an append-only log, so its
status outlives the agent that dispatched it. Off by default.

```lisp
(m:mount *ctx* 'nyaa:agent :name :assistant :model :provider-ollama
                           :tools '(:tool-shell) :call-log t)

(nyaa:call-entries (merge-pathnames ".nyaa/calls.log" (user-homedir-pathname)))
;; => ((:id "20260925-101500-123456-0" :agent :assistant :call-id "c1"
;;      :name :tool-shell :arguments "{\"command\":\"ls\"}" :turn 1
;;      :status :ok :content "{\"stdout\":\"...\"}" ...))
```

## `:call-log`, the agent mount option

| Value | Records to |
|---|---|
| `nil` (default) | nowhere |
| `t` | `~/.nyaa/calls.log`, resolved when first used |
| a string or pathname | that file |

A delegated [sub-agent](agent.md) inherits its parent's `:call-log`, so its
calls land in the same file. A [fork](forking.md) is mounted as its source was.

## Statuses

| `:status` | Meaning |
|---|---|
| `:accepted` | dispatched, waiting for a slot under `:max-parallel-tools` |
| `:running` | handed to its tool, or [detached](agent.md#detached-tool-calls) and still running, until its result lands |
| `:ok` | answered |
| `:error` | the tool failed, or the call was outside the allow-list |
| `:interrupted` | closed unanswered by `:cancel`, `:deadline`, an interrupting `:steer`, or a [restore](checkpoints.md) |
| `:abandoned` | the agent's process exited with the call outstanding |
| `:lost` | accepted or running, and the process that dispatched it is gone[^liveness] |

A call keeps the first outcome written for it.

## The log

```lisp
(:kind :call    :id "..." :at "iso" :agent :assistant :call-id "c1"
 :name :tool-shell :arguments "<json>" :turn 1 :by (:pid 4242 ...))
(:kind :running :id "..." :at "iso")
(:kind :done    :id "..." :at "iso" :outcome :ok :content "<json>")
(:kind :input   :id "..." :at "iso" :agent :assistant :input-id "k"
 :digest "<md5>" :by (:pid 4242 ...))
```

An `:input` is a `:run` keyed with an `:input-id`, [recorded to spot a
redelivery](inputs.md). A `:done` entry finishes it as it does a call.
`call-entries` leaves it out.

`:id` is the log's own, one per dispatch. `:call-id` is the provider's, which
a provider may reuse on a later turn. `:arguments` and `:content` are JSON
text, cut to `:max-tool-result` characters or, with none set,
`*call-log-max-content*` (16 KiB). The log is read with `*read-eval*` nil and
appended under the same lock as the [vault](vault.md#the-log).

## API

| Function | Answers |
|---|---|
| `(call-entries path)` | each call, oldest first, with its `:status`, `:done-at` and `:content` |
| `(input-entries path)` | each keyed `:run`, oldest first, with its `:status` and `:done-at` |
| `(call-log-compact path :max-age s)` | the calls dropped and kept |

`call-log-compact` drops finished calls older than `max-age` seconds (default
`*call-log-max-age*`, 7 days; `0` drops every finished one) with their lines.
Calls not finished are kept. A log with a malformed entry is left as it is and
`call-log-compact` answers nil. An append also compacts once the file passes
`*call-log-compact-size*` (1 MiB) and has doubled since the last attempt.

## Limitations

- A call that finishes after its agent exited is `:abandoned` with no result
  ([#180](https://todo.sr.ht/~takeiteasy/nyaa/180)).
- A call is recorded, not resumed: nothing reattaches to or re-runs a `:lost`
  or `:abandoned` one ([#77](https://todo.sr.ht/~takeiteasy/nyaa/77)).
- There is no tool to list the log
  ([#179](https://todo.sr.ht/~takeiteasy/nyaa/179)).
- Writes are synchronous on the agent's process
  ([#181](https://todo.sr.ht/~takeiteasy/nyaa/181)).

[^liveness]: The dispatching process is judged as a vault
    [claim](vault.md#claims) is: alive while this image, another host, or a
    pid started at the recorded time. A call whose agent exited inside a
    running image is `:abandoned`, not `:lost`, because the agent records it
    as it exits.
