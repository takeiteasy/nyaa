# nyaa

**N**ot **Y**our **A**verage **A**gent

A Cordis-inspired plugin/service runtime, in LFE on OTP, meant to host an
agent loop with sub-agent delegation, isolated scratch REPLs, live code
upgrade, and checkpoint/rollback -- built on supervision trees, message
passing, and hot code loading instead of a mutable Lisp image.

`apps/nyc` is the core runtime (context, service, registry). `apps/nyaa` is
the harness built on top of it.

See [docs/](docs/) for architecture, the registry's design, how to write a
plugin, and how to build and run this.

## License

GPLv3, see [LICENSE](LICENSE).
