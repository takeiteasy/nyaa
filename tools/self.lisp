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

(defvar *last-image* nil
  "SAVE-IMAGE's (image-generation.lisp, loaded after this file) most
recent core pathname, or nil if none has been taken. Set there; read here
for :REQUIRE-IMAGE and logged on every write, so this file only ever
depends on a var, never a forward reference to a function in a file that
loads after it.")

(defvar *self-dirty* nil
  "T once any tool-self write has happened since *LAST-IMAGE* was taken.
Cleared by SAVE-IMAGE and SELF-DEFINE; set by every write this file
performs, regardless of :op.")

(a:define-constant +definition-heads+
    '(defun defmacro defgeneric defmethod defclass defstruct defparameter
      defvar m:defservice nyaa:define-tool)
  :test #'equal
  :documentation "Heads :DEFINE accepts. Anything else -- PROGN, LET, a bare
call -- is :EVAL's job instead, so :DEFINE's checkpoint label and
:previous-source logging always describe an actual definition.")

(define-tool :tool-self
    (:trust :operator
     :summary "Evaluate, redefine and reload in the host image; every write checkpointed and logged"
     :slots ((enable :initarg :enable :initform nil :reader self-enable
                     :documentation "Ops this mount answers as writes, e.g.
'(:define :reload). :EVAL, :DEFINE and :RELOAD are refused unless named
here; :LOG always answers.")
             (dir :initarg :dir :initform *generations-directory* :reader self-dir)
             (keep :initarg :keep :initform nil :reader self-keep)
             (log-path :initarg :log :initform nil :reader self-log-path)
             (require-image :initarg :require-image :initform nil :reader self-require-image-p
                            :documentation "T refuses :eval and :define
unless an image generation (~takeiteasy/nyaa#48) has been taken and
nothing has written since (*LAST-IMAGE*, *SELF-DIRTY*) -- SELF-DEFINE is
then the only way an operator can still redefine anything, and every
:define stays code-exact, undoable by relaunching that image."))
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
      (t (cond
           ((not (member op (self-enable service)))
            (fail (list :forbidden (format nil "~(~a~) is not enabled" op))))
           ((and (member op '(:eval :define)) (self-require-image-p service)
                 (%image-required-refusal))
            (bad-request "~a" (%image-required-refusal)))
           (t (op-self-write service op form package name label timeout)))))))

(defun %image-required-refusal ()
  "Why :REQUIRE-IMAGE refuses right now, or nil if it wouldn't. A generation
taken before any tool-self write, but with a write since, is stale: it
would roll back to before the write tool-self is about to make, not to
before this one."
  (cond ((null *last-image*) "take an image generation first (~takeiteasy/nyaa#48)")
        (*self-dirty* "the last image generation is stale -- take another first")))

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
              (setf *self-dirty* t)
              (log-self-entry service :intent op parsed label checkpoint-path previous)
              (let ((result (perform-self-write
                             service op parsed timeout
                             (lambda (late-result)
                               (log-self-outcome service op parsed late-result
                                                 :kind :late-outcome :checkpoint checkpoint-path)))))
                (log-self-outcome service op parsed result)
                result))
          (file-error (e) (fail (list :error (princ-to-string e))))))))

(defun self-write-previous-source (op parsed)
  "PARSED's defined name's current SYMBOL-SOURCE (tools/image.lisp), for
:DEFINE only, so a log entry that redefines something still points at where
it used to live. Declared-state ROLLBACK never restores code
(~takeiteasy/nyaa#48); an ordinary tool-self :define therefore has no way
back but this pointer -- SELF-DEFINE (image-generation.lisp,
~takeiteasy/nyaa#63) is the code-exact one, an image generation taken
immediately before the write."
  (when (and (eq op :define) (second parsed) (symbolp (second parsed)))
    (symbol-source (second parsed))))

(defun perform-self-write (service op parsed timeout on-late)
  (ecase op
    ((:eval :define) (run-in-host parsed timeout :on-late on-late))
    (:reload (op-self-reload service parsed timeout))))

(defun op-self-reload (service name timeout)
  (declare (ignore timeout))
  (let ((context (m:service-context service)))
    (handler-case
        (a:if-let (process (m:reload (m:service-process context) name))
          (ok :name (string-downcase (symbol-name name)) :process (princ-to-string process))
          (bad-request "no child named ~(~a~)" name))
      (error (e) (fail (list :error (princ-to-string e)))))))

;;; --- CLOS mutation latch (~takeiteasy/nyaa#79) -------------------------
;;;
;;; SBCL's own PCL/DEFSTRUCT loaders are hooked to say exactly when a
;;; form's evaluation reaches its actual CLOS mutation, so :DEFINE only
;;; lets a lapsed deadline wait for the form past that point instead of
;;; across the whole of it (#64, #68).
;;;
;;; *CLOS-MUTATION-LATCH*, bound fresh by RUN-IN-HOST for each evaluation,
;;; starts nil: an interrupt still lands pre-emptively, so a wedged form
;;; before its own CLOS mutation is killed, not leaked. The latching hooks
;;; below set it once evaluation reaches one of SBCL's own class, method,
;;; generic-function or struct loaders -- installed with SB-INT:ENCAPSULATE,
;;; the same primitive TRACE and PROFILE use, so a rename here breaks
;;; loudly rather than silently stops latching. COMPILE-OR-LOAD-DEFGENERIC
;;; (a DEFMETHOD's own implicit ENSURE-GENERIC-FUNCTION, ahead of its :eql
;;; specializers and method compile) doesn't latch -- it defers interrupts
;;; for the duration of the call instead, so it can only ever run to
;;; completion or not start, no cooperative check needed. That deferral is
;;; itself gated on *CLOS-MUTATION-LATCH* being bound, so a DEFMETHOD
;;; anywhere else in the image (the REPL, ASDF, hmr) is unaffected.
;;;
;;; TODO: a form that wedges *after* reaching its own mutation -- a second,
;;; later DEFMETHOD in the same :eval whose :eql specializer hangs -- still
;;; leaks its thread, the same way the whole-form deferral did. Tracked in
;;; ~takeiteasy/nyaa#81.

(defvar *clos-mutation-latch* nil
  "Nil outside RUN-IN-HOST. Bound there to a fresh cons for the form being
evaluated; the hooks below set its CAR once that form's own evaluation
reaches SBCL's CLOS or DEFSTRUCT machinery.")

(a:define-constant +clos-latching-hooks+
    '(sb-pcl::load-defclass sb-pcl::load-defmethod sb-pcl::load-defgeneric
      sb-kernel::%defstruct)
  :test #'equal
  :documentation "SBCL internals that apply a class, method, generic
function or struct definition once its own form has already evaluated
every part a user's code could still wedge on (an :eql specializer, a
slow compile) -- the point RUN-IN-HOST's interrupt switches from killing
the thread to waiting for it, since nothing past here can run long.")

(defun %latch-clos-mutation (next &rest args)
  (when *clos-mutation-latch* (setf (car *clos-mutation-latch*) t))
  (apply next args))

(defun %atomic-clos-mutation (next &rest args)
  "Only defers interrupts inside a RUN-IN-HOST evaluation -- *CLOS-MUTATION-
LATCH* bound means one is in progress. Elsewhere (the REPL, ASDF, hmr) this
must stay a no-op: deferring interrupts for every DEFMETHOD in the image,
on any thread, is a far bigger change than RUN-IN-HOST's own contract asks
for."
  (if *clos-mutation-latch*
      (sb-sys:without-interrupts (apply next args))
      (apply next args)))

(defun %install-clos-mutation-hooks ()
  "Idempotent: UNENCAPSULATEs first, so reloading this file (or SBCL
recompiling it in a running image) never stacks a second copy of the same
hook."
  (dolist (name +clos-latching-hooks+)
    (sb-int:unencapsulate name 'nyaa-self)
    (sb-int:encapsulate name 'nyaa-self #'%latch-clos-mutation))
  (sb-int:unencapsulate 'sb-pcl::compile-or-load-defgeneric 'nyaa-self)
  (sb-int:encapsulate 'sb-pcl::compile-or-load-defgeneric 'nyaa-self #'%atomic-clos-mutation))

(defun clos-mutation-hooks-installed-p ()
  "T if every hook %INSTALL-CLOS-MUTATION-HOOKS installs is still in
place -- checked by a test, so a future SBCL rename of one of these
internals fails loudly instead of silently reverting :DEFINE to
pre-emptive-only."
  (and (every (lambda (name) (sb-int:encapsulated-p name 'nyaa-self)) +clos-latching-hooks+)
       (sb-int:encapsulated-p 'sb-pcl::compile-or-load-defgeneric 'nyaa-self)))

(eval-when (:load-toplevel :execute) (%install-clos-mutation-hooks))

;;; --- host eval, bounded and interruptible ------------------------------

;;; Same shape as TOOLS/HTTP.LISP's ABANDON-REQUEST: a worker thread, a
;;; semaphore for the caller's wait, and an IN-REGION box guarding the
;;; interrupt so it only ever throws to a catch tag that is actually there.
;;;
;;; A deadline's interrupt lands pre-emptively (THROW straight to
;;; SELF-ABANDONED) until *CLOS-MUTATION-LATCH* is set. Once it is, the
;;; interrupt does nothing: the form is left to finish, so a deadline
;;; landing inside SBCL's own CLOS mutation never tears it. The caller has
;;; already been told :TIMEOUT by then, so the worker reports the form's
;;; real result through ON-LATE when it completes.
;;;
;;; STATE is the hand-off between the two threads: whichever of the worker
;;; (:DONE) and the caller (:TIMED-OUT) claims it first by
;;; COMPARE-AND-SWAP decides who reports the result.

(defun run-in-host (form timeout-ms &key on-late)
  "FORM evaluated on its own thread, interrupted at TIMEOUT-MS. Once
evaluation reaches SBCL's own CLOS/DEFSTRUCT machinery (see above) the
interrupt no longer kills it: the form finishes, and ON-LATE, if given, is
called with its result on that thread after the caller has already
received :TIMEOUT."
  (let* ((result nil)
         (in-region (list nil))
         (state (list :running))
         (latch (list nil))
         (done (bt:make-semaphore))
         (registry m:*registry*)
         (worker (bt:make-thread
                  (lambda ()
                    (let ((m:*registry* registry)
                          (*clos-mutation-latch* latch))
                      (unwind-protect
                           (progn
                             (setf result
                                   (catch 'self-abandoned
                                     (setf (car in-region) t)
                                     (unwind-protect (eval-in-host form)
                                       (setf (car in-region) nil))))
                             (when (and (not (eq :running (sb-ext:compare-and-swap (car state) :running :done)))
                                        result on-late)
                               (ignore-errors (funcall on-late result))))
                        (bt:signal-semaphore done))))
                  :name "nyaa-self-eval")))
    (if (or (bt:wait-on-semaphore done :timeout (/ timeout-ms 1000))
            (not (eq :running (sb-ext:compare-and-swap (car state) :running :timed-out))))
        result
        (progn (abandon-self-eval worker in-region latch) (fail :timeout)))))

(defun abandon-self-eval (worker in-region latch)
  (ignore-errors
   (when (bt:thread-alive-p worker)
     (bt:interrupt-thread
      worker (lambda ()
               (when (and (car in-region) (not (car latch)))
                 (throw 'self-abandoned nil)))))))

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
                     :label label :checkpoint checkpoint-path :previous-source previous
                     :image *last-image*)))
    (%append-log (self-log-file service) entry)
    (m:log-info service "tool-self ~(~a~) ~(~a~), checkpoint ~a" kind op checkpoint-path)))

(defun log-self-outcome (service op parsed result &key (kind :outcome) checkpoint)
  "KIND :LATE-OUTCOME, with the write's CHECKPOINT to tie it to its intent
entry, records a write that finished after its caller was told :TIMEOUT."
  (let ((entry (list :at (%now-iso8601) :kind kind :op op
                     :name (and (eq op :reload) parsed)
                     :checkpoint checkpoint
                     :outcome (if (tool-error-p result) (list :error (tool-error result)) :ok))))
    (%append-log (self-log-file service) entry)
    (cond ((eq kind :late-outcome)
           (m:log-warn service "tool-self ~(~a~) finished after its timeout: ~s" op (getf entry :outcome)))
          ((tool-error-p result)
           (m:log-warn service "tool-self ~(~a~) failed: ~s" op (tool-error result)))
          (t (m:log-info service "tool-self ~(~a~) ok" op)))))

(defun op-self-log (path limit)
  (let ((entries (%read-log path)))
    (ok :entries (last entries limit) :total (length entries))))
