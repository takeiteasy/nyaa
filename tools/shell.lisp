(in-package #:nyaa)

;;; Shell tool: one command through `sh -c`, merged output, bounded by a
;;; caller deadline.
;;;
;;; Trust posture: arbitrary command execution. Trusted operator only.
;;;
;;; TODO: the deadline kills the direct `sh` child only, so a backgrounded
;;; descendant outlives it. Upgrade path: start the command in its own
;;; process group and signal the group. Tracked in ~takeiteasy/nyaa#16.

(m:defservice tool-shell () ()
  (:name :tool-shell))

(defmethod m:metadata ((service tool-shell))
  (list :kind :tool
        :name :tool-shell
        :trust :operator
        :summary "Run a shell command (sh -c) and capture merged output"
        :params `((:cmd string :required t :doc "command string to run")
                  (:timeout (integer 1) :default ,+default-tool-timeout+
                   :doc "kill the command after this many milliseconds"))))

(define-tool-handler tool-shell (service args)
  (run-command (getf args :cmd) (getf args :timeout)))

(defun run-command (cmd timeout-ms)
  (let* ((process (uiop:launch-program (list "/bin/sh" "-c" cmd)
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
          ;; Killing the child closes the pipe, which ends the drain
          ;; thread on its own.
          (uiop:terminate-process process :urgent t)
          (uiop:wait-process process)
          (fail :timeout)))))
