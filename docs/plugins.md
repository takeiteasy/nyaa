# Writing a plugin

A plugin is a callback module wrapped by `nyc-service`, mounted onto a
`nyc-context`. `nyc-service` is itself a `gen_server` that holds your
callback module and its state, and handles registry registration and
dependency-waiting once so individual plugins don't reimplement it.

## The callback contract

```
(service-name)                -> atom                            [required]
(dependencies)                -> (list-of atom)                  [required]
(init Args)                   -> #(ok State)                     [required]
(ready Deps State)            -> #(ok State)                     [optional]
(dep-down Name Reason State)  -> #(ok State)                     [optional]
(handle-message Msg State)    -> #(ok State) | #(reply R State)  [optional]
(terminate Reason State)      -> ok                              [optional]
```

Optional callbacks default to no-ops, checked with
`erlang:function_exported/3` -- a trivial plugin with no dependencies only
needs to write `service-name`, `dependencies` (returning `()`), and `init`.

`Deps` (passed to `ready/2`) is a map from dependency name to that
dependency's current pid.

## Dependency waiting, and why it never blocks

`nyc-service`'s `init/1` subscribes to every name in `(dependencies)` and
does **not** call `lookup` first. `nyc-registry:subscribe` replays an
existing registration immediately if the dependency is already there (see
`docs/registry.md`), so this is race-free by construction regardless of
whether the plugin is mounted before or after its dependencies -- and it
never blocks the supervisor start, since subscribing is async.

When every declared dependency has registered, the service transitions to
`ready` and your `ready/2` runs. If a dependency's registration disappears
(the process died, or it was explicitly unregistered) after the service was
ready, it transitions back to `waiting` and your `dep-down/3` runs. If the
dependency reappears, `ready/2` runs again with the new pid.

## The disposer

Your `terminate/2` is `ctx.effect()`'s release half: whatever you acquired
in `init/1`, release it here. It runs before `nyc-service` unregisters the
plugin from the registry, so if you need to notify anyone as your last act
before going away, do it here.

This depends on the service process trapping exits (`nyc-service`'s `init/1`
calls `process_flag(trap_exit, true)` for exactly this reason) -- a plain
`gen_server` that doesn't trap exits is killed outright by a supervisor's
ordinary shutdown, and `terminate/2` never runs at all.

## The child spec

Plugins provide their own `child_spec/1` (or however many arguments your
`init/1` needs) rather than relying on a shared helper, since the shape is
small and explicit is clearer than another layer of indirection:

```lfe
(defun child_spec (reporter)
  `#m(id demo-provider
      start #(nyc-service start_link (nyaa-demo-provider ,reporter))
      restart transient
      shutdown 5000
      type worker
      modules (nyc-service)))
```

`restart transient` is the recommended default (restart only on abnormal
exit) -- override per plugin if you need `permanent` or `temporary`. Mount
it with `(nyc-context:mount ctx (your-module:child_spec Args))`.

## Talking to a running plugin

`(nyc-service:call-service name msg)` and `(nyc-service:cast name msg)` look
the plugin up by name in the registry and forward to its `handle-message/2`.
There's no general topic-based event bus yet -- the registry's
subscribe/notify already covers what the demo plugin needs, and a real bus
is better designed once there's a second consumer for it.

## Worked example

See `apps/nyaa/src/demo/nyaa-demo-provider.lfe` and
`nyaa-demo-consumer.lfe` -- a dependency-free provider and a consumer that
declares the provider as a dependency, used by the test suite in
`apps/nyaa/test/nyaa-demo-tests.lfe` to prove mount-order independence,
dependency-down/re-ready transitions, and disposer firing on unmount.
