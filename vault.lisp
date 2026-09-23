(in-package #:nyaa)

;;; The vault (~takeiteasy/nyaa#14): an append-only s-expression log of
;;; steering messages, each marked consumed once it has been folded into a
;;; run or discarded. Backs AGENT's own in-memory steer queue
;;; (agent.lisp's QUEUE-STEER/ISSUE-TURN) so a steer survives past the run
;;; it was sent to, a crash, or a restart -- not just the next turn.
;;;
;;; The log is two entry kinds, both plists, read back the same guarded way
;;; a generation or the self log is (checkpoint.lisp's %APPEND-LOG/
;;; %READ-LOG): *READ-EVAL* nil, so nothing here can run code merely by
;;; being read.
;;;
;;;   (:kind :steer    :id "..." :at "iso" :agent name-or-nil :content "...")
;;;   (:kind :consumed :id "..." :at "iso" :how :folded-or-:discarded)
;;;
;;; VAULT-ENTRIES folds the log into current state, the same way GENERATIONS
;;; derives its list from files on disk rather than an index. VAULT-COMPACT
;;; rewrites the log without consumed entries past a maximum age, on demand
;;; and automatically once the file grows past a size threshold.
;;;
;;; TODO: compaction is safe within one process only -- another process
;;; appending between its read and its rename loses that entry. Upgrade
;;; path: an flock on the log file. Tracked in ~takeiteasy/nyaa#84.

(defvar *vault-max-age* (* 7 24 60 60)
  "Seconds a consumed entry is kept before VAULT-COMPACT drops it.")

(defvar *vault-compact-size* (* 1024 1024)
  "Log size in bytes past which an append compacts the log.")

(defvar *vault-log* nil
  "Default log path: ~/.nyaa/vault.log, resolved lazily so loading this file
never touches the filesystem or the user's home.")

(defun %default-vault-log ()
  (or *vault-log*
      (setf *vault-log* (merge-pathnames ".nyaa/vault.log" (user-homedir-pathname)))))

(defun %vault-path (spec)
  "SPEC, an agent's :VAULT mount option, as a log path: T means the default,
anything else is used as given -- a string or pathname."
  (if (eq spec t) (%default-vault-log) spec))

(defun %vault-id ()
  "A fresh id: a timestamp plus a random suffix, in %GENERATION-FILENAME's
own style -- unique enough for one operator's log, sortable, and never
reused even across a restart."
  (multiple-value-bind (sec min hour day month year) (get-decoded-time)
    (format nil "~4,'0d~2,'0d~2,'0d-~2,'0d~2,'0d~2,'0d-~6,'0d"
            year month day hour min sec (random 1000000))))

(defvar *vault-compacted-sizes* (make-hash-table :test 'equal)
  "Canonical log namestring -> its size after the last compaction attempt.
Guarded by *LOG-LOCKS-LOCK*.")

(defun %log-size (path)
  (with-open-file (stream path :if-does-not-exist nil)
    (if stream (file-length stream) 0)))

(defun %vault-maybe-compact (path)
  "Compact PATH once it has doubled since the last attempt and passed
*VAULT-COMPACT-SIZE*. A failure never reaches the caller: the log is
rewritten through a temporary file, so the original survives one."
  (let* ((key (%log-key path))
         (size (%log-size path))
         (last (bt:with-lock-held (*log-locks-lock*)
                 (gethash key *vault-compacted-sizes* 0))))
    (when (>= size (max *vault-compact-size* (* 2 last)))
      (ignore-errors (vault-compact path))
      (let ((after (or (ignore-errors (%log-size path)) size)))
        (bt:with-lock-held (*log-locks-lock*)
          (setf (gethash key *vault-compacted-sizes*) after))))))

(defun vault-record (path agent content)
  "Append a :STEER entry to PATH and return its id. AGENT, a keyword or nil,
names the target agent when it is registered under one; a delegated
sub-agent has no name (agent.lisp, checkpoint.lisp's %CONTEXT-ENTRIES), so
nil is recorded and a later VAULT-RESTORE-TARGET call must be given one
explicitly."
  (let ((id (%vault-id)))
    (%append-log path (list :kind :steer :id id :at (%now-iso8601)
                            :agent agent :content content))
    (%vault-maybe-compact path)
    id))

(defun vault-consume (path id how)
  "Append a :CONSUMED entry marking ID as HOW (:FOLDED or :DISCARDED)."
  (%append-log path (list :kind :consumed :id id :at (%now-iso8601) :how how))
  (%vault-maybe-compact path))

(defun %consumed-by-id (log)
  "LOG's :CONSUMED entries by id, the first one winning."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry log table)
      (when (eq (getf entry :kind) :consumed)
        (unless (nth-value 1 (gethash (getf entry :id) table))
          (setf (gethash (getf entry :id) table) entry))))))

(defun vault-entries (path)
  "Every :STEER entry logged at PATH, oldest first, folded against any
:CONSUMED entries that followed it: (:id :at :agent :content :status
(:PENDING :FOLDED or :DISCARDED) :consumed-at). An id with no :STEER entry
-- a :CONSUMED line with nothing to consume -- is dropped rather than
surfaced, since it names nothing a caller could act on."
  (let* ((log (%read-log path))
         (consumed (%consumed-by-id log)))
    (loop for entry in log
          when (eq (getf entry :kind) :steer)
            collect (let ((done (gethash (getf entry :id) consumed)))
                      (list :id (getf entry :id) :at (getf entry :at)
                            :agent (getf entry :agent) :content (getf entry :content)
                            :status (if done (getf done :how) :pending)
                            :consumed-at (and done (getf done :at)))))))

(defun vault-compact (path &key (max-age *vault-max-age*))
  "Rewrite PATH without the steers consumed more than MAX-AGE seconds ago
(0 drops every consumed one) and their :CONSUMED lines. Returns the steers
dropped and the steers kept, or nil, leaving the file untouched, when the
log has a malformed entry -- rewriting it would lose everything past that
entry."
  (bt:with-lock-held ((%log-lock path))
    (multiple-value-bind (log clean) (%read-log path)
      (when clean
        (let* ((cutoff (%now-iso8601 (- (get-universal-time) max-age)))
               (expired (make-hash-table :test 'equal))
               (dropped 0) (kept 0))
          (maphash (lambda (id entry)
                     (let ((at (getf entry :at)))
                       (when (or (zerop max-age) (not (stringp at)) (string< at cutoff))
                         (setf (gethash id expired) t))))
                   (%consumed-by-id log))
          (let ((survivors (remove-if (lambda (entry) (gethash (getf entry :id) expired))
                                      log)))
            (dolist (entry log)
              (when (and (eq (getf entry :kind) :steer) (gethash (getf entry :id) expired))
                (incf dropped)))
            (setf kept (count :steer survivors :key (lambda (e) (getf e :kind))))
            (when (plusp dropped) (%write-log path survivors))
            (values dropped kept)))))))
