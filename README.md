# nyaa

**N**ot **Y**our **A**verage **A**gent

An agent harness on the BEAM (in LFE): an agent loop with sub-agent
delegation, isolated scratch REPLs, live code upgrade, and
checkpoint/rollback -- built on supervision trees, message passing, and
hot code loading instead of a mutable Lisp image.

It is built on [patchbay](https://github.com/takeiteasy/patchbay), a
standalone Cordis-inspired plugin/service runtime core (contexts,
services with mount-order-independent dependency injection, a race-free
registry, dynamic sub-agent supervision). patchbay is pure Erlang with
zero non-OTP dependencies, and its plugin contracts are plain atoms,
tuples, and maps -- so plugins can be written in any BEAM language. See
the [patchbay docs](https://github.com/takeiteasy/patchbay/tree/trunk/docs)
for architecture and the plugin contract; this repo's
[docs/getting-started.md](docs/getting-started.md) covers building and
running the demo pair in `src/demo/` that exercises the core.
In-repo conventions: tools & skills in [docs/tools.md](docs/tools.md),
model backends in [docs/adapters.md](docs/adapters.md).

Both projects share one issue tracker: `~takeiteasy/nyaa` on sourcehut.

## License

GPLv3, see [LICENSE](LICENSE).
