(in-package #:nyaa)

;;; Workers: a bare Lisp child process evaluating forms over stdio, so a
;;; crash or a hang costs at most a deadline and never the host image.
;;;
;;; The child loads nothing -- no Quicklisp, no meow, no nyaa. Loading
;;; Quicklisp alone costs ten times a bare launch, which is what makes a
;;; fresh process per evaluation cheaper than pooling one.
;;;
;;; Protocol, one exchange per line, read on both sides with *READ-EVAL*
;;; bound to nil:
;;;
;;;   host   -> (:eval "<source>")
;;;   worker -> (:ready)                     once, at boot
;;;          -> (:ok "<value>" "<output>")
;;;          -> (:error "<message>" "<output>")
;;;          -> (:reader-error "<message>")
;;;
;;; The source travels as a string rather than a form: the envelope then
;;; holds nothing but keywords and strings, so source that does not read
;;; costs one reply instead of desynchronising the stream.
;;;
;;; A worker leads its own process group (see process.lisp), so a form that
;;; backgrounds a process is signalled along with the worker at kill time,
;;; the same as tools/shell.lisp's commands.

(defmacro worker-program ()
  "The child's loop, read from worker-program.lisp as text when this file is
compiled: it is source the child evaluates, not source the host loads.
ASDF does not know that, so editing the program means touching this file too."
  (uiop:read-file-string
   (merge-pathnames "worker-program.lisp"
                    (or *compile-file-truename* *load-truename*))))

(defparameter *worker-program* (worker-program)
  "The child's read/eval/print loop, passed on its command line.")

(defparameter *worker-command* nil
  "Argv that starts a bare Lisp, or NIL for the host implementation. The
program is appended as the final argument. Set this to run workers on
another implementation than the one hosting them.")

(defconstant +worker-start-timeout+ 5000
  "Milliseconds a worker gets to answer its handshake.")

(defun worker-argv ()
  "The host implementation's bare, quiet, non-interactive invocation."
  (or *worker-command*
      #+sbcl (list (namestring sb-ext:*runtime-pathname*)
                   "--noinform" "--non-interactive" "--no-sysinit" "--no-userinit"
                   "--eval")
      #+ecl (list "ecl" "-q" "--norc" "--eval")
      #+ccl (list "ccl" "--no-init" "--quiet" "--batch" "--eval")
      #-(or sbcl ecl ccl)
      (error "No worker invocation known for ~a; set NYAA:*WORKER-COMMAND*."
             (lisp-implementation-type))))

(defstruct (worker (:constructor %make-worker (process)))
  process)

(defun start-worker ()
  "A running worker, or NIL if the child never answered its handshake."
  (let ((worker (ignore-errors
                 (%make-worker
                  (launch-in-process-group
                   (append (worker-argv) (list *worker-program*))
                   :input :stream :output :stream
                   ;; Diagnostics are reported in band; anything else the
                   ;; child writes to stderr would corrupt the protocol.
                   :error-output nil)))))
    (when worker
      (if (equal '(:ready) (read-reply worker +worker-start-timeout+))
          worker
          (progn (kill-worker worker) nil)))))

(defun worker-alive-p (worker)
  (and worker (uiop:process-alive-p (worker-process worker))))

(defun kill-worker (worker)
  (when worker
    (terminate-process-group (worker-process worker)))
  nil)

(defun worker-eval (worker source timeout-ms)
  "Evaluate SOURCE in WORKER. Returns a tool result; a worker that missed
its deadline or died is dead afterwards and the caller must not reuse it."
  (if (not (worker-alive-p worker))
      (fail :unavailable)
      (let ((stream (uiop:process-info-input (worker-process worker))))
        (handler-case (progn (prin1 (list :eval source) stream)
                             (terpri stream)
                             (finish-output stream))
          (error () (return-from worker-eval (fail :unavailable))))
        (interpret-reply (read-reply worker timeout-ms)))))

(defun read-reply (worker timeout-ms)
  "One reply form, or :TIMEOUT, or NIL on EOF or a malformed reply. A lapsed
deadline kills the worker, which closes the pipe and ends the reader."
  (let ((reply nil)
        (done (bt:make-semaphore))
        (stream (uiop:process-info-output (worker-process worker))))
    (bt:make-thread
     (lambda ()
       (unwind-protect
            (setf reply (handler-case (let ((*read-eval* nil))
                                        (read stream nil nil))
                          (error () nil)))
         (bt:signal-semaphore done)))
     :name "nyaa-worker-reply")
    (if (bt:wait-on-semaphore done :timeout (/ timeout-ms 1000))
        reply
        (progn (kill-worker worker) :timeout))))

(defun interpret-reply (reply)
  (case (and (consp reply) (first reply))
    (:ok (ok :value (second reply) :out (or (third reply) "")))
    (:error (fail (list :error (second reply))))
    (:reader-error (bad-request "~a" (second reply)))
    (t (if (eq reply :timeout) (fail :timeout) (fail :unavailable)))))
