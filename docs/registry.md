# nyc-registry

The piece that lets a plugin be mounted before its dependency exists, and be
told about it when it appears -- Cordis's `inject` is demand-driven, and OTP
has no built-in primitive for that. `nyc-registry` is it.

## Why hand-rolled instead of gproc

`nyc-registry` is a single hand-rolled `gen_server`, not a pull of `gproc`
from Hex. `apps/nyc` has zero non-OTP dependencies, which fits this
project's BEAM-native thesis, and the registry's needs are small enough
(name → pid, plus a subscribe/notify channel) that a purpose-built ~250-line
module is easier to reason about than adopting a general-purpose process
registry. Everything reaches the registry only through the client API in
`nyc-registry.lfe` (`register`, `unregister`, `lookup`, `await`, `subscribe`,
`unsubscribe`, `names`), so a `gproc`-backed implementation could be swapped
in behind that API later without touching callers.

Single-node only, by design -- nothing here needs to work across BEAM nodes.

## API

| Call | Returns |
|---|---|
| `(register name pid props)` | `ok` \| `#(error #(already-registered Pid))` |
| `(unregister name)` | `ok` |
| `(lookup name)` | `#(ok #(Pid Props))` \| `#(error not-found)` |
| `(await name timeout)` | `#(ok Pid)` \| `#(error timeout)` -- blocks; returns immediately if already present |
| `(subscribe name)` | `ok` -- caller gets async notifications, **including an immediate one if `name` is already registered** |
| `(unsubscribe name)` | `ok` |
| `(names)` | list of every currently registered name |

Notification messages sent to subscribers:

```
#(nyc-registry registered   Name Pid)
#(nyc-registry unregistered Name Reason)
```

## The two things that make this correct under concurrency

**`subscribe` replays an existing registration immediately.** If `Name` is
already registered at the moment of subscribing, the subscriber gets a
`registered` message right away, before `subscribe` returns. This removes
the lookup-then-subscribe race by construction: a caller that subscribes
never needs to call `lookup` first, and there's no gap between "check if it
exists" and "start listening for it to appear" for a registration to fall
into. `nyc-service` relies on this -- see `docs/plugins.md`.

**`await` owns its own timeout, server-side.** The obvious implementation
(let the caller's `gen_server:call` timeout do the work) leaks: if the
caller gives up and the name never registers, the server never finds out
and the waiting entry sits in `waiters` forever; if the name registers much
later, the server tries to reply to a caller that's no longer listening.
Instead, `await` starts its own timer via `erlang:start_timer/3`, replies
`#(error timeout)` and cleans up when it fires, and monitors the calling
process so a caller that dies mid-wait is reaped too. Client calls use
`infinity` as the `gen_server:call` timeout -- the server-side timer is what
actually bounds the wait.

## A note on debugging this kind of code

Two of the bugs this module has already had were LFE surface-syntax traps,
not logic errors, and are worth knowing about if you're extending this file:

- An uppercase-led bareword in a pattern (like `DOWN` in a `{'DOWN', ...}`
  monitor message) is read as a *pattern variable*, not a literal atom match
  -- and quoting it (`'DOWN`) doesn't fix it either. Bind it to a lowercase
  variable and guard on it with `(when (=:= tag 'DOWN))` instead.
- `,x` (unquote) only means anything inside a backquote. A map literal like
  `#m(key ,value)` without a leading backtick reads `,value` literally as
  the two-element list `(comma value)`, not the value of the variable --
  silently, with no compile error. Write `` `#m(key ,value)` `` instead.
