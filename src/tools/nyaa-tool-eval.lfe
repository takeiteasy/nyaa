(defmodule nyaa-tool-eval
  (export
    (child_spec 0)
    (service_name 0)
    (dependencies 0)
    (metadata 0)
    (init 1)
    (handle_message 2)
    (terminate 2)))

;;; Standard tool plugin: raw LFE form evaluation. This is the
;;; arbitrary-code surface the #6 decision accepted and #14 exists to
;;; eventually constrain: it runs whatever form it is handed with full
;;; node privileges. Trusted operator only -- see
;;; docs/getting-started.md, "Security & trust". Do not wire untrusted
;;; input here; that is exactly what the constrained DSL (#14) is for.
;;;
;;; Robustness: each form runs in a throwaway process, so a crashing or
;;; infinitely-looping form costs at most its timeout, never this
;;; service's life. The result is the form's value, or an error tuple.

(defun child_spec ()
  `#m(id tool-eval
      start #(patchbay_service start_link (nyaa-tool-eval #m()))
      restart transient
      shutdown 5000
      type worker
      modules (patchbay_service)))

(defun service_name () 'tool-eval)
(defun dependencies () '())

(defun metadata ()
  ;;; Published as registration props (patchbay_service metadata/0);
  ;;; this is what makes the tool discoverable via kind=tool.
  (describe))

(defun init (_args) `#(ok #m()))

(defun describe ()
  #m(kind tool
     name 'tool-eval
     summary #"Evaluate an LFE form on the node (trusted operator only)"
     params #m(form "the LFE form to evaluate"
               timeout "give up after this many ms (default 5000)")))

(defun handle_message
  (('describe state) `#(reply ,(describe) ,state))
  ((`#(invoke ,req) state)
   (case (maps:find 'form req)
     (`#(ok ,form)
      (let ((timeout (maps:get 'timeout req 5000)))
        `#(reply ,(eval-isolated form timeout) ,state)))
     (_ `#(reply #(error #(bad_request "form required")) ,state)))))

(defun terminate (_reason _state) 'ok)

;;; --- implementation -------------------------------------------------

;; Spawn an unlinked evaluator so neither a crash nor a hang in the
;; form can take down (or wedge) this service. lfe_eval:expr/1 needs no
 ;; environment for plain forms; macros expand via the loaded modules.
(defun eval-isolated (form timeout)
  (let ((me (self))
        (ref (make_ref)))
    (let ((worker
            (erlang:spawn
              (lambda ()
                (erlang:send me `#(eval_result ,ref
                                   ,(try-catch-value form)))))))
      (receive
        (`#(eval_result ,ref ,result) result)
        (after
          timeout
          (erlang:exit worker 'kill)
          '#(error timeout))))))

(defun try-catch-value (form)
  ;;; Normal path builds #(ok value); a throw delivers #(EXIT reason)
  ;;; instead -- normalized below so callers always get either
  ;;; #(ok V) or #(error R).
  (let ((result (catch `#(ok ,(lfe_eval:expr form (lfe_env:new))))))
    (case result
      (`#(ok ,value) `#(ok ,value))
      (`#(EXIT ,reason) `#(error ,reason)))))
