(in-package #:nyaa)

;;; Shell tool: one command through `sh -c`, merged output, bounded by a
;;; caller deadline. The deadline kills the command's whole process group
;;; (see process.lisp), so a backgrounded descendant is signalled too.
;;;
;;; Trust posture: arbitrary command execution. Trusted operator only.

(define-tool :tool-shell
    (:trust :operator
     :summary "Run a shell command (sh -c) and capture merged output"
     :params ((:cmd string :required t :doc "command string to run")
              (:timeout (integer 1) :default +default-tool-timeout+
               :doc "kill the command after this many milliseconds")))
  (:invoke (cmd timeout)
    (run-command cmd timeout)))

(defun run-command (cmd timeout-ms)
  (let* ((process (launch-in-process-group (list "/bin/sh" "-c" cmd)
                                           :output :stream
                                           :error-output :output))
         (done (bt:make-semaphore))
         (output nil))
    ;; Drain concurrently: a command that outruns the pipe buffer would
    ;; otherwise block on write while we block waiting for it to exit.
    (bt:make-thread
     (lambda ()
       (unwind-protect
            (setf output (uiop:slurp-stream-string
                          (uiop:process-info-output process)))
         (bt:signal-semaphore done)))
     :name "nyaa-shell-drain")
    (if (bt:wait-on-semaphore done :timeout (/ timeout-ms 1000))
        (ok :exit (uiop:wait-process process) :out (or output ""))
        (progn
          ;; Killing the whole group closes the pipe, which ends the drain
          ;; thread on its own -- true even when a backgrounded descendant
          ;; held the write end open, since it dies with the group too.
          (terminate-process-group process)
          (fail :timeout)))))
