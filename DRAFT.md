# Port plan: MEOW + nyaa in Common Lisp

**Status:** planning, no code yet. Decisions below were confirmed on 2026-09-18.
Anything under "Open questions" still needs a decision before the work that
depends on it.

## 1. Goal

Rebuild the patchbay/nyaa pair in Common Lisp:

- **MEOW** (*Mount Everything, Order Whatever*): a new repo. A Cordis-style
  plugin/service core: contexts, services with mount-order-independent DI,
  a registry, effects, events, config, hot reload, and sub-agent supervision.
  It has no AI-specific code.
- **nyaa** (*Not Your Average Agent*): this repo, keeping its history. An
  Autolith-style agent harness built on MEOW, with the AI living inside the
  Lisp image.
- **patchbay** stays frozen as it is (Erlang/OTP). It serves as the reference
  semantics and test oracle for the MEOW port.

This reverses the old BEAM draft. That draft rebuilt Autolith's features
*instead of* a mutable Lisp image; now the image is the substrate. As a
result:

- Things the BEAM draft listed as out of reach become cheap: live
  introspection, redefining code and CLOS classes, and whole-image snapshots
  (SBCL only).
- Things OTP provided for free now have to be built: supervision, restart
  intensity, links/monitors, and killing a runaway computation.

## 2. Decisions

| Topic | Decision |
|---|---|
| Core name | MEOW, in a new repo `takeiteasy/meow` with origin + sr.ht mirror. GPLv3. |
| Tracker | New `~takeiteasy/meow` for the core. `~takeiteasy/nyaa` stays for the harness. |
| Implementations | SBCL and ECL are both first class. CCL is nice to have and not in CI. |
| Actor substrate | Hand-rolled on bordeaux-threads (bt2 API). No Sento. |
| Failure model | CL conditions and restarts inside a service, plus a small supervisor at the service boundary. |
| Registry | A lock-protected data structure, not a process. |
| Isolation | Hybrid. Services, tools and agents run as in-image threads. eval, scratch REPLs and shell run in separate processes. |
| Plugin API | A service is a CLOS class with generic-function callbacks, declared through a `defservice` macro. |
| Core scope | patchbay parity plus an event bus, effects (scoped disposers), config schemas and hot reload. |
| Checkpoints | Declared state everywhere; full image generations as well on SBCL. |
| Self-modification | Read-only introspection from the start. Writes are a separate tool that must be enabled explicitly and take a checkpoint first. |
| nyaa port | Clean replacement on trunk: one commit removes the LFE code and adds the CL skeleton. |
| Tests | FiveAM, run through `asdf:test-system`. |
| Dependencies | Plain Quicklisp, with vendoring where needed. Keep the dependency count small. |
| Loading MEOW | Symlinked into `~/quicklisp/local-projects`. CI clones it there. |

## 3. MEOW design

### 3.1 Layering

```
┌───────────────────────────────────────────┐
│ nyaa: agent loop, tools, adapters, UI     │  this repo
├───────────────────────────────────────────┤
│ agent supervisor (delegation)             │
│ hot reload · config · events · effects    │  MEOW
│ context · service · registry · supervisor │
├───────────────────────────────────────────┤
│ bordeaux-threads (bt2) · alexandria       │
└───────────────────────────────────────────┘
```

### 3.2 Concurrency primitives (replacing gen_server)

- **Mailbox**: a queue guarded by a lock and a condition variable. `send`
  never blocks. `receive` takes an optional timeout (`bt2:condition-wait`
  with `:timeout`). Selective receive is out of scope.
- **Service thread**: each running service owns one thread that loops over
  its mailbox. Thread pools are out of scope, which is fine at plugin scale.
  `TODO:` switch to a shared dispatcher if the service count grows into the
  hundreds.
- **call / cast**: `call` sends a request together with a one-shot reply
  cell (a promise), then waits on it with a timeout. `(call svc msg
  :timeout n)` returns `(values nil :timeout)` when the time runs out, and
  the target keeps running. This matches patchbay's `call_service/3`.
- **No thread killing.** Cancelling in-image work is always cooperative, via
  an interrupt that signals a `cancel` condition at a safe point. Work that
  needs a hard kill goes out of process (see §4.2).

### 3.3 Registry

The registry ports patchbay's semantics as they stand:

- register, unregister, lookup, and `names`.
- `subscribe` is atomic: it immediately replays an existing registration, so
  there is no lookup-then-subscribe race.
- `await` takes a timeout or `nil` (wait forever); the registry owns the
  deadline.
