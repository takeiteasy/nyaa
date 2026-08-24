(defmodule nyc-service
  (behaviour gen_server)
  (export
    (start_link 2)
    (call-service 2)
    (cast 2))
  (export
    (init 1)
    (handle_call 3)
    (handle_cast 2)
    (handle_info 2)
    (terminate 2)
    (code_change 3)))

;;; Wraps a callback module in a gen_server that handles registry
;;; registration and dependency-waiting once, so individual plugins
;;; don't reimplement it. See docs/plugins.md for the full callback
;;; contract; the short version:
;;;
;;;   (service-name)                -> atom                    [required]
;;;   (dependencies)                -> (list-of atom)           [required]
;;;   (init Args)                   -> #(ok State)              [required]
;;;   (ready Deps State)            -> #(ok State)               [optional]
;;;   (dep-down Name Reason State)  -> #(ok State)                [optional]
;;;   (handle-message Msg State)    -> #(ok State) | #(reply R State) [optional]
;;;   (terminate Reason State)      -> ok                        [optional]
;;;
;;; Missing optional callbacks default to no-ops, checked with
;;; erlang:function_exported/3 so a trivial plugin only writes
;;; service-name, dependencies, and init.
;;;
;;; Dependency waiting: init/1 subscribes to every declared dependency
;;; via nyc-registry:subscribe/1 and does NOT call lookup first --
;;; nyc-registry's subscribe replays an existing registration
;;; immediately (see nyc-registry.lfe), so this is race-free by
;;; construction and never blocks the supervisor start.
;;;
;;; terminate/2 is the plugin's disposer: the callback's own terminate/2
;;; runs first, then this module unregisters the service from
;;; nyc-registry (see docs/plugins.md).

;;; ------------------------------------------------------------------
;;; Client API
;;; ------------------------------------------------------------------

(defun start_link (mod args)
  (gen_server:start_link 'nyc-service `#(,mod ,args) '()))

