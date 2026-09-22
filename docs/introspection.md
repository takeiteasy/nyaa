# Introspection

Two `:agent`-trusted, always-on, read-only tools over the running image:
`tool-image` for the CL image, `tool-services` for the
[meow](https://github.com/takeiteasy/meow) supervision tree it runs under.

```lisp
(m:mount context 'nyaa:tool-image)
(m:mount context 'nyaa:tool-services)
```

Neither ever returns a value or a slot — flags and shapes only. That holds
even for a bound special: `tool-eval` and `tool-repl`, both `:operator`, stay
the way to see one.

## `tool-image`

| `:op` | Params | Answers |
|---|---|---|
| `:describe` | `:symbol` (required), `:package` | `:name`, `:package`, `:fboundp`, `:boundp`, `:kind`, `:lambda-list`, `:documentation`, `:variable-documentation`, `:source` |
| `:apropos` | `:pattern` (required), `:package`, `:external-only` (default `t`), `:limit` (default 100) | `:symbols`, `:total`, `:truncated` |
| `:documentation` | `:symbol` (required), `:doc-type` (default `:function`) | `:documentation` |
| `:source` | `:symbol` (required), `:doc-type` | `:available`, and `:file`/`:position` when it is |
| `:packages` | — | `:packages` — each loaded package's name and nicknames |

`:symbol` is `"nyaa:complete"` or `"complete"` against `:package` (or
`*package*`), resolved with `find-symbol` — never `read-from-string` or
`intern`, so a lookup cannot grow the image. An unresolvable `:package` or
`:symbol` is a `(:bad-request ...)`.

```lisp
(nyaa:invoke-tool :tool-image :op :describe :symbol "nyaa:complete")
;; => (:ok (:name "COMPLETE" :package "NYAA" :fboundp t :boundp nil
;;          :kind :function :lambda-list "(NAME &REST REQUEST)"
;;          :documentation "..." :variable-documentation nil
;;          :source (:available t :file "/.../protocol.lisp" :position 8572)))
```

`:kind` is the most specific of `:special-operator`, `:macro`,
`:generic-function`, `:function`, `:class`, `:constant`, `:variable` or
`:unbound` — a symbol can be several of these; `:describe` picks one.

`:apropos` is capped by `:limit`: a loose pattern against a loaded image is
thousands of symbols, so it reports `:total` and `:truncated` rather than
cutting silently.

Lambda lists and source locations are implementation-specific:
`sb-introspect` on SBCL, `ext:compiled-function-file` and
`si::function-lambda-list` on ECL, `ccl:arglist` for a lambda list on CCL.
Absent — an interpreted definition on SBCL, anything not loaded from a
compiled file on ECL, any source location at all on CCL — reports
`:available nil` rather than erroring
([#47](https://todo.sr.ht/~takeiteasy/nyaa/47),
[#62](https://todo.sr.ht/~takeiteasy/nyaa/62)).

## `tool-services`

| `:op` | Params | Answers |
|---|---|---|
| `:registry` | `:kind` | every registered name and its published props, sorted, optionally filtered to one `:kind` |
| `:children` | `:recursive` (default `t`) | the mount tree under this tool's own context: `:name`, `:class`, `:restart`, `:state`, `:restart-in`, `:alive` |
| `:describe` | `:name` (required) | that name's props, `:alive`, and its effect labels |

Props are exactly what each service's `metadata` already publishes — the
same source `describe-tool` reads, key-free by construction.

```lisp
(nyaa:invoke-tool :tool-services :op :children)
;; => (:ok (:children ((:name :tool-fs :class "tool-fs" :restart :transient
;;                       :state :running :restart-in nil :alive t) ...)))
```

`:state` is `m:children`'s own restart bookkeeping (`:running` or
`:restarting`), not the richer lifecycle `service-status` tracks
([#46](https://todo.sr.ht/~takeiteasy/nyaa/46)). A tool mounted outside a
context — `:children` needs one to walk — answers `(:error "not mounted
under a context")`.

## Trust posture

Both tools are `:agent`-trusted: read-only introspection is the point of
always-on tools, so they carry no operator gate. What they must never do is
leak a slot — a provider's `:api-key` lives in one, and is kept out of
published metadata for exactly that reason (see
[providers](providers.md#credentials)) — so `:describe` reports `:boundp`
and `:fboundp` as flags and nothing more. `tool-services` never reads a
slot at all; everything it answers already travels through `metadata` or
`m:children`.
