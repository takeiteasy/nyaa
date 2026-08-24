(defmodule nyc-agent
  (behaviour gen_server)
  (export
    (start_link 1)
    (prompt 2)
    (prompt-wait 2))
  (export
    (init 1)
    (handle_call 3)
    (handle_cast 2)
    (handle_info 2)
    (terminate 2)
    (code_change 3)))

;;; One delegated sub-agent. Wraps a callback module in a gen_server --
;;; the same optional-callback style as nyc-service, minus the
;;; dependency machinery. The callback contract:
;;;
;;;   (agent-name)                -> atom                     [required]
;;;   (init Args)                 -> #(ok State)              [required]
;;;   (handle-message Msg State)  -> #(ok State) | #(reply R State)
;;;                              | #(done Result State)       [optional]
;;;   (terminate Reason State)    -> ok                        [optional]
;;;
;;; See docs/delegation.md for the full contract, including why a cast
;;; drops #(reply R State) on the floor (there is no caller to reply
;;; to -- a sub-agent that wants to talk back during a cast sends a
;;; message itself).
;;;
;;; Returning #(done Result State2) from handle-message is how a
;;; sub-agent "decides it is done": nyc-agent sends the tagged message
;;;
;;;   #(nyc-agent done <ref> <pid> <result>)
;;;
;;; to its parent and stops normally, on both the cast and call paths.
;;; The ref was supplied by the parent at delegate time so concurrent
;;; delegations are matchable.
;;;
;;; Crash isolation is structural: this process runs under its
;;; nyc-agent-sup as a `temporary` child, so a crashing sub-agent is
;;; simply gone -- it never takes the parent down and is not
;;; restarted. nyc-agent-sup:delegate/5 monitors the child from the
;;; parent process, so a crash also arrives as an ordinary `DOWN`.
;;;
;;; Registration in nyc-registry is opt-in: pass #m(name some-atom) as
;;; opts to be discoverable under that name for the agent's lifetime;
;;; omit `name` (or pass #m()) to stay unregistered, which is the
;;; default for what is fundamentally an ephemeral task, not a
;;; service. A duplicate name fails the start loudly (registry returns
;;; #(error ...), which init/1 turns into #(stop Reason)) rather than
;;; silently colliding with a sibling agent.
;;;
;;; The single start argument is:
;;;   #(mod cbargs ref parent opts)

;;; ------------------------------------------------------------------
;;; Client API
;;; ------------------------------------------------------------------

(defun start_link (child-args)
  (gen_server:start_link 'nyc-agent child-args '()))

;;; Fire-and-forget prompt.
(defun prompt (pid msg) (gen_server:cast pid `#(msg ,msg)))

;;; Blocking prompt; the reply comes from #(reply R State), or `ok` on
;;; #(ok State2) / the done path.
(defun prompt-wait (pid msg) (gen_server:call pid `#(msg ,msg)))

;;; ------------------------------------------------------------------
;;; gen_server callbacks
;;; ------------------------------------------------------------------

(defun init
  ((`#(,mod ,cbargs ,ref ,parent ,opts))
   ;; Trap exits so supervisor shutdown reaches terminate/2 (the
   ;; disposer) instead of killing us outright -- same reason as
   ;; nyc-service's init/1.
    (erlang:process_flag 'trap_exit 'true)
    (let* ((`#(ok ,cbstate) (erlang:apply mod 'init (list cbargs)))
           (state `#m(mod ,mod
                       name undefined
                       ref ,ref
                       parent ,parent
                       cbstate ,cbstate)))
      (case (maps:find 'name opts)
        (`#(ok ,name)
          (case (nyc-registry:register name (self) #m())
            ('ok `#(ok ,(maps:put 'name name state)))
            (`#(error ,reason) `#(stop ,reason))))
        ('error `#(ok ,state))))))

(defun handle_call
  ((`#(msg ,msg) _from state)
    (let* ((mod (maps:get 'mod state))
           (result (call-handle-message mod msg state)))
      (match-result result state))))

(defun handle_cast
  ((`#(msg ,msg) state)
    (let ((mod (maps:get 'mod state)))
      (case (call-handle-message mod msg state)
        (`#(done ,result ,cbstate2)
         ;; Fire-and-forget done: send the tagged message now; the
         ;; normal stop below still runs terminate/2 (the disposer).
          `#(stop normal ,(send-done (set-cbstate state cbstate2) result)))
        (`#(reply ,_r ,cbstate2) `#(noreply ,(set-cbstate state cbstate2)))
        (`#(ok ,cbstate2) `#(noreply ,(set-cbstate state cbstate2)))))))

(defun handle_info (_msg state) `#(noreply ,state))

(defun terminate (reason state)
  (let ((mod (maps:get 'mod state)))
    (if (erlang:function_exported mod 'terminate 2)
      (progn
        (erlang:apply mod 'terminate (list reason (maps:get 'cbstate state)))
        'ok)
      'ok))
  ;; Unregister last, after the disposer has run -- same order as
  ;; nyc-service, so a dying agent can notify anyone as its last act.
  ;; Only unregistered if a name was actually claimed at init time.
  (case (maps:get 'name state)
    ('undefined 'ok)
    (name (nyc-registry:unregister name)))
  'ok)

(defun code_change (_old-vsn state _extra) `#(ok ,state))

;;; ------------------------------------------------------------------
;;; internals
;;; ------------------------------------------------------------------

(defun call-handle-message (mod msg state)
  (if (erlang:function_exported mod 'handle-message 2)
    (erlang:apply mod 'handle-message (list msg (maps:get 'cbstate state)))
    ;; Optional-callback default: a no-op that keeps the agent alive.
    `#(ok ,(maps:get 'cbstate state))))

;;; Call-path return shaping: on #(reply R State2) reply R; on
;;; #(ok State2) reply ok; on #(done Result State2) send the tagged
;;; done message to the parent, reply ok, and stop normally.
(defun match-result
  ((`#(reply ,r ,cbstate2) state) `#(reply ,r ,(set-cbstate state cbstate2)))
  ((`#(done ,result ,cbstate2) state)
    `#(stop normal ok ,(send-done (set-cbstate state cbstate2) result)))
  ((`#(ok ,cbstate2) state) `#(reply ok ,(set-cbstate state cbstate2))))

(defun set-cbstate (state cbstate2) (maps:put 'cbstate cbstate2 state))

(defun send-done (state result)
  (erlang:send (maps:get 'parent state)
               `#(nyc-agent done ,(maps:get 'ref state) ,(self) ,result))
  state)
