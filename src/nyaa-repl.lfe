(defmodule nyaa-repl
  (behaviour gen_server)
  (export
    (child_spec 1)
    (start 1)
    (start_link 1)
    (eval 2)
    (eval 3)
    (stop 1)
    (list-repls 0)
    (init 1)
    (handle_call 3)
    (handle_cast 2)
    (handle_info 2)
    (terminate 2)
    (code_change 3)))

;;; Ephemeral scratch REPLs (#2): one plain process per REPL id,
;;; running a minimal LFE reader/evaluator loop, mounted as a
;;; `temporary` child of the 'nyaa-root context and registered as
;;; #(repl ,id) in patchbay_registry with kind=repl props.
;;;
;;; State model: the interpreter env threads across evals. Top-level
;;; `(set pat expr)` binds via lfe_env:add_vbinding and top-level
;;; `(defun ...)` installs an interpreted function via
;;; lfe_eval:add_dynamic_func -- the same approach lfe_shell uses;
;;; macro definitions come free through expand_fileforms updating the
;;; env. Everything else evaluates with lfe_eval:expr.
;;;
;;; Robustness: every expression runs in a throwaway process, so a
;;; crashing or looping form costs at most its timeout and never takes
;;; down the REPL or corrupts its env. A pristine eval stops whatever
;;; REPL holds the id and spawns a fresh one instead of reusing it.
;;; REPLs are created lazily by eval when the id is not running; use
;;; start for eager creation (it is also what surfaces duplicate-id
;;; errors).
;;;
;;; Trust posture: identical to nyaa-tool-eval -- raw LFE evaluation
;;; with full node privileges, trusted operator only until the
;;; constrained DSL (#14) exists.

;;; --- API -------------------------------------------------------------

(defun name-for (id) (tuple 'repl id))

(defun child_spec (id)
  `#m(id ,(name-for id)
      start #(nyaa-repl start_link (,id))
      restart temporary
      shutdown 1000
      type worker
      modules (nyaa-repl)))

;; Mount a fresh REPL on the root context and wait until it has
;; registered. Fails rather than reusing an existing id.
;;
;; Pattern-position note: bare _ inside backquoted #(...) templates
;; compiles into literal junk atoms rather than wildcards -- patterns
;; here always use explicit (tuple ...) shapes (see ROADMAP lessons);
;; backtick templates stay in expression position only.
(defun start (id)
  (case (patchbay_registry:lookup (name-for id))
    ((tuple 'ok _) `#(error #(already_registered ,id)))
    (_ (case (patchbay_registry:lookup 'nyaa-root)
         ((tuple 'ok (tuple ctx _))
          (match-mount (patchbay_context:mount ctx (child_spec id)) id))
         (_ '#(error root_not_found))))))

(defun match-mount (mounted id)
  (case mounted
    ((tuple 'ok pid)
     (case (patchbay_registry:await (name-for id) 5000)
       ((tuple 'ok _) `#(ok ,pid))
       ((tuple 'error reason) `#(error ,reason))))
    ((tuple 'error reason) `#(error ,reason))))

;; Forward to the REPL process; the call timeout is padded above the
;; per-form isolation timeout so a form that exhausts its budget comes
;; back as #(error timeout) rather than killing the caller's call. A
;; gen_server exit (REPL died mid-call) surfaces as an error too.
(defun eval-at (pid form timeout)
  (let ((result
          (catch (gen_server:call pid `#(eval ,form ,timeout)
                                  (+ timeout 1000)))))
    (case result
      (`#(ok ,value) `#(ok ,value))
      (`#(error ,reason) `#(error ,reason))
      (`#(EXIT ,reason) `#(error ,reason)))))

;; Evaluate a form on the REPL named Id, creating it if it is not
;; running. Opts: timeout (ms, default 5000), pristine (kill + respawn
;; before evaluating). Returns #(ok Value) | #(error Reason).
(defun eval (id form) (eval id form #m()))

(defun eval (id form opts)
  (let ((timeout (maps:get 'timeout opts 5000)))
    (if (maps:get 'pristine opts 'false)
      (progn (stop id) (start id))
      'ok)
    (ensure-and-eval id form timeout)))

;; The lazy half of creation: a first eval against an unknown id
;; spawns the REPL rather than failing.
(defun ensure-and-eval (id form timeout)
  (case (patchbay_registry:lookup (name-for id))
    ((tuple 'ok (tuple pid _)) (eval-at pid form timeout))
    (_ (case (start id)
         ((tuple 'ok _)
          (case (patchbay_registry:lookup (name-for id))
            ((tuple 'ok (tuple pid _)) (eval-at pid form timeout))
            (_ '#(error repl_unavailable))))
         ((tuple 'error reason) `#(error ,reason))))))

;; Stop (unmount) the REPL holding Id. Idempotent: stopping an unknown
;; or already-stopped id is ok -- temporary children are auto-deleted
;; by the supervisor once terminated, so not_found simply means there
;; is nothing left to stop.
(defun stop (id)
  (case (patchbay_registry:lookup 'nyaa-root)
    ((tuple 'ok (tuple ctx _))
     (case (patchbay_context:unmount ctx (name-for id))
       ('ok 'ok)
       ((tuple 'error 'not_found) 'ok)
       ((tuple 'error reason) `#(error ,reason))))
    (_ '#(error root_not_found))))

(defun list-repls ()
  ;;; The ids of all live REPLs, from a registry scan.
  ;;; Zero-arity calls carry no trailing () in LFE -- (names()) would
  ;;; pass the empty list as an argument.
  (lists:filtermap
    (lambda (name)
      (case name
        ((tuple 'repl id) `#(true ,id))
        (_ 'false)))
    (patchbay_registry:names)))

;;; --- gen_server callbacks --------------------------------------------

(defun start_link (id)
  (gen_server:start_link 'nyaa-repl id '()))

(defun init (id)
  (process_flag 'trap_exit 'true)
  (case (patchbay_registry:register (name-for id) (self) `#m(kind repl id ,id))
    ('ok `#(ok #m(id ,id env ,(lfe_env:new))))
    (`#(error ,reason) `#(stop ,reason))))

(defun handle_call
  ((`#(eval ,form ,timeout) _from state)
   ;; do-eval returns the full gen_server reply: #(reply R State2).
   (do-eval form timeout state)))

(defun handle_cast (_msg state) `#(noreply ,state))

(defun handle_info (_msg state) `#(noreply ,state))

(defun terminate (_reason state)
  ;; Best-effort: the registry's monitor-based cleanup would remove the
  ;; entry anyway once this pid dies, but explicit unregistration keeps
  ;; the ordering deterministic for anyone subscribed to the name.
  (patchbay_registry:unregister (name-for (maps:get 'id state)))
  'ok)

(defun code_change (_old state _extra) `#(ok ,state))

;;; --- evaluation ------------------------------------------------------

;; Macro-expand the form (this is where defmacro/defun become their
;; define-* shapes and where new macros enter the env), then evaluate
;; the expanded forms in order; the last value is the result.
(defun do-eval (form timeout state)
  (let ((env (maps:get 'env state)))
    (case (lfe_macro:expand_fileforms (list (tuple form 1)) env 'false 'true)
      ((tuple 'ok eforms env1 _warnings)
       (let ((result (eval-seq eforms timeout (maps:put 'env env1 state))))
         (case result
           ((tuple 'ok value state2) `#(reply #(ok ,value) ,state2))
           ((tuple 'error reason state2) `#(reply #(error ,reason) ,state2)))))
      ((tuple 'error errors _warnings)
       `#(reply #(error #(expand ,errors)) ,state)))))

;; Fold over expanded forms carrying #(ok Value State) through them so
;; bindings made by one form are visible to the next.
(defun eval-seq (forms timeout state)
  (lists:foldl
    (lambda (pair acc)
      (case acc
        ((tuple 'ok _ st) (eval-one (element 1 pair) timeout st))
        (_ acc)))
    `#(ok '() ,state)
    forms))

(defun eval-one
  (((tuple 'progn inner) timeout state)
   ;;; Nested progn at the top level: evaluate each inner form.
   (eval-seq (lists:map (lambda (f) (tuple f 1)) inner) timeout state))
  (((cons 'set rest) timeout state)
   (do-set rest timeout state))
  (((cons 'define-function args) timeout state)
   ;;; (define-function Name Meta Def) after defun expansion.
   (do-define-function args state))
  (((cons 'define-macro args) timeout state)
   ;;; (define-macro Name Meta Def) after defmacro expansion -- the
   ;;; binding already entered the env during expansion, but the
   ;;; leftover form is not an interpreter expression, so install it
   ;;; explicitly like lfe_shell does rather than evaluating it.
   (do-define-macro args state))
  (((cons 'define-record args) timeout state)
   ;;; (define-record Name Fields), same story.
   (do-define-record args state))
  (((cons 'extend-module _) timeout state)
   ;;; Macro-expansion artifacts from module-level forms: recognized
   ;;; and ignored, as in lfe_shell.
   `#(ok 'extend-module ,state))
  (((cons 'eval-when-compile _) timeout state)
   `#(ok 'eval-when-compile ,state))
  ((form timeout state)
   ;;; General case: plain expression evaluation, env unchanged.
   ;;; eval-isolated already normalizes to #(ok V) | #(error R), so
   ;;; unwrap rather than re-wrap.
   (let ((env (maps:get 'env state)))
     (case (eval-isolated form env timeout)
       ((tuple 'ok value) `#(ok ,value ,state))
       ((tuple 'error reason) `#(error ,reason ,state))))))

;; (set pat expr) or (set pat (when guard...) expr): evaluate expr in
;; isolation, match it against the pattern, fold the bindings into the
;; env. Mirrors lfe_shell's set/2.
(defun do-set (args timeout state)
  (case args
    ((cons pat tail)
     (case (split-set pat tail)
       (`#(ok ,pat2 ,guard ,expr)
        (let* ((env (maps:get 'env state))
               (epat (lfe_macro:expand_expr_all pat2 env)))
          (case (eval-isolated expr env timeout)
            ((tuple 'ok value)
             (case (lfe_eval:match_when epat value guard env)
               ((tuple 'yes _ bs)
                (let ((env2 (lists:foldl
                              (lambda (b e)
                                (lfe_env:add_vbinding (element 1 b)
                                                      (element 2 b)
                                                      e))
                              env bs)))
                  ;;; Computed elements inside a template need commas --
                  ;;; without one this would embed the call as data.
                  `#(ok ,value ,(maps:put 'env env2 state))))
               ('no `#(error #(badmatch ,value) ,state))))
            ((tuple 'error reason) `#(error ,reason ,state)))))
       (_ `#(error #(bad_form set) ,state))))
    (_ `#(error #(bad_form set) ,state))))

(defun split-set (pat tail)
  (case tail
    ((cons `('when . ,grest) (cons expr '()))
     `#(ok ,pat ,(cons 'when grest) ,expr))
    ((cons expr '())
     `#(ok ,pat '() ,expr))
    (_ 'false)))

;; defun support: install the lambda as a dynamic function in the env
;; (the same mechanism lfe_shell uses); the form's value is its name.
(defun do-define-function (args state)
  (case args
    ((cons name (cons _meta (cons def '())))
     (let ((env2 (lfe_eval:add_dynamic_func
                   name (function-arity def) def (maps:get 'env state))))
       `#(ok ,name ,(maps:put 'env env2 state))))
    (_ `#(error #(bad_form define-function) ,state))))

(defun do-define-macro (args state)
  (case args
    ((cons name (cons _meta (cons def '())))
     (let ((env2 (lfe_env:add_mbinding name def (maps:get 'env state))))
       `#(ok ,name ,(maps:put 'env env2 state))))
    (_ `#(error #(bad_form define-macro) ,state))))

(defun do-define-record (args state)
  (case args
    ((cons name (cons fields '()))
     (let ((env2 (lfe_env:add_record name fields (maps:get 'env state))))
       `#(ok ,name ,(maps:put 'env env2 state))))
    (_ `#(error #(bad_form define-record) ,state))))

(defun function-arity
  (((cons 'lambda (cons args _))) (length args))
  (((cons 'match-lambda (cons (cons pats _) _))) (length pats))
    ;;; Unknown definition shape: arity 0 is as good a guess as any and
    ;;; add_dynamic_func only uses it for dispatch bookkeeping.
  ((_ ) 0))

;;; Run one expression in a throwaway process so neither a crash nor a
;;; hang can hurt this REPL; lfe_eval:expr needs no environment setup
;;; beyond the threaded env. On timeout the env stays untouched.
(defun eval-isolated (form env timeout)
  (let ((me (self))
        (ref (make_ref)))
    (let ((worker
            (erlang:spawn
              (lambda ()
                (erlang:send me `#(eval_result ,ref
                                   ,(try-catch-value form env)))))))
      (receive
        (`#(eval_result ,ref ,result) result)
        (after
          timeout
          (erlang:exit worker 'kill)
          '#(error timeout))))))

(defun try-catch-value (form env)
  ;;; Normal path builds #(ok value); a throw delivers #(EXIT reason)
  ;;; instead -- normalized so callers always see #(ok V) | #(error R).
  (let ((result (catch `#(ok ,(lfe_eval:expr form env)))))
    (case result
      (`#(ok ,value) `#(ok ,value))
      (`#(EXIT ,reason) `#(error ,reason)))))
