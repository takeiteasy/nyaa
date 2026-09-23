# Checkpoints and rollback

A generation is a snapshot of every named service's own declared state,
written as one s-expression file. `checkpoint` takes one; `rollback` puts it
back.

```lisp
(nyaa:checkpoint *ctx* :label "before edit")
;; => #P"~/.nyaa/generations/20260922-171610-129774.generation"

(nyaa:generations)
;; => ((:path #P"..." :created "2026-09-22T17:16:10Z" :label "before edit"
;;      :services (:tool-fs :assistant)) ...)

(nyaa:rollback *ctx* "~/.nyaa/generations/20260922-171610-129774.generation"
               :timeout 30)
;; => (:ok (:restored (:tool-fs :assistant) :failed nil :failures nil :interrupted nil
;;          :unavailable nil :missing nil :mismatched nil :extra nil))
```

`checkpoint` returns the path, then the names of the services snapshotted
mid-work and of those that could not be snapshotted. Every service is asked
at once and given `:timeout` seconds (default 30), so one busy service does
not delay the rest.

Declared-state generations by default; a generation can also carry the
image itself -- see [image generations](images.md).

## `snapshot` and `restore`

Every tool, the agent and a provider answer two messages, `(:snapshot)` and
`(:restore state)`, backed by a generic function each service may specialise:

```lisp
(defgeneric snapshot (service))   ; -> a plain value, or nil
(defgeneric restore (service state))
```

Both default to `nil`: most services hold nothing worth carrying across a
restart. The agent is the one service with a method today — it keeps
`:messages` and `:turns`. While a run is in progress it also reports
`:in-flight (:turn n :tool-calls (ids...))`. Only the ids are kept: the turn
and tool calls reference processes a restore cannot bring back, so they are
not retried. `restore` always lands a not-running agent, so a further `:run`
is accepted at once.

Any service whose state is a plist with a non-nil `:in-flight` is reported
as interrupted.

## The generation file

```lisp
(:nyaa-generation 1
 :created "2026-09-22T17:16:10Z"
 :label "before edit"
 :services ((:name :tool-fs :class "tool-fs" :state nil)
            (:name :assistant :class "agent"
             :state (:messages (...) :turns 3))
            (:name :slow :class "slow-thing" :unavailable :timeout)))
```

A service that does not answer within the deadline, or exits or deadlocks
first, is recorded `:unavailable` with the reason and no `:state`.

Read with `*read-eval*` bound to `nil` — the same guard `tool-eval`'s worker
applies to a submitted form — so a generation can never run code merely by
being read back in. Written through a temporary file and renamed in, so a
torn write never replaces a good one.

A generation records each named child's `:name` and `:class`, both already
published by `m:children`, never its mount initargs. A provider's `:api-key`
is one, and keeping a credential out of published state is the same line
[providers](providers.md#credentials) and [`tool-image`](introspection.md)
both hold — a generation on disk holds it too, so it draws the line there
rather than at metadata alone.

## Rollback and drift

`rollback` restores state onto the services mounted now; it does not
remount. Every restore is sent at once and given `:timeout` seconds (default
30), so one busy service does not delay the rest. Drift since the checkpoint is reported rather than silently
accepted:

| Key | Meaning |
|---|---|
| `:restored` | names whose state was applied |
| `:failed` | names whose restore got no answer |
| `:failures` | each failed name with its reason: `(name :timeout)`, `(name :down)`, `(name :error)` or `(name :deadlock)` |
| `:interrupted` | restored names that were snapshotted mid-work; the in-flight work is gone |
| `:unavailable` | names the checkpoint could not snapshot — left as they are |
| `:missing` | a generation entry with no service mounted under that name now |
| `:mismatched` | mounted now, but under a different class — not restored |
| `:extra` | mounted now, not named by the generation |

## `tool-checkpoint`

`:trust :operator`: writing and reverting the harness's own state is not
something the default `:agent` trust level should reach.

| `:op` | Params | Answers |
|---|---|---|
| `:save` | `:label`, `:keep` | `:path`, `:interrupted`, `:unavailable` |
| `:list` | — | `:generations` (each with `:interrupted`, `:unavailable`) |
| `:restore` | `:path` (required) | as `rollback` |

```lisp
(m:mount *ctx* 'nyaa:tool-checkpoint)
(nyaa:invoke-tool :tool-checkpoint :op :save :label "before edit")
```

`:save` runs inside the tool's own process, which cannot answer its own
snapshot, so `:tool-checkpoint` is always listed under `:unavailable`.

`:dir` is a mount option (default `*generations-directory*`,
`~/.nyaa/generations/`), read once at mount time — a caller wanting a
different directory per call goes through `checkpoint`/`rollback` directly
instead, as [`tool-self`](self.md) does before every write it makes.

## Limitations

- Rollback restores state, not the mount set: a service unmounted since the
  checkpoint is reported as `:missing`, never remounted
  ([#49](https://todo.sr.ht/~takeiteasy/nyaa/49)).
