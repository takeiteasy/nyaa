# Getting started

## Toolchain

- Erlang/OTP (developed against OTP 29 / ERTS 17.0.5)
- [rebar3](https://rebar3.org/)

Everything else (`lfe`, `rebar3_lfe`, `ltest`) is pulled from Hex by
`rebar.config`; no global LFE install is required.

## Build

```sh
rebar3 compile
```

This builds both umbrella apps: `apps/nyc` (the core runtime) and
`apps/nyaa` (the harness).

## Test

```sh
rebar3 as test ltest
```

Runs every test module across both apps. `rebar3 as test lfe ltest --suite
<name>` is documented by the plugin but does not actually filter to a
single suite as of `rebar3_lfe` 0.5.8/`ltest` 0.13.11 -- it still runs
every discovered module; don't rely on it for isolating one suite's output.

Note for anyone adding a test file: `ltest` discovers test suites by
scanning compiled beams for the `ltest-unit` behaviour tag, not by the
presence of `deftest` forms alone -- a test module needs
`(behaviour ltest-unit)` in its `defmodule` or `ltest` will silently report
"no unit tests found" for it.

## Run the demo interactively

```sh
rebar3 shell
```

Then, from the shell:

```erlang
application:ensure_all_started(nyaa).
{ok, {Ctx, _}} = 'nyc-registry':lookup('nyaa-root').
Reporter = self().
'nyc-context':mount(Ctx, 'nyaa-demo-consumer':child_spec(Reporter)).
%% flush() to see {consumer, waiting} -- mounted before its dependency exists
'nyc-context':mount(Ctx, 'nyaa-demo-provider':child_spec(Reporter)).
%% flush() again to see {consumer, ready, Pid} and {provider, ready}
'nyc-registry':names().
```

Kill the provider and watch the consumer react:

```erlang
{ok, {ProvPid, _}} = 'nyc-registry':lookup('demo-provider').
exit(ProvPid, kill).
%% flush() -- {consumer, dep-down, 'demo-provider', killed}, then
%% {consumer, ready, NewPid} once the supervisor restarts it
```

This is the property the whole core exists to prove: a plugin mounted
before its dependency exists doesn't crash, doesn't block, and becomes
ready on its own once the dependency appears. See `docs/registry.md` for
how that's implemented and `docs/plugins.md` for how to write your own
plugin.
