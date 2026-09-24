# Tools

A tool is a [meow](https://github.com/takeiteasy/meow) service that follows one
extra convention, so any caller — including the agent loop — can discover,
describe and invoke every tool the same way.

## The convention

A tool registers under `:tool-<name>`, and its `metadata` plist carries
`:kind :tool`, a `:summary`, its `:params` and its `:trust` level.
`define-tool` declares all of this in one form:

```lisp
(define-tool :tool-shell
    (:trust :operator
     :summary "Run a shell command (sh -c) and capture merged output"
     :params ((:cmd string :required t :doc "command string to run")
              (:timeout (integer 1) :default +default-tool-timeout+
               :doc "kill the command after this many milliseconds")))
  (:invoke (cmd timeout)
    (run-command cmd timeout cancel-token)))
```

`NAME` is given once, as the leading keyword, and is used for the class, the
registration and the metadata — it cannot drift between them the way it could
when `defservice`, a `metadata` method and a handler were three separate forms
each naming the tool.

`:params` is a typed [schema](schema.md), checked at macroexpansion: a bad
specifier is a compile-time error. It drives coercion and validation, so a
tool's `:invoke` clause reads its arguments already coerced — `(:invoke (cmd
timeout) ...)` binds `cmd` and `timeout` from the plist, in their declared
types — and it renders to the JSON Schema a model needs for tool calling.
`tool-schema` reads it out of the metadata. `:slots` passes extra slots
through to the generated class, as `tool-fs`'s sandbox root does. Inside
`:invoke`, the anaphoric `service` is the tool itself and `cancel-token` is
the call's [cancel token](#cancelling-a-call), or nil.

`:trust` is `:operator` for a tool only a trusted operator may reach, and
`:agent` for one a model may call. `tool-trust` reads it, and answers `:agent`
for metadata that names none. The [agent loop](agent.md)'s default allow-list
is exactly the `:agent`-trusted tools — `tool-fs`, `tool-plan`, `tool-image`
and `tool-services` are the standard tools at that level, so granting the
others to a model is explicit at the mount site.

A tool needing another `handle` clause beyond `:describe` and `:invoke` falls
back to `defservice` and the lower-level `define-tool-handler` directly. It
answers two messages either way:

- `(:describe)` — replies with the metadata plist
- `(:invoke . plist)` — coerces the plist against the schema, then performs the
  operation

Every tool also answers `(:snapshot)` and `(:restore state)`, backed by the
`snapshot`/`restore` generic functions a tool may specialise; both default to
nil. See [checkpoints](checkpoints.md).

Meow intercepts the heads `%update-config`, `%effects` and `%timer-fire` before
`handle`, so a tool must not use them.

## Results

```lisp
(:ok plist)       ; the tool's own return values
(:error reason)   ; one vocabulary across every tool and adapter
```

`reason` is one of:

| Reason | Meaning |
|---|---|
| `(:bad-request msg)` | The invoke arguments are malformed, or will not coerce. |
| `:timeout` | The deadline lapsed. |
| `:cancelled` | The call's cancel token was cancelled. |
| `:unavailable` | The far end could not be reached. |
| `(:error detail)` | Anything else. |
| `(:forbidden msg)` | `tool-fs`: the path escapes the sandbox. `tool-self`: the op is not in `:enable`. |

`tool-error-p` and `tool-error` take a result apart.

`invoke-tool` folds a call that fails below the tool itself -- its process
already exited, or the call would have deadlocked -- into the same
vocabulary: `:timeout`, `:unavailable` for the tool's process being gone, and
`(:error detail)` for anything else, `detail` a printed string.

## Discovery

`(tools)` scans registration props for `:kind :tool`. Props are a snapshot taken
at registration — there is no setter — so a tool's advertised `:params` change
only when it is reloaded. `invoke-tool` reads the schema from there, and
`tool-metadata` the whole plist, neither costing a message to the tool, so a
tool busy with a long call never holds them up. `describe-tool` asks the tool
itself.

```lisp
(nyaa:tools)  ; => (:tool-fs :tool-http :tool-shell)
```

## Invocation

```lisp
(nyaa:describe-tool :tool-shell)
(nyaa:invoke-tool :tool-shell :cmd "ls -la")
(nyaa:schema->json-schema (nyaa:tool-schema (nyaa:describe-tool :tool-shell)))
```

`invoke-tool` coerces its arguments against the tool's schema first, so a
model-supplied `:timeout "15000"` bounds the wait exactly as `15000` does.

`invoke-tool` waits longer than the tool's own `:timeout`, so the tool's bounded
`(:error :timeout)` is what a caller sees. Calling a tool with a bare `m:call`
instead would abort the *caller* after meow's 5-second default while the tool
kept running.

## Cancelling a call

`:cancel` is a reserved argument: a cancel token, as
[`complete`](protocols.md#cancelling) takes, handed to the tool rather than
coerced against its schema.

```lisp
(let ((token (nyaa:make-cancel-token)))
  (bt:make-thread (lambda () (sleep 1) (nyaa:cancel token)))
  (nyaa:invoke-tool :tool-shell :cmd "sleep 30" :cancel token))
