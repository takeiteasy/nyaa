(in-package #:nyaa)

;;; The vault tool (~takeiteasy/nyaa#14): list, restore and discard entries
;;; in the steering message log vault.lisp keeps. Restoring casts a :STEER
;;; straight at the named agent (agent.lisp), passing the entry's own id
;;; back as :VAULT-ID so ISSUE-TURN marks it consumed rather than this tool
;;; recording a second entry for the same steer.
;;;
;;; :trust :operator: restoring injects a :USER-role message into whichever
;;; agent is named, and listing surfaces operator-written steering text --
;;; the same posture as tool-checkpoint's own writes to harness state.

(define-tool :tool-vault
    (:trust :operator
     :summary "List, restore and discard entries in the steering message vault"
     :slots ((path :initarg :path :initform nil :reader vault-tool-path
                   :documentation "Log path this mount reads and writes. NIL
(the default) uses the same default an agent's :VAULT T does."))
     :params ((:op (member :list :restore :discard) :required t
               :doc "operation to perform")
              (:id string :doc "vault entry id, for :restore and :discard")
              (:agent string :doc "target agent name for :restore; required
when the entry was recorded with no agent (a delegated sub-agent has none),
and overrides the recorded one otherwise")
              (:status (member :pending :folded :discarded :all) :default :pending
               :doc "filter for :list")
              (:limit (integer 1 1000) :default 50 :doc "entries to answer, for :list")))
  (:invoke (op id agent status limit)
    (case op
      (:list (op-vault-list (vault-log-path service) status limit))
      (:restore (op-vault-restore service id agent))
      (:discard (op-vault-discard (vault-log-path service) id)))))

(defun vault-log-path (service)
  (%vault-path (or (vault-tool-path service) t)))

(defun %vault-find (path id)
  (find id (vault-entries path) :key (lambda (e) (getf e :id)) :test #'equal))

(defun op-vault-list (path status limit)
  (let ((entries (if (eq status :all)
                     (vault-entries path)
                     (remove-if-not (lambda (e) (eq (getf e :status) status))
                                    (vault-entries path)))))
    (ok :entries (last entries limit) :total (length entries))))

(defun op-vault-restore (service id agent-name)
  (cond
    ((null id) (bad-request ":id is required for :restore"))
    (t (let ((entry (%vault-find (vault-log-path service) id)))
         (cond
           ((null entry) (bad-request "no vault entry ~a" id))
           ((not (eq (getf entry :status) :pending))
            (bad-request "vault entry ~a is already ~(~a~)" id (getf entry :status)))
           (t (op-vault-restore-into service id entry agent-name)))))))

(defun op-vault-restore-into (service id entry agent-name)
  (let ((target (or (and agent-name (a:make-keyword (string-upcase agent-name)))
                    (getf entry :agent))))
    (if (null target)
        (bad-request ":agent is required to restore an entry recorded with no agent")
        (let ((process (m:lookup target :registry (m:service-registry service))))
          (if (null process)
              (bad-request "no agent named ~(~a~)" target)
              (progn
                (m:cast process (list :steer :content (getf entry :content) :vault-id id))
                (ok :agent target :id id)))))))

(defun op-vault-discard (path id)
  (cond
    ((null id) (bad-request ":id is required for :discard"))
    (t (let ((entry (%vault-find path id)))
         (cond
           ((null entry) (bad-request "no vault entry ~a" id))
           ((not (eq (getf entry :status) :pending))
            (bad-request "vault entry ~a is already ~(~a~)" id (getf entry :status)))
           (t (vault-consume path id :discarded) (ok :id id)))))))
