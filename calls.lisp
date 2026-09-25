(in-package #:nyaa)

;;; The call log (~takeiteasy/nyaa#73): an append-only s-expression log with
;;; one record per tool call an agent dispatches, so a call's status outlives
;;; the process running it. Read back the same guarded way the vault is
;;; (checkpoint.lisp's %APPEND-LOG/%READ-LOG).
;;;
;;;   (:kind :call    :id "..." :at "iso" :agent name-or-nil :call-id "c1"
;;;    :name :tool-echo :arguments "<json>" :turn 2 :by owner)
;;;   (:kind :running :id "..." :at "iso")
;;;   (:kind :done    :id "..." :at "iso" :outcome :ok :content "<json>")
;;;
;;; :ID is the log's own, fresh per dispatch: a provider may reuse :CALL-ID on
;;; a later turn. CALL-ENTRIES folds the log into current state.

(defvar *call-log-max-age* (* 7 24 60 60)
  "Seconds a finished call is kept before CALL-LOG-COMPACT drops it.")

(defvar *call-log-compact-size* (* 1024 1024)
  "Log size in bytes past which an append compacts the log.")

(defvar *call-log-max-content* (* 16 1024)
  "Characters of a call's arguments or result kept when the agent has no
:MAX-TOOL-RESULT.")

(defvar *call-log* nil
  "Default log path: ~/.nyaa/calls.log, resolved lazily.")

(defun %call-log-path (spec)
  "SPEC, an agent's :CALL-LOG mount option, as a log path: NIL means off, T the
default, anything else is used as given."
  (cond ((eq spec t)
         (or *call-log*
             (setf *call-log* (merge-pathnames ".nyaa/calls.log" (user-homedir-pathname)))))
        (t spec)))

(defun call-log-accept (path agent turn calls &key (cap *call-log-max-content*))
  "Append a :CALL entry for each of CALLS, plists of :ID, :NAME and :ARGUMENTS,
under one lock hold, and return their log ids in order."
  (let ((owner (%vault-owner))
        (base (%vault-id)))
    (with-log-lock (path)
      (prog1 (loop for call in calls
                   for index from 0
                   for id = (format nil "~a-~d" base index)
                   do (%append-log-locked
                       path (list :kind :call :id id :at (%now-iso8601) :agent agent
                                  :call-id (getf call :id) :name (getf call :name)
                                  :arguments (%cut-text (json:stringify
                                                         (untyped->json (getf call :arguments)))
                                                        cap)
                                  :turn turn :by owner))
                   collect id)))))

(defun call-log-running (path ids)
  (when ids
    (with-log-lock (path)
      (dolist (id ids)
        (%append-log-locked path (list :kind :running :id id :at (%now-iso8601)))))))

(defun call-log-done (path results)
  "Append a :DONE entry for each of RESULTS, lists of a log id, an outcome
(:OK, :ERROR, :INTERRUPTED or :ABANDONED) and the text kept, under one lock
hold. A call already done keeps its first outcome."
  (when results
    (with-log-lock (path)
      (dolist (result results)
        (destructuring-bind (id outcome content) result
          (%append-log-locked path (list :kind :done :id id :at (%now-iso8601)
                                         :outcome outcome :content content)))))
    (%maybe-compact path *call-log-compact-size* #'call-log-compact)))

(defun %done-by-id (log)
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry log table)
      (when (eq (getf entry :kind) :done)
        (unless (nth-value 1 (gethash (getf entry :id) table))
          (setf (gethash (getf entry :id) table) entry))))))

(defun call-entries (path)
  "Every call logged at PATH, oldest first: (:id :at :agent :call-id :name
:arguments :turn :status :done-at :content). :STATUS is :ACCEPTED, :RUNNING,
the :OUTCOME of its :DONE entry, or :LOST when the process that accepted it is
gone and nothing finished it."
  (let* ((log (%read-log path))
         (done (%done-by-id log))
         (running (make-hash-table :test 'equal)))
    (dolist (entry log)
      (when (eq (getf entry :kind) :running)
        (setf (gethash (getf entry :id) running) t)))
    (loop for entry in log
          when (eq (getf entry :kind) :call)
            collect (let* ((id (getf entry :id))
                           (end (gethash id done)))
                      (list :id id :at (getf entry :at) :agent (getf entry :agent)
                            :call-id (getf entry :call-id) :name (getf entry :name)
                            :arguments (getf entry :arguments) :turn (getf entry :turn)
                            :status (cond (end (getf end :outcome))
                                          ((not (%claim-live-p (getf entry :by))) :lost)
                                          ((gethash id running) :running)
                                          (t :accepted))
                            :done-at (getf end :at)
                            :content (getf end :content))))))

(defun call-log-compact (path &key (max-age *call-log-max-age*))
  "Rewrite PATH without the calls finished more than MAX-AGE seconds ago (0
drops every finished one) and their :RUNNING and :DONE lines. Calls not
finished are kept. Returns the calls dropped and kept, or nil, leaving the
file untouched, when the log has a malformed entry."
  (with-log-lock (path)
    (multiple-value-bind (log clean) (%read-log path)
      (when clean
        (let ((cutoff (%now-iso8601 (- (get-universal-time) max-age)))
              (expired (make-hash-table :test 'equal))
              (dropped 0))
          (maphash (lambda (id entry)
                     (let ((at (getf entry :at)))
                       (when (or (zerop max-age) (not (stringp at)) (string< at cutoff))
                         (setf (gethash id expired) t))))
                   (%done-by-id log))
          (let ((survivors (remove-if (lambda (entry) (gethash (getf entry :id) expired)) log)))
            (dolist (entry log)
              (when (and (eq (getf entry :kind) :call) (gethash (getf entry :id) expired))
                (incf dropped)))
            (when (plusp dropped) (%write-log path survivors))
            (values dropped (count :call survivors :key (lambda (e) (getf e :kind))))))))))
