(defmodule nyaa-sup
  (export
    (start_link 0)))

;;; The harness's root context. Deliberately just an nyc-context (see
;;; apps/nyc/src/nyc-context.lfe) rather than a hand-rolled supervisor
;;; module -- a top-level context is not a special case, it's the same
;;; primitive every nested context uses, registered under 'nyaa-root.
;;; Tool/skill/sub-agent plugins mount onto it via nyc-context:mount/2.

(defun start_link ()
  (nyc-context:start_link 'nyaa-root #m()))
