# The plan gate

`tool-plan` (~takeiteasy/nyaa#6) is the DSL gate for *untrusted* input: a
language of tool calls, so untrusted input may only express a composition of
declared tools with typed arguments, never a form. There is no `eval` and no
host-side reader; the audit surface is the interpreter plus each named
tool's own schema.

This gates *what a plan may call*, not arbitrary evaluation. `tool-eval` and
`tool-repl` stay `:trust :operator`, untouched — a model reaches them only if
an operator explicitly grants them, exactly as before. The other shape the
gate could have taken, an allowlist over raw Lisp reaching `tool-eval`
itself, is a separate, harder problem
([#44](https://todo.sr.ht/~takeiteasy/nyaa/44)).

This gate is for untrusted input. The operator's own code — an
[orchestrator definition](agent.md), a [config file](getting-started.md), or
a tool defined with [`define-tool`](tools.md) — is not gated, and the two
should not be confused.

## A plan

```lisp
(:steps ((:as "readme" :tool "tool-fs" :args (:op :read :path "README.md"))
         (:tool "tool-fs" :args (:op :write :path "copy.md"
                                :data (:ref "readme.data")))))
```

Each step names a `:tool` and its `:args`, a plist for that tool's own
schema. `:as`, if given, binds the step's result plist under a name; a later
step's `:args` may reach into it with `(:ref "name.key")`, substituted
before that step runs — `"readme.data"` is `(getf <readme's result> :data)`.

## The allow-list

`tool-plan` is mounted with `:allow`, the tool names it may call:

```lisp
(m:mount context 'nyaa:tool-plan :allow '(:tool-fs))
```

A step's `:tool` must be in `:allow` *and* that tool's own `:trust` must be
`:agent` — an `:allow` naming an operator-trusted tool is refused, so the
gate cannot be used to re-export `tool-shell`. `tool-plan` is never itself
reachable from a plan, so plans do not nest.

## Checked before any step runs

The whole plan is validated before anything executes:

- every `:tool` is registered, in `:allow`, and `:agent`-trusted
- every `:as` is unique
- every `:ref` names a step declared earlier in the same plan

A problem here is a `(:bad-request ...)` and nothing has run. Argument
coercion for a step happens only when that step runs, since a `:ref`'s value
is not known ahead of time.

## Results

```lisp
(:ok (:results (:readme (:data "...")) :steps 2))
```

`:results` holds the result plist of every named (`:as`) step. A step that
errors ends the plan:

```lisp
(:error (:step 2 :tool "tool-fs" :reason (:bad-request "...") :results (...)))
```

with the results of every step that ran before it.

## Timeout

`:timeout` bounds the whole plan, each step included. A step's own
`:timeout`, if its tool declares one, is clamped to the time left. When the
time lapses the wait on the step ends and the step's cancel token is
cancelled:

```lisp
(:error (:step 1 :tool "tool-slow" :reason :timeout :results (...)))
```

A step also stops when the plan's own `:cancel` token is cancelled.

## Limitations

- A tool that honours neither its `:timeout` nor its cancel token keeps
  running after the plan returns
  ([#145](https://todo.sr.ht/~takeiteasy/nyaa/145)).
- A step cannot pass a literal `(:ref "...")` value as an argument — `:args`
  has no way to say "this is not a reference"
  ([#45](https://todo.sr.ht/~takeiteasy/nyaa/45)).
