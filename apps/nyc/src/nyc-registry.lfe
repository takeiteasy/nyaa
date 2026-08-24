(defmodule nyc-registry
  (behaviour gen_server)
  (export
    ;; client API
    (start_link 0)
    (register 3)
    (unregister 1)
    (lookup 1)
    (await 2)
    (subscribe 1)
    (unsubscribe 1)
    (names 0))
  (export
    ;; gen_server callbacks
    (init 1)
    (handle_call 3)
    (handle_cast 2)
    (handle_info 2)
    (terminate 2)
    (code_change 3)))

;;; The service registry: the piece that lets a plugin be mounted before
;;; its dependency exists, and be told about it when it appears.
;;;
;;; This is a hand-rolled gen_server rather than a pull of gproc, so the
;;; core stays at zero non-OTP dependencies -- consistent with the
;;; project's "BEAM-native" thesis. Everything here is reached only
;;; through the client API below, so a gproc-backed implementation could
;;; be swapped in later without touching callers.
;;;
;;; Notification protocol sent to subscribers:
;;;   #(nyc-registry registered   Name Pid)
;;;   #(nyc-registry unregistered Name Reason)
;;;
;;; `subscribe` is atomic with respect to an existing registration: if
;;; `Name` is already registered at the moment of subscribing, the
;;; subscriber is sent a `registered` message immediately, before
;;; `subscribe` returns. This removes the lookup-then-subscribe race by
;;; construction -- callers (see nyc-service) never need to call
;;; `lookup` themselves.
;;;
;;; `await` owns its own timeout server-side via `erlang:start_timer/3`
;;; rather than relying on the caller's `gen_server:call` timeout. If
;;; the client timeout fired instead, a name that registers after the
;;; client gave up would still find a stale `From` sitting in `waiters`
;;; forever, and the server would try to reply into a caller that's no
;;; longer listening. Client calls are made with `infinity` -- the
;;; server-side timer is what actually bounds the wait.

;;; ------------------------------------------------------------------
;;; Client API
;;; ------------------------------------------------------------------

