# Getting started

This repo is the **nyaa harness**. The runtime core it builds on lives in
its own repo: [patchbay](https://github.com/takeiteasy/patchbay) -- see
that repo's docs for architecture, the registry design, the plugin
contract, and sub-agent delegation.

## Toolchain

- Erlang/OTP (developed against OTP 29 / ERTS 17.0.5)
- [rebar3](https://rebar3.org/)

Everything else (`patchbay`, `lfe`, `rebar3_lfe`, `ltest`) is pulled by
`rebar.config`; no global LFE install is required.

## Build

```sh
rebar3 compile
```

Fetches patchbay from GitHub (`trunk` branch) plus the LFE toolchain, and
compiles the harness.

## Test

```sh
rebar3 as test ltest
```

Runs every test module: `nyaa-demo-tests` (mount-order independence,
dependency-down/re-ready, disposer firing, registry-crash self-healing),
`nyaa-tool-tests` (tool convention: discovery, describe/invoke, sandbox
and timeout enforcement), `nyaa-repl-tests` (scratch REPLs: lifecycle,
cross-eval state, pristine resets, crash/timeout resilience), and
`patchbay-agent-tests` (delegation, crash isolation, tagged done
protocol). patchbay's own test suite lives in its own repo.

Note for anyone adding a test file: `ltest` discovers test suites by
scanning compiled beams for the `ltest-unit` behaviour tag, not by the
presence of `deftest` forms alone -- a test module needs
`(behaviour ltest-unit)` in its `defmodule` or `ltest` will silently report
"no unit tests found" for it.

Note for cold checkouts: if `rebar3 as test ltest` fails with
`lfe_comp not found` while compiling ltest's own sources, run plain
`rebar3 compile` once first to warm the default profile, then retry.

## Run the demo interactively

```sh
rebar3 shell
```

Then, from the shell:

```erlang
application:ensure_all_started(nyaa).
{ok, {Ctx, _}} = patchbay_registry:lookup('nyaa-root').
Reporter = self().
patchbay_context:mount(Ctx, 'nyaa-demo-consumer':child_spec(Reporter)).
%% flush() to see {consumer, waiting} -- mounted before its dependency exists
patchbay_context:mount(Ctx, 'nyaa-demo-provider':child_spec(Reporter)).
%% flush() again to see {consumer, ready, Pid} and {provider, ready}
patchbay_registry:names().
```

Kill the provider and watch the consumer react:

```erlang
{ok, {ProvPid, _}} = patchbay_registry:lookup('demo-provider').
exit(ProvPid, kill).
%% flush() -- {consumer, dep-down, 'demo-provider', killed}, then
%% {consumer, ready, NewPid} once the supervisor restarts it
```

This is the property the whole stack exists to prove: a plugin mounted
before its dependency exists doesn't crash, doesn't block, and becomes
ready on its own once the dependency appears.

## Play with a scratch REPL

REPLs are created lazily on first eval and keep their env across evals
(see docs/tools.md, "Scratch REPLs"):

```erlang
'nyaa-repl':eval(scratch, '(set answer 42)).
'nyaa-repl':eval(scratch, '(* answer 2)').   %% => {ok,84}
%% pristine: same id, fresh empty REPL
'nyaa-repl':eval(scratch, 'answer', #{pristine => true}).
```

(The Erlang shell needs the quoted module atom `'nyaa-repl'` -- the
module name contains a hyphen.)

## Security & trust

The planned prompt-as-REPL surface evaluates **raw LFE forms**. That is a
deliberate decision, not an oversight: a form evaluator is arbitrary code
execution with whatever privileges the runtime holds -- full access to the
node, its filesystem, and every registered service. Until a constrained
DSL exists (opt-in, capability-scoped, evaluated without `eval` on raw
forms), do not point the prompt surface at untrusted input: no network
listeners feeding it, no multi-user exposure, no third-party plugins that
forward outside content into it. The constrained DSL is tracked as future
work; raw evaluation is the bootstrap posture for a single-operator,
trusted-plugin runtime.

The standard tool plugins (`tool-shell`, `tool-fs`, `tool-eval`,
`tool-repl` -- see docs/tools.md) are the same surface in plugin form
and inherit this posture: trusted operator only.

## Tool plugins

The tool/skill convention and its reference implementations (shell, fs,
eval) are documented in [docs/tools.md](tools.md).
