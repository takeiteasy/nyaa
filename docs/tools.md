# Tool & skill plugins

Tool plugins are standard `patchbay_service` callback modules (see
patchbay's `docs/plugins.md` for the base contract) that follow one
additional convention so callers -- including the future agent loop --
can discover, describe, and invoke every tool uniformly.

The reference implementations live in `src/tools/`:
`nyaa-tool-shell.lfe`, `nyaa-tool-fs.lfe`, and `nyaa-tool-eval.lfe`.

## The convention

A tool plugin:

1. **Registers under `'tool-<name>`** (e.g. `'tool-shell`) with no
   dependencies, so mounting order never matters.
2. **Implements `metadata/0`** returning a map of the shape

   ```lfe
   #m(kind tool
      name 'tool-shell
      summary "one-line description"
      params #m(param-name "description" ...))
   ```

   `patchbay_service` publishes this as the registration props, which is
   what makes discovery possible without any special registry API.
3. **Answers two messages** via `handle_message/2`:

   - `describe` -- replies with the same metadata map
   - `` `(invoke ,req) `` -- performs the operation; `req` is a map of
     parameter name to value; replies with a plain result or an error
     tuple (`#(error reason)`)

### Discovery

Scan registrations for `kind == tool`:

```lfe
(lists:filtermap
  (lambda (name)
    (case (patchbay_registry:lookup name)
      (`#(ok #(,_pid ,props))
       (=:= '#(ok tool) (maps:find 'kind props)))
      (_ 'false)))
  (patchbay_registry:names()))
```

### Invocation

```lfe
(patchbay_service:call_service 'tool-shell
                               '#(invoke #(cmd "ls -la"))
                               30000)
```

Use the timeout variant for tools whose work can run long -- gen_server's
5s default will otherwise abort the *caller* while the tool keeps running.
Tools that accept a `timeout` parameter bound their own work as well, so
a hung command or looping form returns `#(error timeout)` instead of
wedging the tool service.

## The standard tools

| Tool | Service name | Parameters | Notes |
|------|--------------|------------|-------|
| shell | `tool-shell` | `cmd`, `timeout?` (default 30s) | runs via `sh -c`; merged stdout+stderr and exit status |
| fs | `tool-fs` | `op`, `path`, `data?` | sandboxed to the root dir given at mount time; ops: `read`, `write`, `list`, `mkdir`, `delete` |
| eval | `tool-eval` | `form`, `timeout?` (default 5s) | evaluates an LFE form; **trusted operator only** |

Each form/command runs bounded by its timeout: the shell tool closes the
port on expiry, and the eval tool runs every form in a throwaway process,
so a crashing or looping form costs at most its timeout and never takes
down (or wedges) the tool itself.

## Trust posture

These tools are arbitrary-execution surfaces: `tool-shell` runs any
command, `tool-eval` any form, `tool-fs` reads/writes anything inside its
sandbox (path-based only -- a symlink inside the sandbox pointing out of
it is followed). They are appropriate for nyaa's current single-operator,
trusted-plugin posture; do not wire untrusted input to them until the
constrained DSL lands (#14). See "Security & trust" in
docs/getting-started.md.

## Adding a new tool

Write a callback module per the convention above, mount it on the root
context like any plugin, and cover it in `test/nyaa-tool-tests.lfe`
(discovery, describe, invoke round-trip, plus whatever abuse-safety
property it promises). An HTTP client tool is a natural next candidate;
it was deferred from the initial set pending a dependency decision.