; => (:error :cancelled)
```

Every tool refuses a call whose token is already cancelled, without running
it -- a call queued behind another on the same tool included. Cancelling one
already running stops its work, as a lapsed `:timeout` does, in `tool-shell`
(the whole process group), `tool-http` (the connection), `tool-eval` and
`tool-repl` (the worker, so that `:id` starts empty), `tool-plan` (the step
in flight, and none after it) and `tool-self` (an `:eval` or `:define`; see
[self-modification](self.md)). The other tools finish what they started.

## The standard tools

| Tool | Parameters | Notes |
|---|---|---|
| `:tool-fs` | `:op` (member), `:path`, `:data` | Sandboxed to the root given at mount. Ops: `read`, `write`, `list`, `mkdir`, `delete`. |
| `:tool-shell` | `:cmd`, `:timeout` | Runs via `sh -c` in its own process group; merged stdout and stderr, plus the exit status. |
| `:tool-http` | `:url`, `:method` (member), `:headers` (map), `:body`, `:timeout` | Single request. Redirects are not followed and statuses pass through. |
| `:tool-eval` | `:form`, `:timeout` | Evaluates one form in a [worker](#workers) started for it and killed after it. |
| `:tool-repl` | `:id`, `:form`, `:pristine`, `:timeout` | One session per `:id`, started on first use, so state threads through successive forms. `:pristine` restarts its worker. Sessions run concurrently with each other. An id idle past the mount's `:idle` (600 s by default) is dropped. |
| `:tool-plan` | `:steps`, `:timeout` | Runs a checked sequence of declared tool calls. See [the plan gate](plan.md). |
| `:tool-image` | `:op`, `:symbol`, `:package`, `:pattern`, `:external-only`, `:limit`, `:doc-type` | Read-only introspection over the live Lisp image: `describe`, `apropos`, `documentation`, `source`, `packages`. See [introspection](introspection.md). |
| `:tool-services` | `:op`, `:kind`, `:recursive`, `:name` | Read-only introspection over the meow supervision tree: `registry`, `children`, `describe`. See [introspection](introspection.md). |
| `:tool-checkpoint` | `:op`, `:label`, `:keep`, `:path` | Save, list and roll back generations of the harness's declared state. See [checkpoints](checkpoints.md). |
| `:tool-self` | `:op`, `:form`, `:package`, `:name`, `:label`, `:limit`, `:timeout` | Evaluate, redefine and reload in the host image, each write gated by `:enable`, checkpointed and logged. See [self-modification](self.md). |
| `:tool-vault` | `:op`, `:id`, `:agent`, `:status`, `:limit`, `:max-age` | List, restore, discard and compact entries in the steering message vault. See [the vault](vault.md). |

`:timeout` is in milliseconds and defaults to 30000. `tool-fs`, `tool-image`
and `tool-services` bound no work of their own, so they declare no `:timeout`
and refuse one. Each tool's exact types are in its `:params`; see
[schemas](schema.md) for the vocabulary.

```lisp
(m:mount context 'nyaa:tool-fs :root "/srv/workspace")
(m:mount context 'nyaa:tool-shell)
(m:mount context 'nyaa:tool-http)
(m:mount context 'nyaa:tool-eval)
(m:mount context 'nyaa:tool-repl)
(m:mount context 'nyaa:tool-plan :allow '(:tool-fs))
(m:mount context 'nyaa:tool-image)
(m:mount context 'nyaa:tool-services)
(m:mount context 'nyaa:tool-checkpoint)
(m:mount context 'nyaa:tool-self :enable '(:eval :define :reload))
(m:mount context 'nyaa:tool-vault)
```

`tool-fs` refuses to delete directories, and offers no recursive delete: a tool
this easy to call should not be able to `rm -rf`.

`tool-eval` and `tool-repl` answer `(:ok (:value "<printed first value>"
:values ("<printed value>" ...) :out "<what the form printed>" :elided
<bool>))`. `:values` holds every value the form returned, printed in order
and empty for a form returning none; `:value` is `:values`'s first entry, or
`"NIL"` when there is none, kept for callers that only want the primary
value. `:elided` is true when the worker's print limits, character cap, or
value-list cap cut what came back; see [Workers](#workers) for getting past
it. Source that does not read is a
`(:bad-request ...)`, a form that signals is an `(:error detail)`, and a worker
that missed its deadline is killed: `tool-eval` starts a fresh one next call,
and a `tool-repl` id starts empty again. A session inherited through a
relaunched [image](images.md) is reported lost once, then starts empty.

Each `tool-repl` id runs on its own session, mounted under the tool's
context on first use, so each id evaluates independently of the others and
of the tool's own `:describe`. Calls on one id still run in order, since a
session's own mailbox serialises them.

An id with no eval in flight for `:idle` seconds (a `tool-repl` mount
option, 600 by default; `nil` keeps every session until the tool itself
stops) is dropped, killing its worker the same way an unmounted `tool-repl`
does. An eval still running past `:idle` keeps its session; the check is
against time since the last one finished, not time since the session
started.

`tool-http` folds a caller-supplied `Content-Type` into drakma's own argument,
so it is sent once, as asked, rather than duplicated or overridden.

`tool-http` opens its own connection and hands drakma the wrapped stream it
expects for `:stream` — drakma's own `:connection-timeout` does not bound the
whole exchange, and it cannot close a connection it opened internally.
`:timeout` bounds the connect phase too, ahead of the exchange deadline. A
deadline that lapses unblocks the worker thread wherever it stalled, by
closing the socket from another thread, so it errors out and unwinds
instead of running until the server answers.

## Workers

`tool-eval` and `tool-repl` evaluate in a worker: a separate Lisp process that
loads nothing — no Quicklisp, no meow, no nyaa — and runs a read/eval/print loop
over stdio. A crash or a hang there costs a deadline, never the host image.

Both sides read with `*read-eval*` bound to nil, and the worker evaluates in a
fresh `NYAA-WORKER` package. One exchange per line:

```lisp
(:eval "(+ 1 2)")            ; host to worker
(:ready)                     ; worker, once, at boot
(:ok ("3") "" nil)           ; every value, output, then :elided or nil
(:error "message" "")        ; the form signalled
(:reader-error "message")    ; the source did not read
```

The source travels as a string, so source that does not read costs one reply
rather than desynchronising the stream. Each value prints under
`*print-length*`, `*print-level*` and a character cap; the reply's fourth
element is `:elided` when any value was cut that way, when the form returned
more than 100 values, or when their combined printed form ran past 4000
characters (later values dropped), `nil` when everything printed in full.

No value is lost to elision on a `tool-repl` session: the worker keeps a REPL
history under `*`, `**` and `***` for the first value and `/`, `//` and `///`
for the whole list, shifted the same way the standard toplevel's are after
each successful eval (an erroring form leaves them alone). The session's
history survives across calls on that id, so an elided value can still be
inspected:

```lisp
(invoke-tool :tool-repl :id "a" :form "(make-list 500)")
;; => (:ok (:value "(NIL NIL NIL ...)" :values ("(NIL NIL NIL ...)") :out "" :elided t)
(invoke-tool :tool-repl :id "a" :form "(defparameter v *)")
(invoke-tool :tool-repl :id "a" :form "(length v)")
;; => (:ok (:value "500" :values ("500") :out "" :elided nil))
(invoke-tool :tool-repl :id "a" :form "(floor 7 2)")
;; => (:ok (:value "3" :values ("3" "1") :out "" :elided nil))
(invoke-tool :tool-repl :id "a" :form "(second /)")
;; => (:ok (:value "1" :values ("1") :out "" :elided nil))
```

`tool-eval`'s worker is killed after the call, so its history is of no use
past the reply — a caller that hits `:elided` there needs `tool-repl` to look
further at the value.

A worker runs the host's own SBCL binary. `*worker-command*` overrides the
invocation. Starting one costs about 33 ms, and an exchange with a running
one about 0.2 ms, which is why an evaluation gets a fresh process instead
of a pooled one.

A worker leads its own process group, the same as a `tool-shell` command (see
the standard tools table above), so a process a form backgrounds is killed
along with it rather than outliving the deadline. Containment picks the best
mechanism the host offers, in order: a process group set natively by the
launch itself, one set by a `perl` or `setsid` wrapper, or — with none of
those available — walking and killing the descendant process tree by hand.

## Trust posture

`tool-shell` runs any command, `tool-http` makes arbitrary network requests from
the host, `tool-eval` and `tool-repl` evaluate arbitrary forms,
`tool-checkpoint` writes and reverts the harness's own declared state,
`tool-self` evaluates, redefines and reloads in the host image, and
`tool-vault` restores a steering message into a named agent's conversation.
All seven are trusted-operator surfaces, marked `:trust :operator` at the
definition site. `tool-fs` is confined to its sandbox root: a lexical check
first, so a path outside the root is rejected before anything touches the
filesystem, then an fd-based walk from the root, opening each component with
`O_NOFOLLOW` and stepping into it — a symlink anywhere below the root is
refused outright rather than resolved, and the final component is operated on
relative to that same directory, so the check and the operation share one file
descriptor with no window between them for a swap to land in.
`tool-plan` is `:agent`-trusted, but only reaches what its own `:allow` names,
and only tools that are themselves `:agent`-trusted — see
[the plan gate](plan.md) for what that buys and what it does not.

`tool-image` and `tool-services` are `:agent`-trusted and read-only: neither
ever returns a value or a slot, only flags and shapes, so a provider's
`:api-key` (kept out of published metadata; see [providers](providers.md))
cannot surface through either. Seeing a value stays `tool-eval`, `tool-repl`
or `tool-self`'s job. See [introspection](introspection.md).

## Limitations

- `tool-plan`'s `:timeout` is checked only between steps, so one long step
  can run past it ([#43](https://todo.sr.ht/~takeiteasy/nyaa/43)).
- `tool-image` has no source location for an interpreted definition
  ([#47](https://todo.sr.ht/~takeiteasy/nyaa/47)).
- `tool-services`'s `:state` is `m:children`'s restart bookkeeping, not the
  richer lifecycle `service-status` tracks
  ([#46](https://todo.sr.ht/~takeiteasy/nyaa/46)).
- `tool-vault`'s compaction is safe within one process only
  ([#84](https://todo.sr.ht/~takeiteasy/nyaa/84)). See
  [the vault](vault.md#limitations).
