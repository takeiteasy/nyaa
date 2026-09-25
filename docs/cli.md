# The command line

`nyaa run` runs one [agent](agent.md) to completion, prints the answer and
exits. [`nyaa chat`](chat.md) talks to one agent turn by turn. Both are in the
secondary system `nyaa/cli`, started through [the launcher](launcher.md).

```sh
nyaa run "how many .lisp files are here?" --model ollama:llama3.2 \
    --tools tool-fs,tool-shell -v
```

## Options

| Option | Meaning |
|---|---|
| `PROMPT` | the task, one argument; `chat` takes none |
| `--model PROVIDER:MODEL` | a [provider](providers.md) and its model, split on the first colon; default `ollama:llama3.2` |
| `--tools NAME,...` | [tools](tools.md) the model may call, by full service name; none by default |
| `--system-file FILE` | text added to the default system prompt |
| `--system-replace` | with `--system-file`, the file is the whole system prompt |
| `--max-turns N` | most model turns before the run stops itself; default 16, see [the agent](agent.md#mount-options) |
| `-v`, `--verbose` | `run` only: one line per event on stderr, and streamed text |

`chat` takes the same options except `PROMPT` and `-v`. A provider or tool is mounted by name from the [definitions](tools.md#definitions)
table, so anything `define-provider` or `define-tool` has defined in the
launched core is available. `tool-fs` is rooted at the current directory.
`$NYAA_HOME/init.lisp`, when it exists, is loaded first, so it can define
more.

## Output and exit codes

The final answer goes to stdout, followed by a newline. Everything else --
errors, `-v` events, the reason a run was cut short -- goes to stderr.

| Code | Meaning |
|---|---|
| 0 | the run stopped: the model finished |
| 1 | a run error: the model or a provider failed, or `init.lisp` did |
| 2 | a usage error: bad option, unknown provider or tool, missing prompt |
| 3 | the run was cut short by `:max-turns` or `:timeout`; any text so far is on stdout |

```sh
if answer=$(nyaa run "summarise README.md" --tools tool-fs); then
  echo "$answer"
fi
```
