# nyaa

**N**ot **Y**our **A**verage **A**gent

An agent harness in Common Lisp, built on
[meow](https://github.com/takeiteasy/meow). Tools, model adapters and the
agent loop are meow services under one root context, so they mount in any
order, restart under supervision, and are discovered through the registry.

Runs on SBCL.

## Docs

- [Getting started](docs/getting-started.md)
- [Tools](docs/tools.md)
- [Introspection](docs/introspection.md)
- [The plan gate](docs/plan.md)
- [Protocols](docs/protocols.md)
- [Providers](docs/providers.md)
- [The agent loop](docs/agent.md)
- [Parameter schemas](docs/schema.md)
- [Checkpoints and rollback](docs/checkpoints.md)
- [Image generations](docs/images.md)
- [Self-modification](docs/self.md)
- [The vault](docs/vault.md)

## License

```
nyaa
Copyright (C) 2026 George Watson

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
```
