# Chat

`nyaa chat` is a line-by-line chat with one [agent](agent.md). It streams the
answer, shows tool calls and their results, and takes a line typed mid-run as
a steer. It is the secondary system `nyaa/cli`, drawn from
[client state](client-state.md).

```sh
nyaa chat --model ollama:llama3.2 --tools tool-fs
```

```
> how many .lisp files are here?
[fs-list (:PATH ".")]
[result (:OK (:ENTRIES ...))]
There are 41.
> and in tests/?
```

## Options

The options of [`nyaa run`](cli.md#options), without `PROMPT` and `-v`. A prompt
argument is a usage error (exit 2).

## Keys

| Input | While idle | While a run is under way |
|---|---|---|
| a line | starts a run that carries on from the conversation | [steers](ui.md#commands) the run |
| an empty line | ignored | ignored |
| Ctrl-C | leaves the chat | cancels the run, and the chat carries on |
| Ctrl-D | leaves the chat | leaves the chat |

The agent is mounted as `:chat` and holds the conversation, so each line sees
what came before. It is unmounted when the chat ends.

## Output

| Line | Meaning |
|---|---|
| text | the answer, as it streams |
| `[name args]` | a tool call, arguments shortened to 200 characters |
| `[result ...]` | what it answered, shortened the same way |
| `[turn-retry ...]`, `[context-trimmed ...]` and the like | notices from the run |
| `[run ended: reason]` | the run stopped for any reason but `:stop` |
| `> ` | the run is over; the next line goes to the model |

An existing install needs `nyaa install` again to get `chat` into its saved core.

## Limitations

- A line that reads as Lisp is sent as a prompt
  ([#204](https://todo.sr.ht/~takeiteasy/nyaa/204)).
- The chat draws the [text the provider streams](protocols.md#streaming), so an
  answer that is not streamed is not shown
  ([#205](https://todo.sr.ht/~takeiteasy/nyaa/205)).
- A chat starts empty: it does not resume a saved conversation
  ([#100](https://todo.sr.ht/~takeiteasy/nyaa/100)).
