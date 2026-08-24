# Sub-agent delegation

A sub-agent is a callback module wrapped by `nyc-agent`, started on demand
under an `nyc-agent-sup` -- a dynamic supervisor with one child per delegated
sub-agent. It's the same optional-callback wrapping style as `nyc-service`
(see `docs/plugins.md`), minus the dependency-injection machinery: a
sub-agent is an ephemeral task, not a discoverable, long-lived service.

## The callback contract

```
(init Args)                 -> #(ok State)                          [required]
(handle-message Msg State)  -> #(ok State) | #(reply R State)
                             | #(done Result State)                 [optional]
(terminate Reason State)    -> ok                                   [optional]
```

Optional callbacks default to no-ops, checked with
`erlang:function_exported/3` -- a trivial sub-agent only needs to write
`init`.

## Starting and stopping

```lfe
(nyc-agent-sup:delegate sup mod cbargs ref opts)  ; -> #(ok Pid MonRef) | #(error Reason)
(nyc-agent-sup:stop sup pid)                      ; -> ok | #(error Reason)
```

`delegate/5` runs in the calling (parent) process and monitors the new
sub-agent before returning, so `Pid`'s crash is visible as an ordinary
`DOWN` message with nothing extra to remember -- the free half of crash
isolation. Children are started `temporary`: a crash is never restarted and
never takes the `nyc-agent-sup` down.

`stop/2` calls `supervisor:terminate_child/2`, which blocks until the child
is actually down and -- since `nyc-agent` traps exits -- runs the callback's
`terminate/2` (its disposer) before returning.

## Talking to a running sub-agent

```lfe
(nyc-agent:prompt pid msg)       ; fire-and-forget, gen_server:cast
(nyc-agent:prompt-wait pid msg)  ; blocking, gen_server:call
```

Both dispatch to `handle-message/2`, but the paths shape the return
differently:

- On **`prompt-wait`** (call), `#(reply R State2)` replies `R`; `#(ok State2)`
  replies `ok`.
- On **`prompt`** (cast), `#(reply R State2)` is dropped -- there is no
  caller to reply to. A sub-agent that wants to talk back mid-cast sends a
  message itself (e.g. to whatever pid it was given in `cbargs`).

## Deciding you're done

Returning `#(done Result State2)` from `handle-message/2`, on either path,
is how a sub-agent decides it is finished. `nyc-agent` sends the tagged
message

```
#(nyc-agent done Ref Pid Result)
```

to its parent and stops normally (`prompt-wait` also gets an immediate `ok`
reply before the process exits). `Ref` is whatever `delegate/5` was called
with, so a parent running several concurrent delegations can tell them
apart in its own message loop.

## Registration is opt-in

By default a delegated sub-agent is not registered in `nyc-registry` at
all -- it's addressed purely by the `Pid` `delegate/5` returns. Pass a
`name` in `opts` (`#m(name my-agent)`) to register it under that name for
its lifetime; a duplicate name fails the start (the registry's
`already-registered` error becomes the sub-agent's stop reason) rather than
silently colliding with a sibling. Registration, if any, is dropped in
`terminate/2` after the callback's own disposer runs -- the same ordering
`nyc-service` uses, so a dying sub-agent can still notify anyone as its last
act.

## Worked example

See `apps/nyc/test/nyc-test-echo-agent.lfe`, `nyc-test-crash-agent.lfe` and
`nyc-test-silent-agent.lfe`, exercised by `apps/nyc/test/nyc-agent-tests.lfe`
-- covering the cast/call prompt split, the done protocol on both paths,
crash isolation via the monitor, opt-in registration (including the
duplicate-name failure and two concurrently-named sub-agents of the same
module), and the optional-callback default for `handle-message/2`.
