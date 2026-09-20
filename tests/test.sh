#!/bin/sh
# Usage: tests/test.sh [sbcl|ecl|ccl]
set -e

QL="${QUICKLISP_SETUP:-$HOME/quicklisp/setup.lisp}"
RUN="(progn (ql:quickload :nyaa/tests :silent t) (asdf:test-system :nyaa))"

case "${1:-sbcl}" in
    sbcl) exec sbcl --non-interactive --no-userinit --load "$QL" --eval "$RUN" ;;
    ecl)  exec ecl --norc --load "$QL" \
               --eval "(handler-case $RUN (error (e) (format t \"~a~%\" e) (ext:quit 1)))" \
               --eval "(ext:quit 0)" ;;
    ccl)  exec ccl --no-init --batch --load "$QL" \
               --eval "(handler-case $RUN (error (e) (format t \"~a~%\" e) (ccl:quit 1)))" \
               --eval "(ccl:quit 0)" ;;
    *)    echo "unknown lisp: $1" >&2; exit 2 ;;
esac
