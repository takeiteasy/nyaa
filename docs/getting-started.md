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

Dependencies: `meow` and `alexandria`. meow pulls in `bordeaux-threads`
(bt2 API), `closer-mop` and `trivial-high-precision-timer`, which is not in
a Quicklisp dist and needs the local project above.

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
