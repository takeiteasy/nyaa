(in-package #:nyaa)

#+sbcl (eval-when (:compile-toplevel :load-toplevel :execute) (require :sb-posix))

;;; SBCL image generations (~takeiteasy/nyaa#48): a generation
;;; (checkpoint.lisp) that also carries the running image itself, so a
;;; rollback -- unlike a declared-state-only one -- can undo code, not just
;;; state. SBCL only: SAVE-IMAGE forks, suspends nothing on the calling
;;; thread's own account (M:SUSPEND, meow#64) so every other thread is gone,
;;; then has the child SAVE-LISP-AND-DIE while the parent resumes and
;;; carries on. RELAUNCH re-execs into a saved core; BIN/NYAA and
;;; BIN/NYAA-INSTALL (bin/) are the shell side of launch and recovery.
;;;
;;; ECL and CCL get nothing here -- SAVE-IMAGE signals
;;; IMAGE-GENERATIONS-UNSUPPORTED, and #63's :require-image stays refused
;;; forever on them, exactly as it does today before any image is taken.

(defun image-generations-unsupported ()
  (error "Image generations are SBCL-only (~~takeiteasy/nyaa#48)."))

;;; --- refusals -----------------------------------------------------------

(defun %require-main-thread ()
  #+sbcl
  (unless (sb-thread:main-thread-p)
    (error "SAVE-IMAGE must run on the main thread, not ~a." (sb-thread:thread-name sb-thread:*current-thread*)))
  #-sbcl (image-generations-unsupported))

(defun %credentialed-provider (context)
  "The first entry under CONTEXT whose service is a PROVIDER holding an
:API-KEY, or nil. A core file is a copy of the whole heap -- keeping a
credential out of it is the same line providers.md and tool-image both
hold for published state and metadata, extended here to what SAVE-IMAGE
would otherwise write to disk."
  (find-if (lambda (entry)
             (let ((service (ignore-errors (m:service-of (getf entry :process)))))
               (and (typep service 'provider) (provider-api-key service))))
           (%context-entries context)))

(defun %require-no-credentials (context)
  (a:when-let ((entry (%credentialed-provider context)))
    (error "~(~a~) is mounted with :api-key; SAVE-IMAGE refuses to write a credential to disk. Unmount it, or mount from the environment variable instead." (getf entry :name))))

;;; --- saving ---------------------------------------------------------------

(defun %image-path (generation-path)
  (make-pathname :type "core" :defaults generation-path))

#+sbcl
(defun %make-image-toplevel (suspension)
  "SUSPENSION closed over from before the fork -- the same process and
service instances the saved core's heap already holds, so RESUME on load
just respawns threads over them, no re-discovery needed. NYAA_IMAGE_PROBE
set skips all of that: BIN/NYAA and the integration tests use it to check
a core loads without actually reviving its services."
  (lambda ()
    (cond
      ((uiop:getenv "NYAA_IMAGE_PROBE") (sb-ext:exit :code 0 :abort t))
      (t (cl+ssl:reload)
         (m:resume suspension)
         (sb-impl::toplevel-init)))))

#+sbcl
(defun %save-and-die (suspension core-path)
  "Runs in the forked child, which SAVE-IMAGE has already confirmed is
down to its own single thread. Never returns: SAVE-LISP-AND-DIE exits the
process on success (SAVE-IMAGE reads that exit status, not this return,
since the child's own further execution is moot either way), and this
EXITs it with :code 1 on failure, so a save that raised partway through
-- leaving a truncated core -- is never mistaken for one that finished."
  (ignore-errors
   (sb-ext:save-lisp-and-die (namestring core-path)
                             :toplevel (%make-image-toplevel suspension)))
  (sb-ext:exit :code 1 :abort t))

#+sbcl
(defun %require-clean-save (pid core-path)
  "PID's WAITPID status, checked against SAVE-LISP-AND-DIE's own contract
(a clean exit :code 0): anything else -- a nonzero code, a signal -- means
CORE-PATH is truncated or absent, not a generation to hand back as if it
were whole. Deletes it and signals rather than returning a broken path."
  (multiple-value-bind (reported-pid status) (sb-posix:waitpid pid 0)
    (declare (ignore reported-pid))
    (unless (and (sb-posix:wifexited status) (zerop (sb-posix:wexitstatus status)))
      (ignore-errors (delete-file core-path))
      (error "save-lisp-and-die did not finish cleanly (status ~a); ~a was not written" status core-path))))

(defun save-image (context &key (dir *generations-directory*) label keep)
  "Fork and SAVE-LISP-AND-DIE a full image of CONTEXT's tree, alongside a
declared-state generation (checkpoint.lisp) of the same label. SBCL only
(#-sbcl signals IMAGE-GENERATIONS-UNSUPPORTED); must run on the main
thread, the only one still standing once M:SUSPEND has parked every
other. Refuses -- before suspending anything -- if a mounted PROVIDER
holds an :API-KEY.

Returns (values core-path generation-path). The calling process is
unaffected: every service is suspended for the fork and resumed again
before this returns, whether or not the fork succeeded."
  #-sbcl (image-generations-unsupported)
  #+sbcl
  (progn
    (%require-main-thread)
    (%require-no-credentials context)
    (let* ((generation-path (checkpoint context :dir dir :label label :keep keep))
           (core-path (%image-path generation-path))
           (suspension (m:suspend context))
           (pid (sb-posix:fork)))
      (if (zerop pid)
          (%save-and-die suspension core-path)
          (unwind-protect (%require-clean-save pid core-path)
            (m:resume suspension)))
      (when keep (%prune-generations (uiop:pathname-directory-pathname generation-path) keep))
      (setf *last-image* (%canonical-path core-path) *self-dirty* nil)
      (values *last-image* (%canonical-path generation-path)))))

;;; --- SELF-DEFINE (~takeiteasy/nyaa#63) ---------------------------------
;;;
;;; tool-self's :define, even checkpointed, can only be undone back to
;;; declared state -- never the redefinition itself. SELF-DEFINE closes
;;; that gap for an operator by taking an image generation immediately
;;; before the write, so RELAUNCHing that core undoes the code too. It is
;;; a REPL entry, not a tool op: an agent's turn can't reach it (SAVE-IMAGE
;;; needs the main thread), and the operator interrupts it the ordinary
;;; way -- there is no worker thread or :TIMEOUT here to abandon.

(defun self-define (context form &key (package "CL-USER") label (log (%default-self-log)))
  "Redefine FORM (read in PACKAGE), with an image generation taken
immediately before it as the rollback path. Returns the definition's
result and the image's path. Signals as SAVE-IMAGE does for its own
refusals (off the main thread, a credentialed provider); a malformed or
non-definition FORM is a plain error, same shape PARSE-DEFINE-FORM
reports through tool-self."
  #-sbcl (image-generations-unsupported)
  #+sbcl
  (multiple-value-bind (parsed problem) (parse-define-form form package)
    (if problem
        (error "~a" problem)
        (let ((previous (self-write-previous-source :define parsed)))
          (multiple-value-bind (image-path checkpoint-path)
              (save-image context :label (or label (format nil "self-define ~(~a~)" (first parsed))))
            (%log-self-define-entry log :intent parsed label checkpoint-path previous image-path)
            (let ((result (eval-in-host parsed)))
              (%log-self-define-entry log :outcome parsed label checkpoint-path previous image-path result)
              (values result image-path)))))))

(defun %log-self-define-entry (log kind parsed label checkpoint-path previous image-path &optional result)
  (let ((entry (if (eq kind :intent)
                    (list :at (%now-iso8601) :kind :intent :op :define
                          :form (prin1-to-string parsed) :label label
                          :checkpoint (namestring checkpoint-path) :previous-source previous
                          :image image-path)
                    (list :at (%now-iso8601) :kind :outcome :op :define
                          :outcome (if (tool-error-p result) (list :error (tool-error result)) :ok)))))
    (%append-log log entry)))

;;; --- launching --------------------------------------------------------

#+sbcl
(defun %probe-core (core)
  "T if CORE loads and its toplevel runs cleanly under NYAA_IMAGE_PROBE, in
a throwaway subprocess -- RELAUNCH and BIN/NYAA both refuse a core that
doesn't, rather than exec into a half-written or foreign one."
  (zerop (nth-value 2
          (uiop:run-program
           (list (namestring sb-ext:*runtime-pathname*) "--core" (namestring core)
                 "--noinform" "--non-interactive")
           :environment (list* "NYAA_IMAGE_PROBE=1" (sb-ext:posix-environ))
           :ignore-error-status t))))

;;; No Lisp-level execv wrapper exists in this SBCL build (sb-posix,
;;; sb-ext and sb-unix were all checked by hand against the running
;;; implementation) -- bound straight to libc's.
#+sbcl
(sb-alien:define-alien-routine "execv" sb-alien:int
  (path sb-alien:c-string)
  (argv (* sb-alien:c-string)))

#+sbcl
(defun %execv (path args)
  "Replace the current process image with PATH, ARGS as argv (PATH itself
is not implicitly argv[0]; callers pass it). Never returns on success --
signals an error on failure, execv's usual contract."
  (let* ((n (length args))
         (argv (sb-alien:make-alien sb-alien:c-string (1+ n))))
    (unwind-protect
         (progn
           (loop for i from 0 for a in args do (setf (sb-alien:deref argv i) a))
           (setf (sb-alien:deref argv n) nil)
           (execv path argv)
           (error "execv ~a failed: ~a" path (sb-int:strerror (sb-unix::get-errno))))
      (sb-alien:free-alien argv))))

(defun relaunch (core)
  "Replace the running SBCL process with CORE (EXECV), after confirming it
loads (%PROBE-CORE). A generation's core is code-exact -- unlike
declared-state ROLLBACK, this is the manual way tool-self's :DEFINE
writes can actually be undone (~takeiteasy/nyaa#63) until an operator
does it. Never returns on success."
  #-sbcl (image-generations-unsupported)
  #+sbcl
  (progn
    (unless (probe-file core) (error "no such core: ~a" core))
    (unless (%probe-core core) (error "~a did not load cleanly; refusing to relaunch into it" core))
    (finish-output) (finish-output *error-output*)
    (let ((runtime (namestring sb-ext:*runtime-pathname*)))
      (%execv runtime (list runtime "--core" (namestring core))))))

(defun save-recovery-image (path)
  "A plain image with no services mounted, for BIN/NYAA-INSTALL: the
fallback BIN/NYAA falls back to when a generation's core fails
%PROBE-CORE. Must run on the main thread, same as SAVE-IMAGE."
  #-sbcl (image-generations-unsupported)
  #+sbcl
  (progn
    (%require-main-thread)
    (ensure-directories-exist path)
    (sb-ext:save-lisp-and-die
     (namestring path)
     :toplevel (lambda ()
                 (unless (uiop:getenv "NYAA_IMAGE_PROBE")
                   (cl+ssl:reload))
                 (if (uiop:getenv "NYAA_IMAGE_PROBE")
                     (sb-ext:exit :code 0 :abort t)
                     (sb-impl::toplevel-init))))))
