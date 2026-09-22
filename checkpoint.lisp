(in-package #:nyaa)

;;; Generations (~takeiteasy/nyaa#11). A checkpoint is one s-expression file
;;; recording every named service's own declared state, taken through the
;;; SNAPSHOT/RESTORE convention (tool.lisp) shared by every tool, the agent
;;; and a provider. Rollback restores that state onto the services mounted
;;; now; it does not remount, so a service unmounted since the checkpoint is
;;; reported rather than rebuilt. A generation therefore carries a manifest
;;; of each child's name and class -- both already reported by M:CHILDREN --
;;; never its mount initargs, which is where a provider's :api-key would
;;; otherwise end up on disk (providers.md's credentials line, held the same
;;; way in tools/image.lisp).
;;;
;;; SBCL image generations -- SAVE-LISP-AND-DIE, relaunch-and-restore, an
;;; install-time recovery image -- are a follow-up, not this file. ECL gets
;;; only what is here, exactly as the ticket asks.
;;;
;;; The agent's own SNAPSHOT/RESTORE methods live at the end of agent.lisp,
;;; alongside the slots they read and write.

(defvar *generations-directory*
  (merge-pathnames ".nyaa/generations/" (user-homedir-pathname))
  "Default directory CHECKPOINT writes to and GENERATIONS lists from.")

;;; --- walking the mount tree ---------------------------------------------

(defun %context-entries (context-process)
  "Every named child under CONTEXT-PROCESS, recursively, as a flat list of
(:name :class :process). An unregistered child -- a delegated sub-agent,
whose name is nil (agent.lisp) -- is skipped, as is its own subtree."
  (loop for child in (m:children context-process)
        for name = (getf child :name)
        for class = (getf child :class)
        for process = (getf child :process)
        when name
          collect (list :name name :class (string-downcase (symbol-name class))
                        :process process)
        when (and name (subtypep class 'm:context) process)
          append (%context-entries process)))

;;; --- snapshot / restore across a process boundary ------------------------

;;; A reply of (:error ...) -- a service outside these three conventions,
;;; still answering the shared UNKNOWN-MESSAGE fallback -- is recorded as no
;;; state rather than failing the whole checkpoint. A transport failure
;;; (M:CALL's second value) is treated the same way.

(defun %snapshot-child (process)
  (multiple-value-bind (reply status) (m:call process '(:snapshot) :timeout 30)
    (if (or status (tool-error-p reply)) nil reply)))

(defun %restore-child (process state)
  (multiple-value-bind (reply status) (m:call process (list :restore state) :timeout 30)
    (declare (ignore reply))
    (not status)))

;;; --- the generation file --------------------------------------------------

(defun %generation-filename ()
  (multiple-value-bind (sec min hour day month year) (get-decoded-time)
    (format nil "~4,'0d~2,'0d~2,'0d-~2,'0d~2,'0d~2,'0d-~6,'0d.generation"
            year month day hour min sec (random 1000000))))

(defun %now-iso8601 ()
  (multiple-value-bind (sec min hour day month year) (get-decoded-time)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            year month day hour min sec)))

(defun %write-generation (path form)
  "FORM written to PATH through a temporary file in the same directory, then
renamed in, so a torn write never replaces a good generation."
  (uiop:with-temporary-file (:pathname tmp :directory (uiop:pathname-directory-pathname path)
                             :type "tmp" :keep t)
    (let ((*package* (find-package "KEYWORD")) (*print-case* :downcase))
      (a:write-string-into-file (prin1-to-string form) tmp :if-exists :supersede))
    (uiop:rename-file-overwriting-target tmp path)))

(defun %read-generation (path)
  "The form stored at PATH, read with *READ-EVAL* NIL so a generation can
never run code merely by being read back in -- the same guard tool-eval's
worker applies to a submitted form."
  (let ((*read-eval* nil) (*package* (find-package "KEYWORD")))
    (with-input-from-string (stream (a:read-file-into-string path))
      (read stream))))

;;; --- the API -------------------------------------------------------------

;; TODO: entries are snapshotted one M:CALL at a time, in mount order, so a
;; service busy in a long synchronous call (a protocol mid-HTTP-exchange, a
;; tool mid-command) makes every later entry wait behind it rather than
;; being skipped or run in parallel. Upgrade path: fan the calls out
;; concurrently and cap each on its own deadline independently of the
;; others. Tracked in ~takeiteasy/nyaa#51.

(defun %canonical-path (path)
  "PATH resolved to its TRUENAME when possible. A symlinked TMPDIR (macOS's
/var, say) resolves differently under a plain MERGE-PATHNAMES than under a
directory listing, and the two implementations disagree on which side does
the resolving -- so CHECKPOINT's return and GENERATIONS' own :path both go
through this, and always compare equal to each other."
  (or (ignore-errors (truename path)) path))

(defun checkpoint (context &key (dir *generations-directory*) label keep)
  "Snapshot every named service under CONTEXT, a mounted context's process,
recursively, and write it as a generation file under DIR. Returns the
generation's pathname. KEEP, given, prunes DIR to its KEEP newest
generations afterwards."
  (let* ((entries (%context-entries context))
         (services (mapcar (lambda (entry)
                              (list :name (getf entry :name)
                                    :class (getf entry :class)
                                    :state (%snapshot-child (getf entry :process))))
                            entries))
         (directory (uiop:ensure-directory-pathname dir))
         (path (merge-pathnames (%generation-filename) directory)))
    (ensure-directories-exist directory)
    (%write-generation path
                       (list :nyaa-generation 1 :created (%now-iso8601)
                             :label label :services services))
    (when keep (%prune-generations directory keep))
    (%canonical-path path)))

(defun generations (&key (dir *generations-directory*))
  "Every generation under DIR, newest first, as (:path :created :label
:services), :services naming the services it covers rather than their
state."
  (sort (loop for path in (ignore-errors
                            (uiop:directory-files (uiop:ensure-directory-pathname dir)
                                                  "*.generation"))
              for generation = (ignore-errors (%read-generation path))
              when generation
                collect (list :path (namestring (%canonical-path path))
                              :created (getf generation :created)
                              :label (getf generation :label)
                              :services (mapcar (lambda (entry) (getf entry :name))
                                                (getf generation :services))))
        ;; The filename is timestamp-then-random, so sorting by it (rather
        ;; than :CREATED, which two generations in the same second share)
        ;; is both newest-first and a total order -- PRUNE-GENERATIONS
        ;; must never be able to tie-break away the one CHECKPOINT just
        ;; wrote.
        #'string> :key (lambda (g) (getf g :path))))

(defun %prune-generations (dir keep)
  (dolist (stale (nthcdr keep (generations :dir dir)))
    (ignore-errors (delete-file (getf stale :path)))))

(defun rollback (context path)
  "Restore the generation at PATH onto CONTEXT's named services now.
Returns (:ok (:restored names :missing names :mismatched entries :extra
names)). MISSING names a generation entry with no service mounted under
that name now; MISMATCHED one mounted under a different class, which is
reported rather than restored; EXTRA a service mounted now the generation
does not name. None of these fails the call -- the caller decides what
drift means."
  (let* ((generation (%read-generation path))
         (recorded (getf generation :services))
         (current (%context-entries context))
         (restored '()) (missing '()) (mismatched '()))
    (dolist (entry recorded)
      (let* ((name (getf entry :name))
             (found (find name current :key (lambda (e) (getf e :name)))))
        (cond
          ((null found) (push name missing))
          ((not (string= (getf entry :class) (getf found :class)))
           (push (list :name name :expected (getf entry :class)
                       :actual (getf found :class))
                 mismatched))
          (t (%restore-child (getf found :process) (getf entry :state))
             (push name restored)))))
    (ok :restored (nreverse restored) :missing (nreverse missing)
        :mismatched (nreverse mismatched)
        :extra (set-difference (mapcar (lambda (e) (getf e :name)) current)
                               (mapcar (lambda (e) (getf e :name)) recorded)))))
