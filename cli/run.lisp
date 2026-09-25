(in-package #:nyaa/cli)

;;; `nyaa run`: one agent run to completion. docs/cli.md.

(defparameter *usage*
  "usage: nyaa run PROMPT [--model PROVIDER:MODEL] [--tools NAME,...]
                 [--system-file FILE] [--system-replace] [--max-turns N] [-v]")

(defparameter *default-system*
  "You are nyaa, an agent run from the command line. Do the task, then answer briefly.")

(defparameter *default-model* "ollama:llama3.2")

(define-condition usage-error (error)
  ((message :initarg :message :reader usage-message))
  (:report (lambda (condition stream) (write-string (usage-message condition) stream))))

(defun usage-error (format &rest args)
  (error 'usage-error :message (apply #'format nil format args)))

;;; --- arguments ------------------------------------------------------------

(defun parse-args (args)
  "ARGS after `run`, as a plist: :prompt :model :tools :system-file
:system-replace :max-turns :verbose."
  (let (prompt (model *default-model*) tools system-file system-replace max-turns verbose)
    (flet ((value (flag)
             (or (pop args) (usage-error "~a needs a value" flag))))
      (loop while args
            do (let ((arg (pop args)))
                 (cond ((string= arg "--model") (setf model (value arg)))
                       ((string= arg "--tools") (setf tools (uiop:split-string (value arg) :separator ",")))
                       ((string= arg "--system-file") (setf system-file (value arg)))
                       ((string= arg "--system-replace") (setf system-replace t))
                       ((string= arg "--max-turns")
                        (let ((n (parse-integer (value arg) :junk-allowed t)))
                          (unless (and n (plusp n)) (usage-error "--max-turns wants a positive integer"))
                          (setf max-turns n)))
                       ((member arg '("-v" "--verbose") :test #'string=) (setf verbose t))
                       ((string= arg "--") (when args (setf prompt (pop args))))
                       ((and (> (length arg) 1) (char= (char arg 0) #\-))
                        (usage-error "unknown option ~a" arg))
                       (prompt (usage-error "more than one prompt: ~s and ~s" prompt arg))
                       (t (setf prompt arg))))))
    (unless prompt (usage-error "no prompt"))
    (when (and system-replace (not system-file))
      (usage-error "--system-replace needs --system-file"))
    (list :prompt prompt :model model :tools tools :system-file system-file
          :system-replace system-replace :max-turns max-turns :verbose verbose)))

(defun split-model (spec)
  "SPEC, PROVIDER:MODEL, split on the first colon."
  (let ((colon (position #\: spec)))
    (unless (and colon (plusp colon) (< (1+ colon) (length spec)))
      (usage-error "--model wants PROVIDER:MODEL, got ~s" spec))
    (values (subseq spec 0 colon) (subseq spec (1+ colon)))))

(defun named (prefix name)
  (a:make-keyword (string-upcase (format nil "~a~a" prefix name))))

(defun system-prompt (system-file replace)
  (let ((text (and system-file
                   (or (probe-file system-file) (usage-error "no such file: ~a" system-file))
                   (uiop:read-file-string system-file))))
    (cond ((null text) *default-system*)
          (replace text)
          (t (format nil "~a~%~%~a" *default-system* text)))))

;;; --- running --------------------------------------------------------------

(defun load-init (home)
  (let ((init (merge-pathnames "init.lisp" home)))
    (when (probe-file init) (load init))))

(defun verbose-sink (stream)
  (lambda (event)
    (case (getf event :type)
      (:text-delta (write-string (getf event :text "") stream))
      (:tool-call (format stream "~&[tool ~(~a~) ~s]~%" (getf event :name) (getf event :arguments)))
      (:tool-result (format stream "~&[result ~s]~%" (getf event :result)))
      (:turn-retry (format stream "~&[retry ~s]~%" (getf event :reason)))
      (:run-done (format stream "~&[done ~(~a~)]~%" (getf event :reason))))
    (finish-output stream)))

(defun exit-code (result)
  "RESULT, run-agent's answer, as an exit code: 0 for a run that stopped, 3
for one cut short by :max-turns or :timeout, 1 for anything else."
  (if (eq (first result) :ok)
      (case (getf (second result) :stop-reason)
        (:stop 0)
        ((:max-turns :timeout) 3)
        (t 1))
      1))

(defun report (result out err)
  (if (eq (first result) :ok)
      (let ((text (nyaa:content-text (getf (second result) :content)))
            (reason (getf (second result) :stop-reason)))
        (when (plusp (length text)) (format out "~a~%" text))
        (unless (eq reason :stop)
          (format err "nyaa: run ended: ~(~a~)~%" reason)))
      (format err "nyaa: ~a~%" (second result))))

(defun run (options context out err)
  (multiple-value-bind (provider model) (split-model (getf options :model))
    (let ((provider-name (named "provider-" provider))
          (tools (mapcar (lambda (name) (named "" name)) (getf options :tools)))
          (system (system-prompt (getf options :system-file) (getf options :system-replace))))
      (unless (member provider-name (nyaa:definitions :kind :provider))
        (usage-error "no provider ~s; defined: ~{~(~a~)~^, ~}" provider
                     (mapcar (lambda (name) (subseq (string name) (length "provider-")))
                             (nyaa:definitions :kind :provider))))
      (dolist (tool tools)
        (unless (member tool (nyaa:definitions :kind :tool))
          (usage-error "no tool ~(~a~); defined: ~{~(~a~)~^, ~}" tool (nyaa:definitions :kind :tool))))
      (nyaa:ensure-mounted context provider-name :model model)
      (dolist (tool tools)
        (if (eq tool :tool-fs)
            (nyaa:ensure-mounted context tool :root (namestring (uiop:getcwd)))
            (nyaa:ensure-mounted context tool)))
      (let ((result (apply #'nyaa:run-agent context
                           :model provider-name :system system
                           :messages (list (list :role :user :content (getf options :prompt)))
                           (append (and tools (list :tools tools))
                                   (and (getf options :max-turns)
                                        (list :max-turns (getf options :max-turns)))
                                   (and (getf options :verbose)
                                        (list :sink (verbose-sink err)))))))
        (report result out err)
        (exit-code result)))))

(defun main (args &key context (home (nyaa/launcher:nyaa-home))
                    (out *standard-output*) (err *error-output*))
  "Run the command ARGS names and return its exit code. CONTEXT is the
context to mount into; by default one is started and stopped here. HOME is
where init.lisp is read from."
  (handler-case
      (cond
        ((null args) (usage-error "no command"))
        ((member (first args) '("-h" "--help") :test #'string=)
         (format out "~a~%" *usage*) 0)
        ((string= (first args) "run")
         (let ((options (parse-args (rest args))))
           (load-init home)
           (if context
               (run options context out err)
               (let ((own (m:start-service (make-instance 'm:context :name :cli))))
                 (unwind-protect (run options own out err)
                   (m:stop own))))))
        (t (usage-error "unknown command ~a" (first args))))
    (usage-error (e)
      (format err "nyaa: ~a~%~a~%" e *usage*)
      2)
    (error (e)
      (format err "nyaa: ~a~%" e)
      1)))