(defun start_link ()
  (gen_server:start_link `#(local nyc-registry) 'nyc-registry '() '()))

(defun register (name pid props)
  (gen_server:call 'nyc-registry `#(register ,name ,pid ,props)))

(defun unregister (name)
  (gen_server:call 'nyc-registry `#(unregister ,name)))

(defun lookup (name)
  (gen_server:call 'nyc-registry `#(lookup ,name)))

(defun await (name timeout)
  (gen_server:call 'nyc-registry `#(await ,name ,timeout) 'infinity))

(defun subscribe (name)
  (gen_server:call 'nyc-registry `#(subscribe ,name ,(self))))

(defun unsubscribe (name)
  (gen_server:call 'nyc-registry `#(unsubscribe ,name ,(self))))

(defun names ()
  (gen_server:call 'nyc-registry 'names))

;;; ------------------------------------------------------------------
;;; State
;;; ------------------------------------------------------------------
;;;
;;; regs             :: #{Name => #(Pid Props)}
;;; reg-mon          :: #{Name => MonRef}          -- monitor on a registered pid
;;; mon-reg          :: #{MonRef => Name}          -- reverse, for DOWN handling
;;; waiters          :: #{Name => [#(From TimerRef CallerMonRef)]}
;;; timer-waiter     :: #{TimerRef => #(Name From)}
;;; callermon-waiter :: #{CallerMonRef => #(Name From TimerRef)}
;;; subs             :: #{Name => ordsets(Pid)}
;;; sub-mon          :: #{Pid => MonRef}           -- one monitor per subscriber
;;; mon-sub          :: #{MonRef => Pid}           -- reverse, for DOWN handling

(defun new-state ()
  #m(regs #m()
     reg-mon #m()
     mon-reg #m()
     waiters #m()
     timer-waiter #m()
     callermon-waiter #m()
     subs #m()
     sub-mon #m()
     mon-sub #m()))

;;; ------------------------------------------------------------------
;;; gen_server callbacks
;;; ------------------------------------------------------------------

(defun init (_args)
  `#(ok ,(new-state)))

(defun handle_call
  ((`#(register ,name ,pid ,props) _from state)
    (do-register name pid props state))
  ((`#(unregister ,name) _from state)
    (do-unregister name 'unregistered state))
  ((`#(lookup ,name) _from state)
    `#(reply ,(do-lookup name state) ,state))
  ((`#(await ,name ,timeout) from state)
    (do-await name timeout from state))
  ((`#(subscribe ,name ,pid) _from state)
    `#(reply ok ,(do-subscribe name pid state)))
  ((`#(unsubscribe ,name ,pid) _from state)
    `#(reply ok ,(do-unsubscribe name pid state)))
  (('names _from state)
    `#(reply ,(maps:keys (sref state 'regs)) ,state)))

(defun handle_cast (_msg state)
  `#(noreply ,state))

;;; The DOWN tag can't be matched as a literal in the pattern head the
;;; way lowercase atoms can: LFE (like Erlang) reads an uppercase-led
;;; bareword as a pattern *variable*, so `DOWN` in a pattern silently
;;; binds rather than matches, and even a quoted `'DOWN` doesn't fix it
;;; -- both were tried and confirmed not to match against a real DOWN
;;; message. Binding the tag generically and guarding on it does work.
(defun handle_info
  ((`#(,tag ,mon process ,_pid ,reason) state) (when (=:= tag 'DOWN))
    (handle-down mon reason state))
  ((`#(timeout ,timer-ref timeout) state)
    (handle-waiter-timeout timer-ref state))
  ((_msg state)
    `#(noreply ,state)))

(defun terminate (_reason _state) 'ok)
(defun code_change (_old-vsn state _extra) `#(ok ,state))

;;; ------------------------------------------------------------------
;;; register / unregister / lookup
;;; ------------------------------------------------------------------

(defun do-register (name pid props state)
  (case (maps:find name (sref state 'regs))
    (`#(ok #(,existing-pid ,_))
      (if (erlang:is_process_alive existing-pid)
        `#(reply #(error #(already-registered ,existing-pid)) ,state)
        (do-register-fresh name pid props state)))
    ('error
      (do-register-fresh name pid props state))))

(defun do-register-fresh (name pid props state)
  ;; drop-registration first: if `name` is being re-registered (a dead
  ;; pid's replacement raced ahead of that pid's own DOWN -- e.g. a
  ;; supervisor restart completing before the registry got around to
  ;; processing the old monitor), this clears the OLD monitor's
  ;; reg-mon/mon-reg entries before the new ones go in. Without it,
  ;; mon-reg[OldMonRef] survives pointing at `name`; when the old DOWN
  ;; eventually arrives, handle-down matches on that stale ref, looks up
  ;; regs[name] (now the live NEW registration), and tears it down --
  ;; broadcasting `unregistered` for a process that's still alive.
  ;; demonitor(_, [flush]) also drops an already-queued DOWN from this
  ;; process's own mailbox, so this is correct regardless of which
  ;; arrives first, not just correct when DOWN happens to win the race.
  (let* ((state (drop-registration name state))
         (mon (erlang:monitor 'process pid))
         (state (sput state 'regs (maps:put name `#(,pid ,props) (sref state 'regs))))
         (state (sput state 'reg-mon (maps:put name mon (sref state 'reg-mon))))
         (state (sput state 'mon-reg (maps:put mon name (sref state 'mon-reg))))
         (state (reply-waiters name pid state))
         (state (notify-subs name `#(nyc-registry registered ,name ,pid) state)))
    `#(reply ok ,state)))

(defun do-unregister (name reason state)
  (case (maps:find name (sref state 'regs))
    ('error `#(reply ok ,state))
    (`#(ok #(,pid ,_))
      (let* ((state (drop-registration name state))
             (state (notify-subs name `#(nyc-registry unregistered ,name ,reason) state)))
        `#(reply ok ,state)))))

(defun drop-registration (name state)
  (let* ((mon (maps:get name (sref state 'reg-mon) 'undefined))
         (_ (if (=/= mon 'undefined) (erlang:demonitor mon '(flush))))
         (state (sput state 'regs (maps:remove name (sref state 'regs))))
         (state (sput state 'reg-mon (maps:remove name (sref state 'reg-mon))))
         (state (sput state 'mon-reg
                  (if (=/= mon 'undefined)
                    (maps:remove mon (sref state 'mon-reg))
                    (sref state 'mon-reg)))))
    state))

(defun do-lookup (name state)
  (case (maps:find name (sref state 'regs))
    (`#(ok ,entry) `#(ok ,entry))
    ('error '#(error not-found))))

;;; ------------------------------------------------------------------
;;; await (server-owned timeout)
;;; ------------------------------------------------------------------

(defun do-await (name timeout from state)
  (case (maps:find name (sref state 'regs))
    (`#(ok #(,pid ,_)) `#(reply #(ok ,pid) ,state))
    ('error
      (let* ((timer-ref (erlang:start_timer timeout (self) 'timeout))
             (`#(,caller-pid ,_) from)
             (caller-mon (erlang:monitor 'process caller-pid))
             (entry `#(,from ,timer-ref ,caller-mon))
             (existing (maps:get name (sref state 'waiters) '()))
             (state (sput state 'waiters (maps:put name (cons entry existing) (sref state 'waiters))))
             (state (sput state 'timer-waiter (maps:put timer-ref `#(,name ,from) (sref state 'timer-waiter))))
             (state (sput state 'callermon-waiter (maps:put caller-mon `#(,name ,from ,timer-ref) (sref state 'callermon-waiter)))))
        `#(noreply ,state)))))

(defun reply-waiters (name pid state)
  (let ((entries (maps:get name (sref state 'waiters) '())))
    (lists:foldl
      (match-lambda
        ((`#(,from ,timer-ref ,caller-mon) acc)
          (erlang:cancel_timer timer-ref)
          (erlang:demonitor caller-mon '(flush))
          (gen_server:reply from `#(ok ,pid))
          (let* ((acc (sput acc 'timer-waiter (maps:remove timer-ref (sref acc 'timer-waiter))))
                 (acc (sput acc 'callermon-waiter (maps:remove caller-mon (sref acc 'callermon-waiter)))))
            acc)))
      (sput state 'waiters (maps:remove name (sref state 'waiters)))
      entries)))

(defun handle-waiter-timeout (timer-ref state)
  (case (maps:find timer-ref (sref state 'timer-waiter))
    ('error `#(noreply ,state))
    (`#(ok #(,name ,from))
      (gen_server:reply from '#(error timeout))
      `#(noreply ,(drop-waiter name from timer-ref state)))))

(defun drop-waiter (name from timer-ref state)
  (let* ((remaining
           (lists:filter
             (match-lambda
               ((`#(,f ,_ ,_)) (=/= f from)))
             (maps:get name (sref state 'waiters) '())))
         (removed
           (lists:filter
             (match-lambda
               ((`#(,f ,_ ,_)) (=:= f from)))
             (maps:get name (sref state 'waiters) '())))
         (state (sput state 'waiters
                  (if (=:= remaining '())
                    (maps:remove name (sref state 'waiters))
                    (maps:put name remaining (sref state 'waiters)))))
         (state (sput state 'timer-waiter (maps:remove timer-ref (sref state 'timer-waiter)))))
    (lists:foldl
      (match-lambda
        ((`#(,_ ,_ ,caller-mon) acc)
          (erlang:demonitor caller-mon '(flush))
          (sput acc 'callermon-waiter (maps:remove caller-mon (sref acc 'callermon-waiter)))))
      state
      removed)))

;;; ------------------------------------------------------------------
;;; subscribe / unsubscribe
;;; ------------------------------------------------------------------

(defun do-subscribe (name pid state)
  (let* ((current (maps:get name (sref state 'subs) (sets:new())))
         (state
           (if (sets:is_element pid current)
             state
             (let ((state (sput state 'subs (maps:put name (sets:add_element pid current) (sref state 'subs)))))
               (ensure-sub-monitor pid state)))))
    (case (maps:find name (sref state 'regs))
      (`#(ok #(,reg-pid ,_))
        (erlang:send pid `#(nyc-registry registered ,name ,reg-pid))
        state)
      ('error state))))

(defun ensure-sub-monitor (pid state)
  (case (maps:find pid (sref state 'sub-mon))
    (`#(ok ,_) state)
    ('error
      (let* ((mon (erlang:monitor 'process pid))
             (state (sput state 'sub-mon (maps:put pid mon (sref state 'sub-mon))))
             (state (sput state 'mon-sub (maps:put mon pid (sref state 'mon-sub)))))
        state))))

(defun do-unsubscribe (name pid state)
  (let ((current (maps:get name (sref state 'subs) 'undefined)))
    (if (=:= current 'undefined)
      state
      (let* ((updated (sets:del_element pid current))
             (state
               (if (=:= (sets:size updated) 0)
                 (sput state 'subs (maps:remove name (sref state 'subs)))
                 (sput state 'subs (maps:put name updated (sref state 'subs))))))
        (maybe-drop-sub-monitor pid state)))))

(defun still-subscribed? (pid state)
  (maps:fold
    (match-lambda
      ((_name pids 'true) 'true)
      ((_name pids 'false) (sets:is_element pid pids)))
    'false
    (sref state 'subs)))

(defun maybe-drop-sub-monitor (pid state)
  (if (still-subscribed? pid state)
    state
    (case (maps:find pid (sref state 'sub-mon))
      ('error state)
      (`#(ok ,mon)
        (erlang:demonitor mon '(flush))
        (let* ((state (sput state 'sub-mon (maps:remove pid (sref state 'sub-mon))))
               (state (sput state 'mon-sub (maps:remove mon (sref state 'mon-sub)))))
          state)))))

(defun notify-subs (name msg state)
  (let ((pids (sets:to_list (maps:get name (sref state 'subs) (sets:new())))))
    (lists:foreach (lambda (pid) (erlang:send pid msg)) pids)
    state))

(defun drop-all-subs-for (pid state)
  (let* ((names (maps:keys (sref state 'subs)))
         (state
           (lists:foldl
             (lambda (name acc)
               (let ((current (maps:get name (sref acc 'subs) 'undefined)))
                 (if (=:= current 'undefined)
                   acc
                   (let ((updated (sets:del_element pid current)))
                     (if (=:= (sets:size updated) 0)
                       (sput acc 'subs (maps:remove name (sref acc 'subs)))
                       (sput acc 'subs (maps:put name updated (sref acc 'subs))))))))
             state
             names))
         (state (sput state 'sub-mon (maps:remove pid (sref state 'sub-mon)))))
    state))

;;; ------------------------------------------------------------------
;;; DOWN handling -- registered pids, waiting callers, and subscribers
;;; all share the same monitor-message stream, disambiguated by which
;;; reverse-index map the ref shows up in.
;;; ------------------------------------------------------------------

(defun handle-down (mon reason state)
  (cond
    ((maps:is_key mon (sref state 'mon-reg))
      (let* ((name (maps:get mon (sref state 'mon-reg)))
             (`#(ok #(,_pid ,_props)) (maps:find name (sref state 'regs)))
             (state (sput state 'regs (maps:remove name (sref state 'regs))))
             (state (sput state 'reg-mon (maps:remove name (sref state 'reg-mon))))
             (state (sput state 'mon-reg (maps:remove mon (sref state 'mon-reg))))
             (state (notify-subs name `#(nyc-registry unregistered ,name ,reason) state)))
        `#(noreply ,state)))
    ((maps:is_key mon (sref state 'mon-sub))
      (let* ((pid (maps:get mon (sref state 'mon-sub)))
             (state (sput state 'mon-sub (maps:remove mon (sref state 'mon-sub))))
             (state (drop-all-subs-for pid state)))
        `#(noreply ,state)))
    ((maps:is_key mon (sref state 'callermon-waiter))
      (let* ((`#(,name ,from ,timer-ref) (maps:get mon (sref state 'callermon-waiter)))
             (_ (erlang:cancel_timer timer-ref))
             (state (sput state 'timer-waiter (maps:remove timer-ref (sref state 'timer-waiter))))
             (state (sput state 'callermon-waiter (maps:remove mon (sref state 'callermon-waiter))))
             (state
               (sput state 'waiters
                 (let ((remaining
                         (lists:filter
                           (match-lambda ((`#(,f ,_ ,_)) (=/= f from)))
                           (maps:get name (sref state 'waiters) '()))))
                   (if (=:= remaining '())
                     (maps:remove name (sref state 'waiters))
                     (maps:put name remaining (sref state 'waiters)))))))
        `#(noreply ,state)))
    ('true `#(noreply ,state))))

;;; ------------------------------------------------------------------
;;; tiny map helpers -- LFE has no built-in mref/mset for maps beyond
;;; the #m() / #M() literal syntax, so these keep the code above legible
;;; ------------------------------------------------------------------

(defun sref (state key) (maps:get key state))
(defun sput (state key val) (maps:put key val state))
