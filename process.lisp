(in-package #:nyaa)

;;; A subprocess launched in its own process group, so a deadline can signal
;;; everything it spawned rather than the direct child alone. Shared by
;;; `run-command` (tools/shell.lisp) and the worker launch/kill pair
;;; (worker.lisp) -- one helper instead of two copies of the same trick.
;;;
;;; macOS has no `setsid`, so the group is set on the spawn path instead: a
;;; `perl -e 'setpgrp; exec @ARGV'` wrapper makes the child its own group
;;; leader (group id == pid) before it execs the real command. The kill then
;;; signals `-<pid>` -- the whole group -- ahead of the existing
;;; leader-only `uiop:terminate-process`.
;;;
;;; Without perl on PATH, launch and kill fall back to today's behaviour:
;;; the direct child only. A backgrounded grandchild then still outlives the
;;; kill, exactly as before this ticket. Tracked in ~takeiteasy/nyaa#54.

(defparameter *process-group-wrapper*
  (let ((perl (ignore-errors (uiop:run-program '("command" "-v" "perl")
                                               :output '(:string :stripped t)
                                               :ignore-error-status t))))
    (when (and perl (plusp (length perl)))
      (list perl "-e" "setpgrp; exec @ARGV")))
  "Argv prefix that makes a launched command lead its own process group, or
NIL when perl is not on PATH. Resolved once, at load time.")

(defun launch-in-process-group (argv &rest keys &key &allow-other-keys)
  "UIOP:LAUNCH-PROGRAM on ARGV, prefixed with *PROCESS-GROUP-WRAPPER* when
one is available, so the child leads its own process group."
  (apply #'uiop:launch-program
         (append *process-group-wrapper* argv)
         keys))

(defun terminate-process-group (process)
  "Signal PROCESS's whole process group, then reap the leader. When
*PROCESS-GROUP-WRAPPER* ran, the leader's pid is the group id; the group
kill is best-effort and ignored on failure, since the leader-only
TERMINATE-PROCESS below always follows it."
  (when *process-group-wrapper*
    (ignore-errors
     (uiop:run-program (list "/bin/kill" "-9"
                             (format nil "-~d" (uiop:process-info-pid process)))
                       :ignore-error-status t)))
  (ignore-errors (uiop:terminate-process process :urgent t))
  (ignore-errors (uiop:wait-process process)))
