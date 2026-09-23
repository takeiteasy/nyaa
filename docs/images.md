# Image generations

An image generation is a [generation](checkpoints.md) that also carries
the running image itself -- SBCL's `save-lisp-and-die` -- so a rollback
can undo code, not only declared state.

```lisp
(nyaa:save-image *ctx*)
;; => #P"~/.nyaa/generations/20260923-105642-113500.core"
```

## `save-image`

`(save-image context &key dir label keep)`:

1. Refuses unless called on the main thread.
2. Refuses if a mounted [provider](providers.md) holds an `:api-key`
   initarg -- a core file is a copy of the whole heap, and keeping a
   credential off it is the same line [providers](providers.md#credentials)
   and [`tool-image`](introspection.md) already hold for published state.
3. Takes a declared-state [checkpoint](checkpoints.md) of `context`.
4. [`m:suspend`](https://github.com/takeiteasy/meow/blob/trunk/docs/suspend.md)s
   `context`'s whole tree, so only the calling thread is left --
   `save-lisp-and-die` and `fork(2)` both refuse otherwise.
5. Forks. The child `save-lisp-and-die`s a `.core` next to the
   checkpoint's `.generation`; the parent waits for it and
   [resumes](https://github.com/takeiteasy/meow/blob/trunk/docs/suspend.md)
   the suspended tree.

The calling process is unaffected either way: every service is suspended
for the fork and resumed again before `save-image` returns.

## Relaunching

`(relaunch core)` probes `core` in a subprocess and, if it loads cleanly,
`execv`s the current process into it. Never returns on success.

The saved core's own toplevel, on load:

1. Exits at once if `NYAA_IMAGE_PROBE` is set -- `relaunch` and
   `bin/nyaa` both use this to check a core loads without reviving its
   services.
2. Otherwise, `cl+ssl:reload`s (foreign libraries need re-initialising
   after a reload), `m:resume`s the tree `save-image` suspended -- the
   same process and service instances the core's heap already holds, so
   nothing is rediscovered -- and falls through to SBCL's own toplevel,
   so `--eval`, `--non-interactive` and a plain REPL all work as usual.

## `generations`

[`generations`](checkpoints.md) reports each entry's `:image`, the
sibling `.core`'s path, or nil if none was taken. `:keep` prunes a core
alongside its generation.

## `bin/nyaa` and `bin/nyaa-install`

```sh
bin/nyaa-install                    # build ~/.nyaa/images/recovery.core
bin/nyaa                            # run the newest generation, or recovery
bin/nyaa path/to/some.core          # run a specific core
bin/nyaa -- --eval '(+ 1 2)'        # extra args reach sbcl
```

`bin/nyaa` probes its chosen core the same way `relaunch` does, and falls
back to the recovery image -- a plain image with no services, built by
`bin/nyaa-install` -- if it doesn't load cleanly. `NYAA_HOME` (default
`~/.nyaa`) holds both the recovery image and the generations directory.

## Trust posture

Reaches everywhere `tool-self`'s `:eval` already does -- taking an image
is `:operator`-level, done from the REPL
([`self-define`](self.md#self-define-and-require-image)), not a
model-reachable tool op.

## Limitations

- Needs a current SBCL build. 2.2.9 (Debian's `apt` package as of this
  writing) segfaults inside `save-lisp-and-die`'s own C runtime
  ([#72](https://todo.sr.ht/~takeiteasy/nyaa/72)); 2.6.8 is known good.
- A relaunched core's other external handles -- open sockets, worker
  process handles, a `tool-repl` session -- are stale, not just `cl+ssl`'s
  context. `cl+ssl:reload` is the only one handled here
  ([#70](https://todo.sr.ht/~takeiteasy/nyaa/70)).
- A core is tens of megabytes; taking one is not free, and `bin/nyaa`'s
  probe launches a whole second SBCL process.
