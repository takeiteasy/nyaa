(defmodule nyaa-tool-repl
  (export
    (child_spec 0)
    (service_name 0)
    (dependencies 0)
    (metadata 0)
    (init 1)
    (handle_message 2)
    (terminate 2)))

;;; Standard tool plugin over nyaa-repl: persistent scratch LFE REPLs.
;;; Each invocation targets a REPL by id; REPLs are created lazily on
;;; first eval and keep their env across evals (set/defun/defmacro
;;; stick), so this is the stateful sibling of tool-eval, which is
;;; stateless per form. pristine=true stops whatever process holds the
;;; id and evaluates against a fresh one instead. Same trust posture as
;;; tool-eval: raw LFE evaluation, trusted operator only (#14 gates any
;;; untrusted exposure).

(defun child_spec ()
  `#m(id tool-repl
      start #(patchbay_service start_link (nyaa-tool-repl #m()))
      restart transient
      shutdown 5000
      type worker
      modules (patchbay_service)))

(defun service_name () 'tool-repl)
(defun dependencies () '())

(defun metadata ()
  ;;; Published as registration props (patchbay_service metadata/0);
  ;;; this is what makes the tool discoverable via kind=tool.
  (describe))

(defun init (_args) `#(ok #m()))

(defun describe ()
  #m(kind tool
     name 'tool-repl
     summary #"Evaluate LFE forms in a persistent scratch REPL (trusted operator only)"
     params #m(id "the REPL id to evaluate against (created on first use)"
               form "the LFE form to evaluate"
               pristine "if true, spawn a fresh REPL instead of reusing the existing one (default false)"
               timeout "give up after this many ms (default 5000)")))

(defun handle_message
  (('describe state) `#(reply ,(describe) ,state))
  ((`#(invoke ,req) state) (invoke req state)))

(defun terminate (_reason _state) 'ok)

;;; --- implementation -------------------------------------------------

(defun invoke (req state)
  (case (maps:find 'id req)
    (`#(ok ,id)
     (case (maps:find 'form req)
       (`#(ok ,form)
        `#(reply ,(repl-eval id form req) ,state))
       (_ `#(reply #(error #(bad_request "form required")) ,state))))
    (_ `#(reply #(error #(bad_request "id required")) ,state))))

(defun repl-eval (id form req)
  ;;; Computed map values need a backquoted #m -- see ROADMAP lessons.
  (nyaa-repl:eval id form
                  `#m(pristine ,(maps:get 'pristine req 'false)
                      timeout ,(maps:get 'timeout req 5000))))
