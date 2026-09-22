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
    (run-command cmd timeout)))
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
through to the generated class, as `tool-fs`'s sandbox root does; the
anaphoric `service` is bound inside `:invoke` for a tool that needs it.

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
| `:unavailable` | The far end could not be reached. |
| `(:error detail)` | Anything else. |
| `(:forbidden msg)` | `tool-fs` only: the path escapes the sandbox. |

`tool-error-p` and `tool-error` take a result apart.

## Discovery

`(tools)` scans registration props for `:kind :tool`. Props are a snapshot taken
at registration — there is no setter — so a tool's advertised `:params` change
only when it is reloaded. `invoke-tool` reads the schema from there, which costs
no message to the tool.

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

## The standard tools

| Tool | Parameters | Notes |
|---|---|---|
| `:tool-fs` | `:op` (member), `:path`, `:data` | Sandboxed to the root given at mount. Ops: `read`, `write`, `list`, `mkdir`, `delete`. |
| `:tool-shell` | `:cmd`, `:timeout` | Runs via `sh -c`; merged stdout and stderr, plus the exit status. |
| `:tool-http` | `:url`, `:method` (member), `:headers` (map), `:body`, `:timeout` | Single request. Redirects are not followed and statuses pass through. |
| `:tool-eval` | `:form`, `:timeout` | Evaluates one form in a [worker](#workers) started for it and killed after it. |
| `:tool-repl` | `:id`, `:form`, `:pristine`, `:timeout` | One worker per `:id`, started on first use, so state threads through successive forms. `:pristine` restarts it. |
| `:tool-plan` | `:steps`, `:timeout` | Runs a checked sequence of declared tool calls. See [the plan gate](plan.md). |
| `:tool-image` | `:op`, `:symbol`, `:package`, `:pattern`, `:external-only`, `:limit`, `:doc-type` | Read-only introspection over the live Lisp image: `describe`, `apropos`, `documentation`, `source`, `packages`. See [introspection](introspection.md). |
| `:tool-services` | `:op`, `:kind`, `:recursive`, `:name` | Read-only introspection over the meow supervision tree: `registry`, `children`, `describe`. See [introspection](introspection.md). |

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
```

`tool-fs` refuses to delete directories, and offers no recursive delete: a tool
this easy to call should not be able to `rm -rf`.

`tool-eval` and `tool-repl` answer `(:ok (:value "<printed value>" :out
"<what the form printed>"))`. Source that does not read is a
`(:bad-request ...)`, a form that signals is an `(:error detail)`, and a worker
that missed its deadline is killed: `tool-eval` starts a fresh one next call,
and a `tool-repl` id starts empty again.

`tool-http` folds a caller-supplied `Content-Type` into drakma's own argument,
so it is sent once, as asked, rather than duplicated or overridden.

## Workers

`tool-eval` and `tool-repl` evaluate in a worker: a separate Lisp process that
loads nothing — no Quicklisp, no meow, no nyaa — and runs a read/eval/print loop
over stdio. A crash or a hang there costs a deadline, never the host image.

Both sides read with `*read-eval*` bound to nil, and the worker evaluates in a
fresh `NYAA-WORKER` package. One exchange per line:

```lisp
(:eval "(+ 1 2)")            ; host to worker
(:ready)                     ; worker, once, at boot
(:ok "3" "")                 ; value, then anything the form printed
(:error "message" "")        ; the form signalled
(:reader-error "message")    ; the source did not read
```

The source travels as a string, so source that does not read costs one reply
rather than desynchronising the stream. Values print under `*print-length*`,
`*print-level*` and a character cap.

A worker runs the host implementation, resolved from the running binary.
`*worker-command*` overrides the invocation. Starting one costs about 33 ms on
SBCL and 41 ms on ECL, and an exchange with a running one about 0.2 ms, which is
why an evaluation gets a fresh process instead of a pooled one.

## Trust posture

`tool-shell` runs any command, `tool-http` makes arbitrary network requests from
the host, and `tool-eval` and `tool-repl` evaluate arbitrary forms. All four are
trusted-operator surfaces, marked `:trust :operator` at the definition site.
`tool-fs` is confined to its sandbox root, subject to the limitation below.
`tool-plan` is `:agent`-trusted, but only reaches what its own `:allow` names,
and only tools that are themselves `:agent`-trusted — see
[the plan gate](plan.md) for what that buys and what it does not.

`tool-image` and `tool-services` are `:agent`-trusted and read-only: neither
ever returns a value or a slot, only flags and shapes, so a provider's
`:api-key` (kept out of published metadata; see [providers](providers.md))
cannot surface through either. Seeing a value stays `tool-eval`'s job. See
[introspection](introspection.md).

## Limitations

- The `tool-fs` sandbox is path-based. Paths are confined lexically, without
  touching the filesystem, which is what makes the check sound against `../`
  tricks — but a symlink inside the root pointing outside it is followed
  ([#15](https://todo.sr.ht/~takeiteasy/nyaa/15)).
- `tool-shell`'s deadline signals the `sh` child only, so a backgrounded
  descendant outlives it ([#16](https://todo.sr.ht/~takeiteasy/nyaa/16)).
- A `tool-http` request abandoned at its deadline leaves its worker thread
  running until the server answers
  ([#17](https://todo.sr.ht/~takeiteasy/nyaa/17)).
- A worker's deadline kills the worker itself, so a process it backgrounded
  outlives it, as with `tool-shell`
  ([#16](https://todo.sr.ht/~takeiteasy/nyaa/16)).
- A value too large to print is truncated silently, and the caller cannot ask
  for the rest ([#26](https://todo.sr.ht/~takeiteasy/nyaa/26)).
- `tool-repl` handles one message at a time, so its sessions are isolated but
  not concurrent ([#27](https://todo.sr.ht/~takeiteasy/nyaa/27)).
- `tool-plan`'s `:timeout` is checked only between steps, so one long step
  can run past it ([#43](https://todo.sr.ht/~takeiteasy/nyaa/43)).
- `tool-image` has no source location for an interpreted definition on SBCL,
  or anything not loaded from a compiled file on ECL
  ([#47](https://todo.sr.ht/~takeiteasy/nyaa/47)).
- `tool-services`'s `:state` is `m:children`'s restart bookkeeping, not the
  richer lifecycle `service-status` tracks
  ([#46](https://todo.sr.ht/~takeiteasy/nyaa/46)).
