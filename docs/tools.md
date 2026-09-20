# Tools

A tool is a [meow](https://github.com/takeiteasy/meow) service that follows one
extra convention, so any caller — including the agent loop — can discover,
describe and invoke every tool the same way.

## The convention

A tool registers under `:tool-<name>`, and its `metadata` plist carries
`:kind :tool`, a `:summary` and its `:params`:

```lisp
(m:defservice tool-shell () ()
  (:name :tool-shell))

(defmethod m:metadata ((service tool-shell))
  (list :kind :tool
        :name :tool-shell
        :summary "Run a shell command (sh -c) and capture merged output"
        :params '(:cmd "command string to run"
                  :timeout "kill the command after this many milliseconds")))
```

Use an explicit keyword for the name. `defservice` otherwise defaults to the
class symbol, and names compare with `equal`, so `foo::tool-shell` and
`bar::tool-shell` would be different tools.

It answers two messages, through `define-tool-handler`:

- `(:describe)` — replies with the metadata plist
- `(:invoke . plist)` — performs the operation

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
| `(:bad-request msg)` | The invoke arguments are malformed. |
| `:timeout` | The deadline lapsed. |
| `:unavailable` | The far end could not be reached. |
| `(:error detail)` | Anything else. |
| `(:forbidden msg)` | `tool-fs` only: the path escapes the sandbox. |

`tool-error-p` and `tool-error` take a result apart.

## Discovery

`(tools)` scans registration props for `:kind :tool`. Props are a snapshot taken
at registration — there is no setter — so a tool's advertised `:params` change
only when it is reloaded.

```lisp
(nyaa:tools)  ; => (:tool-fs :tool-http :tool-shell)
```

## Invocation

```lisp
(nyaa:describe-tool :tool-shell)
(nyaa:invoke-tool :tool-shell :cmd "ls -la")
```

`invoke-tool` waits longer than the tool's own `:timeout`, so the tool's bounded
`(:error :timeout)` is what a caller sees. Calling a tool with a bare `m:call`
instead would abort the *caller* after meow's 5-second default while the tool
kept running.

## The standard tools

| Tool | Parameters | Notes |
|---|---|---|
| `:tool-fs` | `:op`, `:path`, `:data` | Sandboxed to the root given at mount. Ops: `read`, `write`, `list`, `mkdir`, `delete`. |
| `:tool-shell` | `:cmd`, `:timeout` | Runs via `sh -c`; merged stdout and stderr, plus the exit status. |
| `:tool-http` | `:url`, `:method`, `:headers`, `:body`, `:timeout` | Single request. Redirects are not followed and statuses pass through. |

`:timeout` is in milliseconds and defaults to 30000.

```lisp
(m:mount context 'nyaa:tool-fs :root "/srv/workspace")
(m:mount context 'nyaa:tool-shell)
(m:mount context 'nyaa:tool-http)
```

`tool-fs` refuses to delete directories, and offers no recursive delete: a tool
this easy to call should not be able to `rm -rf`.

`tool-http` folds a caller-supplied `Content-Type` into drakma's own argument,
so it is sent once, as asked, rather than duplicated or overridden.

## Trust posture

`tool-shell` runs any command and `tool-http` makes arbitrary network requests
from the host. Both are trusted-operator surfaces. `tool-fs` is confined to its
sandbox root, subject to the limitation below.

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
