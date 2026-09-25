# The launcher

`nyaa` starts nyaa from the newest [image generation](images.md), falling
back to a recovery image if it will not load. It is a [Roswell](https://github.com/roswell/roswell)
script, `roswell/nyaa.ros`.

```sh
nyaa install                        # build ~/.nyaa/images/recovery.core
nyaa                                # newest generation, else recovery
nyaa --core path/to/some.core       # a specific core
nyaa -- --eval '(+ 1 2)'            # arguments after -- reach sbcl
nyaa run "list the files" -v        # one-shot agent run, see cli.md
```

## Installing

```sh
ros install takeiteasy/nyaa         # puts nyaa on ~/.roswell/bin
ln -s ~/git/nyaa/roswell/nyaa.ros ~/.local/bin/nyaa   # or from a checkout
```

`install` builds the recovery image with `nyaa` and its dependencies loaded
through Quicklisp (`$QUICKLISP_SETUP`, default `~/quicklisp/setup.lisp`).

## Choosing a core

| Step | Result |
|---|---|
| `--core F` given, `F` missing | error |
| `--core F`, else the newest `generations/*.core` | probed |
| the probe fails | warning on stderr, the recovery image is used |
| no candidate | the recovery image |
| no recovery image | error naming `nyaa install` |

The probe runs the core with `NYAA_IMAGE_PROBE` set, as
[`relaunch`](images.md#relaunching) does, so a core that will not load never
replaces a working process. `NYAA_HOME` (default `~/.nyaa`) holds
`generations/` and `images/recovery.core`.

The launcher `exec`s the core in Roswell's SBCL, the runtime `relaunch` execs
too.[^runtime] It does not load nyaa itself.

## Limitations

- A core saved by another SBCL build does not load, so it falls back to
  recovery; rebuild it with `nyaa install`.
- The probe starts a second SBCL process per launch.

[^runtime]: An SBCL core loads only in the runtime build that saved it, so
    cores saved from a `sbcl` on `PATH` of another version fail the probe.
