(defmodule nyaa-tool-shell
  (export
    (child_spec 0)
    (service_name 0)
    (dependencies 0)
    (metadata 0)
    (init 1)
    (handle_message 2)
    (terminate 2)))

;;; Standard tool plugin: shell. Runs a command string through `sh -c`
;;; on a port, captures stdout/stderr (merged), and enforces a caller
;;; timeout -- a hung command gets its port closed and returns
;;; #(error timeout) instead of wedging either the caller or this
;;; service. Part of the tool/skill convention (see docs/tools.md):
;;; registers as 'tool-shell, answers #(describe) and #(invoke ...).
;;;
;;; Trust posture: arbitrary command execution on the node. Trusted
;;; operator only -- see docs/getting-started.md, "Security & trust".

(defun child_spec ()
  `#m(id tool-shell
      start #(patchbay_service start_link (nyaa-tool-shell #m()))
      restart transient
      shutdown 5000
      type worker
      modules (patchbay_service)))

(defun service_name () 'tool-shell)
(defun dependencies () '())

(defun metadata ()
  ;;; Published as registration props (patchbay_service metadata/0);
  ;;; this is what makes the tool discoverable via kind=tool.
  (describe))

(defun init (_args) `#(ok #m()))

(defun describe ()
  #m(kind tool
     name 'tool-shell
     summary #"Run a shell command (sh -c) and capture merged output"
     params #m(cmd "command string to run, binary (required)"
               timeout "kill the command after this many ms (default 30000)")))

(defun handle_message
  (('describe state) `#(reply ,(describe) ,state))
  ((`#(invoke ,req) state)
   (case (maps:find 'cmd req)
     (`#(ok ,cmd) (when (orelse (is_binary cmd) (is_list cmd)))
      (let ((timeout (maps:get 'timeout req 30000)))
        `#(reply ,(run cmd timeout) ,state)))
     (_ `#(reply #(error #(bad_request "cmd must be a string or binary"))
                ,state)))))

(defun terminate (_reason _state) 'ok)

;;; --- implementation -------------------------------------------------

;; LFE string literals are char lists; model-supplied args may well be
;; binaries. Accept both everywhere.
(defun acceptable-string (v)
  (orelse (is_list v) (is_binary v)))

(defun arg->list (v)
  (if (is_binary v) (binary_to_list v) v))

(defun run (cmd timeout)
  (let ((port (open_port '#(spawn_executable "/bin/sh")
                         `(binary exit_status
                           #(args ("-c" ,(arg->list cmd)))))))
    (collect port (+ (erlang:monotonic_time 'milli_seconds) timeout) '())))

(defun collect (port deadline acc)
  (cond
    ;; deadline passed: give up, close the port. Note the OS child of a
    ;; closed port isn't guaranteed to die instantly -- we just stop
    ;; waiting for it and report timeout to the caller.
    ((>= (erlang:monotonic_time 'milli_seconds) deadline)
     (kill-port port)
     '#(error timeout))
    ('true
     (receive
       (`#(,port #(data ,chunk))
        (when (is_binary chunk))
        ;; acc is a chunk list (reversed); iolist_to_binary flattens.
        (collect port deadline (cons chunk acc)))
       (`#(,port #(exit_status ,status))
        `#(ok #m(exit ,status out ,(iolist_to_binary (lists:reverse acc)))))
       (`#(EXIT ,port ,_reason)
        '#(error port_died))
       (_msg
        (collect port deadline acc))
       (after
         ;; never sit in receive past the deadline:
         (- deadline (erlang:monotonic_time 'milli_seconds))
         (kill-port port)
         '#(error timeout))))))

(defun kill-port (port)
  (catch (erlang:port_close port))
  'ok)