(defun call-service (name msg)
  (case (nyc-registry:lookup name)
    (`#(ok #(,pid ,_props)) (gen_server:call pid `#(msg ,msg)))
    (`#(error not-found) '#(error not-found))))

(defun cast (name msg)
  (case (nyc-registry:lookup name)
    (`#(ok #(,pid ,_props)) (gen_server:cast pid `#(msg ,msg)))
    (`#(error not-found) '#(error not-found))))

;;; ------------------------------------------------------------------
;;; gen_server callbacks
;;; ------------------------------------------------------------------

(defun init
  ((`#(,mod ,args))
    ;; A plain gen_server does not trap exits, so a supervisor's ordinary
    ;; shutdown -- exit(Pid, shutdown) via supervisor:terminate_child --
    ;; would kill this process outright without ever calling terminate/2,
    ;; silently skipping the callback's disposer and the registry
    ;; unregister below. Trapping exits is what makes terminate/2 (and
    ;; therefore the plugin's disposer) actually fire on nyc-context:unmount.
    (erlang:process_flag 'trap_exit 'true)
    (let* ((name (dispatch mod 'service-name ()))
           (deps (dispatch mod 'dependencies ()))
           (`#(ok ,cbstate) (mod-init mod args))
           (state `#m(mod ,mod
                      name ,name
                      deps ,deps
                      ready #m()
                      status waiting
                      cbstate ,cbstate)))
      (nyc-registry:register name (self) #m())
      ;; Subscribing (not looking up) is what makes this race-free: a
      ;; dependency already registered is replayed to us immediately by
      ;; nyc-registry, so the zero-deps and already-satisfied-deps cases
      ;; both fall out of the same maybe-transition-ready call below,
      ;; whether or not any #(nyc-registry registered ...) message ever
      ;; needs to arrive.
      (lists:foreach (lambda (dep) (nyc-registry:subscribe dep)) deps)
      `#(ok ,(maybe-transition-ready state)))))

(defun handle_call
  ((`#(msg ,msg) _from state)
    (let* ((mod (maps:get 'mod state))
           (cbstate (maps:get 'cbstate state)))
      (case (call-handle-message mod msg cbstate)
        (`#(reply ,r ,cbstate2) `#(reply ,r ,(set-cbstate state cbstate2)))
        (`#(ok ,cbstate2) `#(reply ok ,(set-cbstate state cbstate2)))))))

(defun handle_cast (_msg state) `#(noreply ,state))

(defun handle_info
  ((`#(nyc-registry registered ,dep-name ,pid) state)
    (handle-dep-registered dep-name pid state))
  ((`#(nyc-registry unregistered ,dep-name ,reason) state)
    (handle-dep-unregistered dep-name reason state))
  ((_msg state) `#(noreply ,state)))

(defun terminate (reason state)
  (call-terminate (maps:get 'mod state) reason (maps:get 'cbstate state))
  (nyc-registry:unregister (maps:get 'name state))
  'ok)

(defun code_change (_old-vsn state _extra) `#(ok ,state))

;;; ------------------------------------------------------------------
;;; dependency lifecycle
;;; ------------------------------------------------------------------

(defun handle-dep-registered (dep-name pid state)
  (let ((deps (maps:get 'deps state)))
    (if (lists:member dep-name deps)
      (let* ((ready (maps:put dep-name pid (maps:get 'ready state)))
             (state (maps:put 'ready ready state))
             (state (maybe-transition-ready state)))
        `#(noreply ,state))
      `#(noreply ,state))))

(defun handle-dep-unregistered (dep-name reason state)
  (let ((deps (maps:get 'deps state)))
    (if (lists:member dep-name deps)
      (let* ((was-ready (=:= (maps:get 'status state) 'ready))
             (ready (maps:remove dep-name (maps:get 'ready state)))
             (state (maps:put 'ready ready state))
             (state (maps:put 'status 'waiting state)))
        (if was-ready
          `#(noreply ,(transition-dep-down dep-name reason state))
          `#(noreply ,state)))
      `#(noreply ,state))))

(defun all-deps-ready? (deps ready)
  (lists:all (lambda (d) (maps:is_key d ready)) deps))

;;; Called both from init/1 (covers the zero-dependency case, which no
;;; #(nyc-registry registered ...) message would ever trigger) and from
;;; handle-dep-registered (covers the normal case). Idempotent: a no-op
;;; once status is already 'ready.
(defun maybe-transition-ready (state)
  (let ((deps (maps:get 'deps state))
        (ready (maps:get 'ready state)))
    (if (and (all-deps-ready? deps ready) (=/= (maps:get 'status state) 'ready))
      (let* ((mod (maps:get 'mod state))
             (`#(ok ,cbstate) (call-ready mod ready (maps:get 'cbstate state)))
             (state (maps:put 'status 'ready state)))
        (maps:put 'cbstate cbstate state))
      state)))

(defun transition-dep-down (dep-name reason state)
  (let* ((mod (maps:get 'mod state))
         (`#(ok ,cbstate) (call-dep-down mod dep-name reason (maps:get 'cbstate state))))
    (maps:put 'cbstate cbstate state)))

;;; ------------------------------------------------------------------
;;; optional-callback dispatch
;;; ------------------------------------------------------------------

(defun mod-init (mod args) (dispatch mod 'init (list args)))

(defun call-ready (mod deps cbstate)
  (if (erlang:function_exported mod 'ready 2)
    (dispatch mod 'ready (list deps cbstate))
    `#(ok ,cbstate)))

(defun call-dep-down (mod dep-name reason cbstate)
  (if (erlang:function_exported mod 'dep-down 3)
    (dispatch mod 'dep-down (list dep-name reason cbstate))
    `#(ok ,cbstate)))

(defun call-handle-message (mod msg cbstate)
  (if (erlang:function_exported mod 'handle-message 2)
    (dispatch mod 'handle-message (list msg cbstate))
    `#(ok ,cbstate)))

(defun call-terminate (mod reason cbstate)
  (if (erlang:function_exported mod 'terminate 2)
    (dispatch mod 'terminate (list reason cbstate))
    'ok))

(defun set-cbstate (state cbstate) (maps:put 'cbstate cbstate state))

(defun dispatch (mod fun args)
  (erlang:apply mod fun args))
