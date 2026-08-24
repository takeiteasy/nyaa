# Architecture

`nyaa` is a Cordis-inspired plugin/service runtime, built in LFE on OTP. The
core idea: reproduce Cordis's user-facing capabilities (context/service
composition, dependency injection that doesn't care about mount order, a
disposer on teardown) using BEAM-native primitives -- supervision trees,
message passing, and hot code loading -- rather than a mutable Lisp image.

## Layering

```
┌─────────────────────────────────────┐
│  Agent loop (top-level plugin)       │   -- not yet built
├─────────────────────────────────────┤
│  Tool / skill plugins                │   -- not yet built
│  (shell, fs, http, lisp-eval, ...)   │
├─────────────────────────────────────┤
│  Sub-agent supervisor                │   apps/nyc (nyc-agent, nyc-agent-sup)
├─────────────────────────────────────┤
│  nyc: context, service, registry     │   -- apps/nyc
├─────────────────────────────────────┤
│  OTP (supervisor, gen_server, code)  │
└─────────────────────────────────────┘
```

`apps/nyc` is the core runtime and has zero non-OTP dependencies. `apps/nyaa`
is the harness built on top of it; today that's just the demo plugin pair
under `apps/nyaa/src/demo/` that exercises the core.

## Cordis → OTP mapping

| Cordis concept | OTP realization | Where |
|---|---|---|
| `Context` | a supervisor, one per composition boundary | `nyc-context` |
| `Service` | a gen_server wrapping a callback module | `nyc-service` |
| plugin mount | `supervisor:start_child/2` | `nyc-context:mount/2` |
| plugin unmount | `supervisor:terminate_child/2` + the callback's `terminate/2` | `nyc-context:unmount/2` |
| `ctx.effect()` | resource acquired in the callback's `init/1`, released in its `terminate/2` | see `docs/plugins.md` |
| `inject` (DI) | subscribe to the registry; replay-on-subscribe makes mount order irrelevant | `nyc-registry` |
| context tree | nested supervisors -- a sub-supervisor started via `mount` *is* a child context | `nyc-context` |

Service discovery (Cordis's `inject`, which lets a plugin mount before its
dependency exists) was the key open design question for this runtime -- OTP
has no built-in "wait for a named service" primitive. It's resolved by
`nyc-registry`: see `docs/registry.md`.

## What's built vs. deferred

Built: `nyc-context`, `nyc-service`, `nyc-registry`, a demo plugin pair
proving a consumer can mount before its provider, react to the provider
dying and restarting, and have its disposer fire correctly on unmount, and
sub-agent delegation (`nyc-agent`, `nyc-agent-sup` -- see `docs/delegation.md`):
a dynamic supervisor that starts and stops one process per delegated
sub-agent on demand, with crash isolation and a tagged done-message protocol
for a sub-agent to report back to its parent.

Deferred (tracked on the project's sr.ht tracker, in this order): ephemeral
scratch REPLs, the tool/skill plugin convention, the vault (durable steering
messages), checkpoint/rollback, and a decision on how much of the "prompt is
a REPL" surface should be raw LFE forms vs. a constrained DSL -- full form
evaluation is arbitrary code execution with agent privileges, so that's a
security decision to make deliberately.
