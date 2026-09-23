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
;;; Nothing is ever rewritten -- VAULT-ENTRIES folds the log into current
;;; state, the same way GENERATIONS derives its list from files on disk
;;; rather than an index.
;;;
;;; TODO: VAULT-ENTRIES reads and folds the whole file on every call, and
;;; the file itself never shrinks, so both cost grows without bound as
;;; entries pile up. Upgrade path: compact the log by rewriting it with
;;; already-consumed entries dropped, past some age or size threshold.
;;; Tracked in ~takeiteasy/nyaa#67.

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

(defun vault-record (path agent content)
  "Append a :STEER entry to PATH and return its id. AGENT, a keyword or nil,
names the target agent when it is registered under one; a delegated
sub-agent has no name (agent.lisp, checkpoint.lisp's %CONTEXT-ENTRIES), so
nil is recorded and a later VAULT-RESTORE-TARGET call must be given one
explicitly."
  (let ((id (%vault-id)))
    (%append-log path (list :kind :steer :id id :at (%now-iso8601)
                            :agent agent :content content))
    id))

(defun vault-consume (path id how)
  "Append a :CONSUMED entry marking ID as HOW (:FOLDED or :DISCARDED)."
  (%append-log path (list :kind :consumed :id id :at (%now-iso8601) :how how)))

(defun vault-entries (path)
  "Every :STEER entry logged at PATH, oldest first, folded against any
:CONSUMED entries that followed it: (:id :at :agent :content :status
(:PENDING :FOLDED or :DISCARDED) :consumed-at). An id with no :STEER entry
-- a :CONSUMED line with nothing to consume -- is dropped rather than
surfaced, since it names nothing a caller could act on."
  (let ((log (%read-log path)))
    (loop for entry in log
          when (eq (getf entry :kind) :steer)
            collect (let ((consumed (find (getf entry :id) log
                                          :key (lambda (e) (and (eq (getf e :kind) :consumed)
                                                                (getf e :id)))
                                          :test #'equal)))
                      (list :id (getf entry :id) :at (getf entry :at)
                            :agent (getf entry :agent) :content (getf entry :content)
                            :status (if consumed (getf consumed :how) :pending)
                            :consumed-at (and consumed (getf consumed :at)))))))
