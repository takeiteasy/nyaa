(in-package #:nyaa)

;;; Self-modification (~takeiteasy/nyaa#12): evaluate in the host image,
;;; redefine functions and classes, and reload a mounted child -- the three
;;; things tool-eval, tool-repl and a worker can never reach, since a worker
;;; loads nothing and shares no state with the running harness.
;;;
;;; Every write op (:eval, :define, :reload) is off by default. :ENABLE, a
;;; mount option, names the ops a caller may reach; :LOG alone is always
;;; answered, since it only reads back what a write already did. This
;;; records operator intent and gives an audit trail -- it is not a sandbox.
;;; A :form can still redefine TOOL-TRUST or RESOLVE-TOOLS, since it runs in
;;; the host image with no DSL between it and CL:EVAL; the plan gate (#6)
;;; constrains a *model's* reach, not an operator's.
;;;
;;; A write takes a checkpoint first (checkpoint.lisp) and logs an intent
;;; entry naming it before the op runs, then an outcome entry after -- so a
;;; crash mid-eval still leaves a trace pointing at the generation to roll
;;; back to. The log is a second, append-only s-expression file alongside
;;; the generation directory, read the same guarded way (checkpoint.lisp's
;;; %READ-GENERATION): *READ-EVAL* nil, so a submitted form can never run
;;; merely by the log being read back. Each entry also reaches meow's
;;; logger, when one is mounted, for live visibility; the file is the
;;; durable copy.
;;;
;;; TODO: a checkpoint taken here shares #11's own ceilings -- it does not
;;; bound its own time by :TIMEOUT (~takeiteasy/nyaa#51) and, issued mid-run
;;; the way an agent's own call always is, it keeps the conversation but not
;;; the turn in flight (~takeiteasy/nyaa#50). Both are tracked already;
;;; nothing here raises the ceiling further.

(defvar *self-log* nil
  "Default log path for TOOL-SELF: ~/.nyaa/self.log, resolved lazily so
loading this file never touches the filesystem or the user's home.")

(defun %default-self-log ()
  (or *self-log*
      (setf *self-log* (merge-pathnames ".nyaa/self.log" (user-homedir-pathname)))))

(a:define-constant +definition-heads+
    '(defun defmacro defgeneric defmethod defclass defstruct defparameter
      defvar m:defservice nyaa:define-tool)
  :test #'equal
  :documentation "Heads :DEFINE accepts. Anything else -- PROGN, LET, a bare
call -- is :EVAL's job instead, so :DEFINE's checkpoint label and
:previous-source logging always describe an actual definition.")

(a:define-constant +clos-definition-heads+
    '(defclass defmethod defgeneric defstruct m:defservice nyaa:define-tool)
  :test #'equal
  :documentation "Heads of +DEFINITION-HEADS+ that expand into several
sub-forms mutating CLOS (a DEFCLASS's class-defining code, method-adding
forms for DEFMETHOD) -- M:DEFSERVICE and NYAA:DEFINE-TOOL both macroexpand
to DEFCLASS plus DEFMETHOD. An interrupt landing between those sub-forms can
leave CLOS mid-update, so :DEFINE abandons these cooperatively instead of
pre-emptively (RUN-IN-HOST, below), waiting for the form to finish rather
than risking a torn redefinition. DEFUN, DEFMACRO, DEFPARAMETER and DEFVAR
each end in one store and cannot tear this way, so they stay pre-emptively
interruptible -- treating them the same way would also make their init
forms uninterruptible, turning a wedged (defparameter *x* (loop)) into a
leaked thread instead of a killable one.")

(define-tool :tool-self
    (:trust :operator
     :summary "Evaluate, redefine and reload in the host image; every write checkpointed and logged"
     :slots ((enable :initarg :enable :initform nil :reader self-enable
                     :documentation "Ops this mount answers as writes, e.g.
'(:define :reload). :EVAL, :DEFINE and :RELOAD are refused unless named
here; :LOG always answers.")
             (dir :initarg :dir :initform *generations-directory* :reader self-dir)
             (keep :initarg :keep :initform nil :reader self-keep)
             (log-path :initarg :log :initform nil :reader self-log-path))
     :params ((:op (member :eval :define :reload :log) :required t
               :doc "operation to perform")
              (:form string :doc "source text of one form, for :eval and :define")
              (:package string :default "CL-USER"
               :doc "package the form reads in, for :eval and :define")
              (:name string :doc "child name to reload, for :reload")
              (:label string :doc "a note for this write's checkpoint and log entry")
              (:limit (integer 1 1000) :default 50 :doc "entries to answer, for :log")
              (:timeout (integer 1) :default +default-tool-timeout+
               :doc "kill a wedged :eval or :define after this many milliseconds")))
  (:invoke (op form package name label limit timeout)
    (case op
      (:log (op-self-log (self-log-file service) limit))
      (t (if (not (member op (self-enable service)))
             (fail (list :forbidden (format nil "~(~a~) is not enabled" op)))
             (op-self-write service op form package name label timeout))))))

(defun self-log-file (service)
  (or (self-log-path service) (%default-self-log)))

;;; --- dispatch, ahead of any checkpoint --------------------------------

(defun op-self-write (service op form package name label timeout)
  (multiple-value-bind (parsed problem)
      (case op
        (:eval (parse-self-form form package))
        (:define (parse-define-form form package))
        (:reload (parse-reload-name name)))
    (if problem
        (bad-request "~a" problem)
        (run-checkpointed-write service op parsed label timeout))))

(defun parse-self-form (form package)
  (if (null form)
      (values nil ":form is required")
      (%read-one-form form package)))

(defun parse-define-form (form package)
  (multiple-value-bind (parsed problem) (parse-self-form form package)
    (cond
      (problem (values nil problem))
      ((not (member (first parsed) +definition-heads+ :test #'eq))
       (values nil (format nil "~(~a~) is not a definition form" (first parsed))))
      (t (values parsed nil)))))

(defun parse-reload-name (name)
  (if (null name)
      (values nil ":name is required")
      (let ((symbol (find-symbol (string-upcase name) "KEYWORD")))
        (if symbol (values symbol nil) (values nil (format nil "no such name ~a" name))))))

(defun %read-one-form (text package-name)
  "TEXT read as exactly one form, in PACKAGE-NAME, with *READ-EVAL* nil, or
(values nil problem). FIND-PACKAGE only -- a package that does not already
exist is a problem, never created on the operator's behalf."
  (let ((package (find-package (string-upcase package-name))))
    (if (null package)
        (values nil (format nil "no package named ~a" package-name))
        (let ((*read-eval* nil) (*package* package))
          (handler-case
              (with-input-from-string (stream text)
                (let ((form (read stream)))
                  (if (eq (read stream nil :eof) :eof)
                      (values form nil)
                      (values nil "form must be exactly one expression"))))
            (error (e) (values nil (princ-to-string e))))))))

;;; --- checkpoint, log, then the op --------------------------------------

(defun run-checkpointed-write (service op parsed label timeout)
  (let ((context (m:service-context service)))
    (if (null context)
        (fail (list :error "not mounted under a context"))
        (handler-case
            (let* ((checkpoint-path
                     (namestring (checkpoint (m:service-process context)
                                             :dir (self-dir service) :keep (self-keep service)
                                             :label (or label (format nil "tool-self ~(~a~)" op)))))
                   (previous (self-write-previous-source op parsed)))
              (log-self-entry service :intent op parsed label checkpoint-path previous)
              (let ((result (perform-self-write service op parsed timeout)))
                (log-self-outcome service op parsed result)
                result))
          (file-error (e) (fail (list :error (princ-to-string e))))))))

(defun self-write-previous-source (op parsed)
  "PARSED's defined name's current SYMBOL-SOURCE (tools/image.lisp), for
:DEFINE only, so a log entry that redefines something still points at where
it used to live -- rollback restores declared state, never code
(~takeiteasy/nyaa#48, ~takeiteasy/nyaa#63), so this is the only revert path
a generation buys."
  (when (and (eq op :define) (second parsed) (symbolp (second parsed)))
    (symbol-source (second parsed))))

(defun perform-self-write (service op parsed timeout)
  (ecase op
    ((:eval :define) (run-in-host parsed timeout (self-write-defers-p op parsed)))
    (:reload (op-self-reload service parsed timeout))))

(defun self-write-defers-p (op parsed)
  "T when PARSED's head is one of +CLOS-DEFINITION-HEADS+, so RUN-IN-HOST
defers interrupts across the whole form instead of leaving it abandonable."
  (and (eq op :define) (member (first parsed) +clos-definition-heads+ :test #'eq)))

(defun op-self-reload (service name timeout)
  (declare (ignore timeout))
  (let ((context (m:service-context service)))
    (handler-case
        (a:if-let (process (m:reload (m:service-process context) name))
          (ok :name (string-downcase (symbol-name name)) :process (princ-to-string process))
          (bad-request "no child named ~(~a~)" name))
      (error (e) (fail (list :error (princ-to-string e)))))))

;;; --- host eval, bounded and interruptible ------------------------------

;;; Same shape as TOOLS/HTTP.LISP's ABANDON-REQUEST: a worker thread, a
;;; semaphore for the caller's wait, and an IN-REGION box guarding the
;;; interrupt so it only ever throws to a catch tag that is actually there.
;;;
;;; A :DEFINE whose head is one of +CLOS-DEFINITION-HEADS+ (~takeiteasy/
;;; nyaa#64) abandons cooperatively instead of pre-emptively: an interrupt
;;; landing inside a DEFCLASS or DEFMETHOD expansion can leave CLOS
;;; mid-update, unlike TOOLS/HTTP.LISP's socket, which has one resource to
;;; release on the way out. BT:INTERRUPT-THREAD's deferral around a target
;;; thread's own critical sections (SBCL's WITHOUT-INTERRUPTS, CCL's) is not
;;; portable -- ECL's MP:INTERRUPT-PROCESS fires immediately even inside
;;; MP:WITHOUT-INTERRUPTS, confirmed by hand against the running
;;; implementation -- so ABANDON-SELF-EVAL never interrupts a deferred
;;; write. It only raises the ABANDON flag; the worker checks it itself,
;;; from its own thread, right after EVAL-IN-HOST returns, and throws only
;;; then. A deadline during a deferred write therefore always waits for the
;;; form to finish rather than risking tearing it.
;;;
;;; TODO: a form that never finishes -- a wedged :eql specializer, a slow
;;; compile -- leaks its thread instead of being killed, since it is never
;;; interrupted at all. Upgrade path: defer only around the CLOS mutation
;;; itself, once an implementation exposes where that starts relative to
;;; the form's own evaluation, rather than around the whole form. Tracked
;;; in ~takeiteasy/nyaa#68.

(defun run-in-host (form timeout-ms &optional defer-p)
  "FORM evaluated on its own thread, interrupted at TIMEOUT-MS -- or, when
DEFER-P, abandoned cooperatively (see above) so a lapsed deadline waits one
form longer instead of tearing a CLOS-mutating :define."
  (let* ((result nil)
         (in-region (list nil))
         (abandon (list nil))
         (done (bt:make-semaphore))
         (registry m:*registry*)
         (worker (bt:make-thread
                  (lambda ()
                    (let ((m:*registry* registry))
                      (unwind-protect
                           (setf result
                                 (catch 'self-abandoned
                                   (setf (car in-region) t)
                                   (unwind-protect
                                        (prog1 (eval-in-host form)
                                          (when (and defer-p (car abandon))
                                            (throw 'self-abandoned nil)))
                                     (setf (car in-region) nil))))
                        (bt:signal-semaphore done))))
                  :name "nyaa-self-eval")))
    (if (bt:wait-on-semaphore done :timeout (/ timeout-ms 1000))
        result
        (progn (abandon-self-eval worker in-region abandon defer-p) (fail :timeout)))))

(defun abandon-self-eval (worker in-region abandon defer-p)
  (if defer-p
      (setf (car abandon) t)
      (ignore-errors
       (when (bt:thread-alive-p worker)
         (bt:interrupt-thread
          worker (lambda () (when (car in-region) (throw 'self-abandoned nil))))))))

(defun eval-in-host (form)
  (let ((out (make-string-output-stream)))
    (handler-case
        (let ((value (let ((*standard-output* out) (*error-output* out))
                       (eval form))))
          (ok :value (render-self-value value) :out (get-output-stream-string out)))
      (error (e) (fail (list :error (princ-to-string e)))))))

(defun render-self-value (value)
  "VALUE printed under the same caps WORKER-PROGRAM.LISP applies, so a large
or circular host value cannot flood the reply the way an uncapped one
could ~takeiteasy/nyaa#26 already tracks for the worker side."
  (let ((*print-length* 100) (*print-level* 8) (*print-readably* nil) (*print-circle* t))
    (let ((s (prin1-to-string value)))
      (if (> (length s) 4000) (concatenate 'string (subseq s 0 4000) " ...") s))))

;;; --- the log -----------------------------------------------------------

(defun log-self-entry (service kind op parsed label checkpoint-path previous)
  (let ((entry (list :at (%now-iso8601) :kind kind :op op
                     :form (and (member op '(:eval :define)) (prin1-to-string parsed))
                     :name (and (eq op :reload) parsed)
                     :label label :checkpoint checkpoint-path :previous-source previous)))
    (%append-log (self-log-file service) entry)
    (m:log-info service "tool-self ~(~a~) ~(~a~), checkpoint ~a" kind op checkpoint-path)))

(defun log-self-outcome (service op parsed result)
  (let ((entry (list :at (%now-iso8601) :kind :outcome :op op
                     :name (and (eq op :reload) parsed)
                     :outcome (if (tool-error-p result) (list :error (tool-error result)) :ok))))
    (%append-log (self-log-file service) entry)
    (if (tool-error-p result)
        (m:log-warn service "tool-self ~(~a~) failed: ~s" op (tool-error result))
        (m:log-info service "tool-self ~(~a~) ok" op))))

(defun op-self-log (path limit)
  (let ((entries (%read-log path)))
    (ok :entries (last entries limit) :total (length entries))))
