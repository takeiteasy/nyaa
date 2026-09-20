# Getting started

## Loading

nyaa loads through Quicklisp's local projects, alongside
[meow](https://github.com/takeiteasy/meow) and its own out-of-dist
dependency:

```sh
ln -s ~/git/nyaa ~/quicklisp/local-projects/nyaa
ln -s ~/git/meow ~/quicklisp/local-projects/meow
git clone https://github.com/takeiteasy/trivial-high-precision-timer \
    ~/quicklisp/local-projects/trivial-high-precision-timer
```

```lisp
(ql:quickload :nyaa)
```

Dependencies: `meow`, `alexandria`, [`jzon`](https://github.com/Zulu-Inuoe/jzon)
for JSON, [`drakma`](https://edicl.github.io/drakma/) with `flexi-streams` and
`usocket` for HTTP, and `bordeaux-threads` (bt2 API) for the tool deadlines.
meow pulls in `closer-mop` and `trivial-high-precision-timer`, which is not in a
Quicklisp dist and needs the local project above. drakma needs OpenSSL for
HTTPS.

The [tools](tools.md) mount into a meow context:

```lisp
(defvar *tools* (meow:start-service (make-instance 'meow:context :name :tools)))
(meow:mount *tools* 'nyaa:tool-fs :root "/srv/workspace")
(meow:mount *tools* 'nyaa:tool-shell)
(nyaa:invoke-tool :tool-shell :cmd "echo hello")
```

Runs on SBCL and ECL.

## Tests

The suite uses FiveAM and runs through ASDF:

```lisp
(asdf:test-system :nyaa)
```

From the shell, `tests/test.sh` runs it on `sbcl` (default), `ecl` or `ccl`
and exits non-zero on failure:

```sh
tests/test.sh ecl
```

Tests that make real network requests are skipped unless `NYAA_LIVE_HTTP` is
set:

```sh
NYAA_LIVE_HTTP=1 tests/test.sh
```
