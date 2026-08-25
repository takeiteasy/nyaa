(defmodule nyaa-sup
  (export
    (start_link 0)))

;;; The harness's root context. Deliberately just a patchbay_context
;;; (see apps/patchbay/src/patchbay_context.erl) rather than a
;;; hand-rolled supervisor module -- a top-level context is not a special
;;; case, it's the same primitive every nested context uses, registered
;;; under 'nyaa-root. Tool/skill/sub-agent plugins mount onto it via
;;; patchbay_context:mount/2.

(defun start_link ()
  (patchbay_context:start_link 'nyaa-root #m()))
