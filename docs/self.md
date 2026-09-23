# Self-modification

`tool-self` is the one place nyaa can change its own running image: evaluate
a form in the host, redefine a function or class, or reload a mounted
child. Everything else -- `tool-eval`, `tool-repl`, a worker -- runs in a
throwaway process that loads nothing and shares no state with the harness.
See [~takeiteasy/nyaa#12](https://todo.sr.ht/~takeiteasy/nyaa/12).

```lisp
(m:mount *ctx* 'nyaa:tool-self :enable '(:eval :define :reload))
(nyaa:invoke-tool :tool-self :op :eval :form "(+ 1 2)")
;; => (:ok (:value "3" :out ""))
```

## `:enable`

Each write op -- `:eval`, `:define`, `:reload` -- is refused unless it is
named in `:enable`, a mount option that defaults to nil. `:log` always
answers, since it only reads back what a write already did.

```lisp
(nyaa:invoke-tool :tool-self :op :eval :form "1")
;; => (:error (:forbidden ":eval is not enabled"))
```

This records operator intent and gives an audit trail; it is not a
sandbox. A `:form` runs with nothing between it and `cl:eval` and can
redefine anything in the image, including `tool-trust` or `resolve-tools`
themselves. The [plan gate](plan.md) constrains what a *model* may reach
through `tool-plan`; `tool-self` is `:operator`-trusted like `tool-eval`,
and stays off the model's own allow-list the same way.

## Ops

| `:op` | Params | Answers |
|---|---|---|
| `:eval` | `:form` (required), `:package` (default `"CL-USER"`), `:timeout` | `:value`, `:out` |
| `:define` | `:form` (required), `:package`, `:timeout` | `:name` |
| `:reload` | `:name` (required) | `:name` |
| `:log` | `:limit` (default 50) | `:entries`, `:total` |

`:form` is read as exactly one expression, with `*read-eval*` nil -- the
same guard a generation's own read applies -- against `:package`, resolved
with `find-package` only: a package that doesn't already exist is a
`(:bad-request ...)`, never created on the caller's behalf. `:define`
additionally requires the form's head to be a definition -- `defun`,
`defmacro`, `defgeneric`, `defmethod`, `defclass`, `defstruct`,
`defparameter`, `defvar`, `m:defservice` or `nyaa:define-tool` -- so its
checkpoint and log entry describe an actual definition; anything else is
`:eval`'s job.

`:reload` is `m:reload` on the tool's own context: the named child is
stopped, reinitialised with its own mount initargs and started again.
There is no `:mount` or `:unmount` here -- caller-supplied initargs would
have to be logged, and a provider's `:api-key` is exactly the kind of
initarg that must never reach disk (see
[checkpoints](checkpoints.md#the-generation-file)). Arbitrary remount stays
with [#49](https://todo.sr.ht/~takeiteasy/nyaa/49).

`:eval` and `:define` run on their own thread, interrupted at `:timeout` --
the same shape as `tool-http`'s deadline (see [tools](tools.md#workers)) --
so a wedged form costs a timeout, not a wedged service. A value is printed
under the same caps a worker applies: `*print-length*` 100, `*print-level*`
8, a 4000-character cap.

A lapsed `:timeout` interrupts pre-emptively until evaluation reaches
SBCL's own class, method, generic-function or struct loader -- past an
`:eql` specializer's own form and a method's compile, the parts a wedged
or slow form could still be caught in. From there the interrupt does
nothing: the form finishes, so the deadline never tears a mutation. The
caller still gets `:timeout`; a write that lands afterwards is logged as a
`:late-outcome` entry. A form that wedges before that point -- a wedged
`:eql` specializer, a slow compile -- is killed, not leaked
([#79](https://todo.sr.ht/~takeiteasy/nyaa/79)).

## Checkpoint and log

Every write takes a [checkpoint](checkpoints.md) first, then writes an
intent log entry naming it -- before the op runs, so a crash mid-eval still
points at what to roll back to -- and an outcome entry after:

```lisp
(:at "2026-09-23T10:00:00Z" :kind :intent :op :eval
 :form "(+ 1 2)" :label nil :checkpoint "~/.nyaa/generations/....generation"
 :previous-source nil)
(:at "2026-09-23T10:00:00Z" :kind :outcome :op :eval :outcome :ok)
```

A write that finishes after its caller received `:timeout` adds a third
entry, `(:kind :late-outcome ... :checkpoint "..." :outcome :ok)`, whose
`:checkpoint` matches its intent entry's. The log always reads intent,
`:timeout` outcome, then `:late-outcome`.

`:previous-source` is `:define`'s defined name's `symbol-source`
([introspection](introspection.md)) as it stood before the write --
rollback restores declared service state, never code
([#48](https://todo.sr.ht/~takeiteasy/nyaa/48)), so this pointer is the
only way back to the old definition. The log is an append-only
s-expression file (`:log`, default `~/.nyaa/self.log`), read the same
guarded way a generation is: `*read-eval*` nil, so a log can never run code
merely by being read back. Each entry also reaches [meow's
logger](https://github.com/takeiteasy/meow/blob/trunk/docs/logger.md) when
one is mounted, at `:info` or `:warn`.

## `self-define` and `:require-image`

`:previous-source` is a manual way back, and only for one symbol.
[`self-define`](images.md) closes that for real: it takes an
[image generation](images.md) immediately before the write, so
`nyaa:relaunch`ing that core undoes the redefinition itself, not just
declared state.

```lisp
(nyaa:self-define *ctx* "(defun greet () :hi)" :package "MY-APP")
;; => :hi, #P"~/.nyaa/generations/....core"
```

It is a REPL entry, not a tool op: `save-image` needs the main thread, so
no agent turn can reach it, and there is no worker thread or `:timeout`
here for an operator to abandon -- interrupt it the ordinary way.
`(context form &key package label log)`; `context` is the mounted
context's process to image, matching `save-image`'s own argument.

`:require-image`, a mount option (default nil), refuses `:eval` and
`:define` once it's true unless an image has been taken and nothing has
written since:

```lisp
(m:mount *ctx* 'nyaa:tool-self :enable '(:eval :define) :require-image t)
(nyaa:invoke-tool :tool-self :op :eval :form "1")
;; => (:error (:bad-request "take an image generation first (~takeiteasy/nyaa#48)"))
```

With it set, `self-define` becomes the only way to still redefine
anything: every write it enables stays code-exact and undoable. Every
intent log entry, `:require-image` or not, also records `:image`, the
newest image's path at the time -- `nil` if none has been taken yet.

## Trust posture

`:operator` only. Host eval can read anything the image holds, including a
provider's `:api-key` -- unlike `tool-image`, which never returns a value
or a slot (see [introspection](introspection.md#trust-posture)), `tool-self`
*is* the way to see one, alongside `tool-eval` and `tool-repl`.

## Limitations

- Rollback restores declared service state, not code: an ordinary
  tool-self `:define`'s checkpoint does not undo the redefinition itself,
  only whatever state drifted around it. `:previous-source` is the manual
  way back; `self-define`'s image generation is the code-exact one, but
  only tracks tool-self's own writes -- code loaded any other way is not
  reflected in `:require-image`'s staleness check.
- A form that wedges *after* reaching its own CLOS mutation -- a second,
  later `defmethod` in the same `:eval` whose `:eql` specializer hangs --
  still leaks its thread, the same way the whole-form deferral did before
  it ([#81](https://todo.sr.ht/~takeiteasy/nyaa/81)).
- The checkpoint taken before a write waits up to `checkpoint`'s own 30
  second `:timeout` for a busy service, independent of `:timeout`, and
  does not report which services it caught mid-run.
