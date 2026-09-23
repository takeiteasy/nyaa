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

;;; A steer sitting in an agent's in-memory queue, or one a :RESTORE has cast
;;; at an agent, is claimed: still :PENDING in the log, but no second delivery
;;; may be started for it. The claim is persisted in the log, so other
;;; processes see it, and ends when the entry is consumed, released, or its
;;; owner process is gone.
;;;
;;;   (:kind :claimed  :id "..." :at "iso" :by owner)
;;;   (:kind :released :id "..." :at "iso")
;;;
;;; A steer an agent records for itself carries :CLAIMED-BY on its :STEER
;;; entry instead, so recording and claiming are one append.

;; TODO: a saved core carries this token to every process launched from it,
;; and a relaunch keeps claims made before it. Upgrade path: reset it in
;; sb-ext:*save-hooks* and release claims on relaunch. Tracked in
;; ~takeiteasy/nyaa#91.
(defvar *vault-token* nil
  "A random string naming this image, so its claims are recognised as its own
even when a pid is reused.")

#+linux
(defun %proc-stat-fields (line)
  "The whitespace-separated fields of /proc/<pid>/stat after its command name."
  (let ((start (+ 2 (position #\) line :from-end t)))
        (fields '()))
    (loop with from = start
          for end = (position #\Space line :start from)
          do (push (subseq line from end) fields)
          while end do (setf from (1+ end)))
    (nreverse fields)))

(defun %process-start-time (pid)
  "An opaque integer that changes when PID is reused by a new process, or nil
when it cannot be read."
  (ignore-errors
   #+darwin
   (sb-alien:with-alien ((mib (array sb-alien:int 4))
                         (buf (array (sb-alien:unsigned 8) 1024))
                         (len sb-alien:unsigned-long 1024))
     (loop for i from 0 for v in (list 1 14 1 pid) do (setf (sb-alien:deref mib i) v))
     (when (and (zerop (sb-alien:alien-funcall
                        (sb-alien:extern-alien
                         "sysctl" (function sb-alien:int (* sb-alien:int) sb-alien:unsigned-int
                                            (* t) (* sb-alien:unsigned-long) (* t) sb-alien:unsigned-long))
                        (sb-alien:cast mib (* sb-alien:int)) 4
                        (sb-alien:cast buf (* t)) (sb-alien:addr len) nil 0))
                (plusp len))
       (let ((sap (sb-alien:alien-sap buf)))
         (+ (* 1000000 (sb-sys:signed-sap-ref-64 sap 0))
            (sb-sys:signed-sap-ref-32 sap 8)))))
   #+linux
   (with-open-file (stream (format nil "/proc/~d/stat" pid))
     (let* ((line (read-line stream))
            (fields (%proc-stat-fields line)))
       (parse-integer (nth 19 fields))))))

(defun %vault-owner ()
  "This image's claim owner: (:pid :host :start :token). The start time is
read on every call, never cached: a saved core would carry it to a process
with a different one."
  (let ((pid (sb-posix:getpid)))
    (list :pid pid :host (machine-instance) :start (%process-start-time pid)
          :token (or *vault-token*
                     (setf *vault-token*
                           (format nil "~36r" (random (expt 2 64) (make-random-state t))))))))

(defun %claim-live-p (owner)
  "True when OWNER, a :CLAIMED-BY plist, is this image, on another host
(flock is host-local, so it cannot be probed), or a process still running
here that started when the claim was made. A claim or process with no
readable start time is judged by its pid alone."
  (let ((pid (getf owner :pid))
        (start (getf owner :start)))
    (or (equal (getf owner :token) (getf (%vault-owner) :token))
        (not (equal (getf owner :host) (machine-instance)))
        (not (integerp pid))
        (and (handler-case (progn (sb-posix:kill pid 0) t)
               (sb-posix:syscall-error (e) (= (sb-posix:syscall-errno e) sb-posix:eperm)))
             (let ((now (and start (%process-start-time pid))))
               (or (null now) (eql start now)))))))

(defun %claims-by-id (log)
  "LOG's current claim owner by id, the latest entry winning."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry log table)
      (let ((id (getf entry :id)))
        (case (getf entry :kind)
          (:steer (when (getf entry :claimed-by) (setf (gethash id table) (getf entry :claimed-by))))
          (:claimed (setf (gethash id table) (getf entry :by)))
          (:released (remhash id table)))))))

(defun %live-claim (claims id)
  (let ((owner (gethash id claims)))
    (and owner (%claim-live-p owner) owner)))

(defun %pending-state (log id)
  "ID's state in LOG: :UNKNOWN for an id with no :STEER entry, its :HOW once
consumed, :HELD when a live claim holds it, or nil when it is pending and
free."
  (let ((done (gethash id (%consumed-by-id log))))
    (cond ((notany (lambda (e) (and (eq (getf e :kind) :steer) (equal (getf e :id) id))) log)
           :unknown)
          (done (getf done :how))
          ((%live-claim (%claims-by-id log) id) :held))))

(defun vault-claim-pending (path id)
  "Claim ID at PATH if it is a :PENDING steer nobody has claimed, checked and
claimed under PATH's lock. Returns :CLAIMED, :UNKNOWN for an id with no
:STEER entry, :HELD when it is already claimed, or the status it already
has."
  (with-log-lock (path)
    (or (%pending-state (%read-log path) id)
        (progn (%append-log-locked path (list :kind :claimed :id id :at (%now-iso8601)
                                              :by (%vault-owner)))
               :claimed))))

;; TODO: each release reads and folds the whole log, so dropping n queued
;; steers costs n reads. Upgrade path: a batch release under one lock hold.
;; Tracked in ~takeiteasy/nyaa#90.
(defun vault-release (path id)
  "Drop this image's claim on ID at PATH, if it still holds one."
  (with-log-lock (path)
    (let ((log (%read-log path)))
      (when (and (not (gethash id (%consumed-by-id log)))
                 (equal (getf (gethash id (%claims-by-id log)) :token)
                        (getf (%vault-owner) :token)))
        (%append-log-locked path (list :kind :released :id id :at (%now-iso8601)))))))

(defun vault-record (path agent content &key claim)
  "Append a :STEER entry to PATH and return its id, claimed by this image
when CLAIM. AGENT, a keyword or nil, names the target agent when it is
registered under one; a delegated sub-agent has no name (agent.lisp,
checkpoint.lisp's %CONTEXT-ENTRIES), so nil is recorded and a later
VAULT-RESTORE-TARGET call must be given one explicitly."
  (let ((id (%vault-id)))
    (%append-log path (list* :kind :steer :id id :at (%now-iso8601)
                             :agent agent :content content
                             (and claim (list :claimed-by (%vault-owner)))))
    (%vault-maybe-compact path)
    id))

(defun vault-consume (path id how)
  "Append a :CONSUMED entry marking ID as HOW (:FOLDED or :DISCARDED)."
  (%append-log path (list :kind :consumed :id id :at (%now-iso8601) :how how))
  (%vault-maybe-compact path))

(defun vault-consume-pending (path id how)
  "Append a :CONSUMED entry marking ID as HOW, only if ID is a :PENDING
steer nobody has claimed, checked and appended under PATH's lock. Returns
:CONSUMED, :UNKNOWN for an id with no :STEER entry, :HELD when it is claimed,
or the status it already has."
  (let ((result
          (with-log-lock (path)
            (or (%pending-state (%read-log path) id)
                (progn (%append-log-locked
                        path (list :kind :consumed :id id :at (%now-iso8601) :how how))
                       :consumed)))))
    (when (eq result :consumed) (%vault-maybe-compact path))
    result))

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
(:PENDING :FOLDED or :DISCARDED) :consumed-at :claimed), :CLAIMED true for a
pending steer held by an agent's queue or a restore. An id with no :STEER entry
-- a :CONSUMED line with nothing to consume -- is dropped rather than
surfaced, since it names nothing a caller could act on."
  (let* ((log (%read-log path))
         (consumed (%consumed-by-id log))
         (claims (%claims-by-id log)))
    (loop for entry in log
          when (eq (getf entry :kind) :steer)
            collect (let ((done (gethash (getf entry :id) consumed)))
                      (list :id (getf entry :id) :at (getf entry :at)
                            :agent (getf entry :agent) :content (getf entry :content)
                            :status (if done (getf done :how) :pending)
                            :consumed-at (and done (getf done :at))
                            :claimed (and (not done) (%live-claim claims (getf entry :id)) t))))))

(defun %fold-claim (steer owner)
  "STEER with its :CLAIMED-BY set to OWNER, or removed when OWNER is nil."
  (let ((plain (loop for (k v) on steer by #'cddr unless (eq k :claimed-by) append (list k v))))
    (if owner (append plain (list :claimed-by owner)) plain)))

(defun vault-compact (path &key (max-age *vault-max-age*))
  "Rewrite PATH without the steers consumed more than MAX-AGE seconds ago
(0 drops every consumed one) and their :CONSUMED lines. Returns the steers
dropped and the steers kept, or nil, leaving the file untouched, when the
log has a malformed entry -- rewriting it would lose everything past that
entry."
  (with-log-lock (path)
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
          (let* ((claims (%claims-by-id log))
                 (survivors
                   (loop for entry in (remove-if (lambda (entry) (gethash (getf entry :id) expired))
                                                 log)
                         for kind = (getf entry :kind)
                         unless (member kind '(:claimed :released))
                           collect (if (eq kind :steer)
                                       (%fold-claim entry (%live-claim claims (getf entry :id)))
                                       entry))))
            (dolist (entry log)
              (when (and (eq (getf entry :kind) :steer) (gethash (getf entry :id) expired))
                (incf dropped)))
            (setf kept (count :steer survivors :key (lambda (e) (getf e :kind))))
            (when (or (plusp dropped) (not (equal survivors log)))
              (%write-log path survivors))
            (values dropped kept)))))))