- Dead registrants are cleaned up. A service thread that exits unregisters
  itself through `unwind-protect`, and the supervisor unregisters on the
  thread's behalf if that doesn't happen.

The registry is **a lock-protected data structure, not a process**. Notifications are then plain mailbox sends performed while
the lock is held. patchbay needed a registry process plus ETS-backed crash
recovery (#7) only because an Erlang registry *is* a process. A structure
behind a lock cannot crash independently of its callers, so that whole
category of failure goes away.

### 3.4 Services

```lisp
(defservice consumer ()
  ((greeting :initarg :greeting :type string :initform "hi"))   ; config slots
  (:name :consumer)
  (:depends-on :provider))

(defmethod ready ((s consumer) deps) ...)          ; all deps present
(defmethod dep-down ((s consumer) name reason) ...)
(defmethod handle ((s consumer) msg) ...)          ; return value is the reply
(defmethod dispose ((s consumer) reason) ...)
```

- Every callback except `handle` has a default no-op method. This replaces
  patchbay's `function_exported` checks.
- `metadata` is a generic function that returns a plist. It is published as
  the registration props, which is how tool and model discovery keep working.
- Redefining the class updates live instances through
  `update-instance-for-redefined-class`, and hot reload builds on that.

### 3.5 Failure model

- Inside a service, errors are ordinary conditions. The service loop wraps
  `handle` in `handler-bind` and offers two restarts: `skip-message` (reply
  with an error and carry on) and `stop-service`.
- When `*debug-services*` is true, which is the development default, an
  unhandled error enters the debugger with those restarts available, so an
  error can be fixed interactively in the live image.
- Otherwise the service stops. Its disposers run, it unregisters, subscribers
  receive `dep-down`, and its supervisor applies the restart policy.
- **Supervisor**: one-for-one only. The restart type is `:permanent`,
  `:transient` (the default) or `:temporary`. Restart intensity and period
  work as in OTP (5 restarts in 10 seconds). When the limit is exceeded, the
  supervisor escalates by stopping its own context.
- A context is a supervisor plus a registry entry, as in patchbay. Nested
  contexts are just services whose class is `context`.

### 3.6 Effects, events, config, reload (new relative to patchbay)

- **Effects**: `(effect ctx acquire-fn)`. The acquire function returns a
  disposer, and the context pushes it onto a stack. Unmounting or crashing
  unwinds the stack in LIFO order. The `dispose` method is just the last
  effect on the stack.
- **Events**: `(on ctx :event fn)` registers a listener as an effect, so the
  listener is removed automatically when its context goes away. `emit` calls
  listeners in parallel, `emit-serial` calls them in order, and `bail`
  returns the first non-nil result, following Cordis.
  Open question: should listeners run on the emitter's thread or be sent as
  a message to the listener's service?
- **Config**: `defservice` config slots carry a `:type`, and an optional
  `:validate` function checks the whole config. Validation runs at mount
  time and signals `invalid-config` with every problem found.
- **Hot reload**: `(reload ctx 'consumer)` runs the disposers, then
  `reinitialize-instance` with the same config, then restarts the thread.
  Recompiling a file followed by `reload` is the whole workflow.

### 3.7 Sub-agent supervision

This ports `patchbay_agent`/`patchbay_agent_sup`:

- Sub-agents are temporary children.
- `(delegate sup class args :ref r :name n)` starts one; `:name` is optional.
- When the agent's `handle` returns `(values :done result)`, the agent sends
  `(:agent-done ref agent result)` to the parent's mailbox and stops.
- If the agent crashes, the parent receives `(:agent-down ref reason)`
  instead.

### 3.8 Test plan

Port patchbay's eunit suites into FiveAM suites that check the same
properties: `registry`, `service`, `service-recovery`, and agent delegation.
They include the regression for re-registration racing a stale down
notification. If the registry stops being a process, drop the
registry-recovery suite. CI runs every suite on SBCL and ECL.

## 4. nyaa design

### 4.1 Layering

- Tools, model adapters, the agent loop and the UI are all MEOW services
  under one root context, as they are today.
- Tool convention: a service named `:tool-<name>` whose `metadata` includes
  `:kind :tool`. It responds to `(:describe)` and `(:invoke plist)`.
- Model adapter convention: named `:model-<name>`, `:kind :model`, and
  responds to `(:complete plist)` with streaming through a sink mailbox.
- Both conventions map one-to-one from `docs/tools.md` and `docs/adapters.md`.

### 4.2 Workers (hard isolation)

- A worker is a separate Lisp process started with `uiop:launch-program`.
  By default it runs the same implementation as the host.
- Workers speak an s-expression protocol over stdio. Every `read` binds
  `*read-eval*` to nil and runs in a dedicated package.
- **Timeout**: the host kills the process and reports `:timeout`. This is
  the only real hard kill available, and it is why eval and REPL work run
  here.
- **Scratch REPL**: one persistent worker per id, so state threads through
  successive evals. `:pristine t` kills the worker and starts a new one under
  the same id. Workers start lazily on first use.
- **eval**: a single-use worker, or a pooled one that is reset after use.
  Start-up cost matters here; see Open questions.
- **shell**: runs through `uiop:launch-program` with the same kill-on-timeout
  behaviour.
- With this design, the guarantee in `docs/tools.md` stays true: a crash or
  hang costs at most the timeout and cannot take down the image.

### 4.3 AI inside the image

- **Introspection tools** are read-only and always on. They cover
  `describe`, `apropos`, `documentation`, source locations where the
  implementation provides them, the list of plugins and services, service
  state, and the registry.
- **Self-modification tools** are off by default. They cover evaluating in
  the host image, redefining functions and classes, and
  remounting/reloading plugins. Each write first takes a checkpoint (§4.4)
  and logs the change.
- The constrained DSL (#14) is still the gate before anything untrusted can
  reach either kind of eval.

### 4.4 Checkpoints and rollback (#5)

- **Declared state, on every implementation**: services implement
  `snapshot` and `restore` generic functions. A generation is an s-expression
  file containing the conversation, config, the mounted plugin set, and each
  service's snapshot.
- **SBCL image generations**: `save-lisp-and-die` refuses to run while more
  than one thread exists, and it ends the process. An image checkpoint
  therefore goes: take a declared-state snapshot, stop every service thread,
  dump the image, then relaunch it and restore from the snapshot. The running
  agent really does stop and restart. A recovery image built at install time
  is the fallback, as in Autolith.
- ECL can't dump images, so it only gets declared-state generations.

### 4.5 Vault (#4)

An append-only s-expression log of steering messages. Each entry is marked
consumed once it has been handled. It is exposed as the `vault`,
`vault-restore` and `vault-discard` tools. No change in design from the BEAM
draft.

## 5. Build order

### MEOW (tracker `~takeiteasy/meow`)

1. Repo skeleton: ASDF systems `meow` and `meow/tests`, FiveAM, CI on
   SBCL + ECL, README, and `docs/`.
2. Mailbox, service thread, and call/cast with timeouts.
3. Registry. Port the registry tests.
4. `defservice`, DI/ready/dep-down, and disposers. Port the service tests.
5. Supervisor and contexts: restart types, intensity, escalation, and the
   debugger/restart integration.
6. Sub-agent supervisor. Port the delegation tests.
7. Effects, then events, then config, then hot reload.

### nyaa (tracker `~takeiteasy/nyaa`)

1. Clean replacement on trunk: remove the LFE code and rebar, add the ASDF
   skeleton and FiveAM, and rewrite the README and docs
   for CL.
2. Tools: fs, shell, http. Port `nyaa-tool-tests` alongside them.
3. Workers, then eval and scratch REPL on top of them. Port
   `nyaa-repl-tests`, including env persistence and pristine.
4. Model adapters: Ollama, then OpenRouter (#10). Port
   `nyaa-adapter-tests` and the fake HTTP server.
5. Agent loop (#12).
6. Introspection tools, then gated self-modification tools.
7. UI convention (#11), vault (#4), checkpoints (#5), DSL (#14).

## 6. Tracker housekeeping (when the work starts)

- Rewrite the open nyaa tickets (#4, #5, #10, #11, #12, #14) for CL. Checkpoints
  (#5) is no longer "hardest, do last": the declared-state part is simple.

## 7. Open questions

- **Events**: should listeners run on the emitter's thread, or be dispatched
  to the listener service's mailbox?
- **Worker start-up**: is a cold ECL or SBCL start fast enough for one-shot
  eval, or does it need a warm pool from day one?
- **Worker implementation**: always the same as the host, or configurable
  (for example, ECL host with SBCL workers)?
- **Libraries**: which JSON library (jzon or shasht) and which HTTP client
  (dexador or drakma)? Check that each builds on ECL before picking.
- **bt2 on ECL**: before MEOW step 2, confirm that `bt2:condition-wait` with
  `:timeout` works reliably on ECL, since every `call` depends on it.
- **Package style**: one `meow` package, or `meow` plus `meow.internal`?
  Should nyaa use package-local nicknames?
