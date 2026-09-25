(in-package #:nyaa/cli)

;;; `nyaa chat`: a line REPL over one agent, drawn from nyaa/ui's state.
;;; docs/chat.md.

(defvar *output-lock* (bt:make-lock :name "nyaa chat output")
  "Held while the chat writes, so what it printed can be read without a tear.")

(defparameter *abbreviate-at* 200)

(defparameter *prompt* "> ")

;;; --- drawing --------------------------------------------------------------

;;; The renderer prints only what a state adds to what it printed before. PROGRESS
;;; holds, per transcript index, the characters of a text entry printed, the phase
;;; of a call (1 announced, 2 answered), or :FINISHED. START is the first index that
;;; is not.

(defstruct (renderer (:constructor make-renderer (out)))
  out (progress (make-hash-table)) (start 0) (last-status :idle))

(defun abbreviate (object)
  (let ((text (let ((*print-pretty* nil)) (prin1-to-string object))))
    (if (> (length text) *abbreviate-at*)
        (format nil "~a..." (subseq text 0 *abbreviate-at*))
        text)))

(defun render-entry (renderer entry index superseded)
  "Print what ENTRY, at INDEX in the transcript, has added. SUPERSEDED is true
when a later entry exists, so it can no longer grow."
  (let ((out (renderer-out renderer))
        (progress (renderer-progress renderer)))
    (ecase (ui:entry-kind entry)
      (:text
       (let* ((text (ui:entry-text entry))
              (printed (gethash index progress 0)))
         (when (> (length text) printed)
           (write-string text out :start printed)
           (setf (gethash index progress) (length text)))
         (when superseded
           (setf (gethash index progress) :finished))))
      (:call
       (let ((phase (gethash index progress 0))
             (status (ui:entry-status entry)))
         (when (and (< phase 1) (member status '(:running :detached :done)))
           (format out "~&[~(~a~) ~a]~%" (ui:entry-name entry) (abbreviate (ui:entry-arguments entry)))
           (setf phase 1))
         (when (and (< phase 2) (eq status :done))
           (format out "~&[result ~a]~%" (abbreviate (ui:entry-result entry)))
           (setf phase 2))
         (setf (gethash index progress) (if (or (= phase 2) (eq status :abandoned)) :finished phase))))
      (:notice
       (format out "~&[~(~a~) ~a]~%" (ui:entry-name entry) (abbreviate (ui:entry-result entry)))
       (setf (gethash index progress) :finished))
      ((:message :steer)
       (setf (gethash index progress) :finished)))))

(defun render (renderer state)
  "Print what STATE adds to what RENDERER has printed, and a prompt when a run
has just ended."
  (bt:with-lock-held (*output-lock*)
    (let* ((out (renderer-out renderer))
           (entries (coerce (ui:state-transcript state) 'vector))
           (count (length entries))
           (progress (renderer-progress renderer)))
      (loop for index from (renderer-start renderer) below count
            unless (eq :finished (gethash index progress))
              do (render-entry renderer (aref entries index) index (< index (1- count))))
      (setf (renderer-start renderer)
            (or (loop for index from (renderer-start renderer) below count
                      unless (eq :finished (gethash index progress)) return index)
                count))
      (let ((status (ui:state-status state)))
        (when (and (eq status :done) (not (eq (renderer-last-status renderer) :done)))
          (fresh-line out)
          (unless (eq :stop (ui:state-reason state))
            (format out "[run ended: ~(~a~)]~%" (ui:state-reason state)))
          (write-string *prompt* out))
        (setf (renderer-last-status renderer) status))
      (finish-output out))))

;;; --- the session ----------------------------------------------------------

(defun already-running-p (answer)
  (equal answer '(:error (:bad-request "agent is already running"))))

(defun submit (client line)
  "Send LINE as the next prompt, or, when the agent is mid-run, as a steer. The
agent decides which: the state a client holds trails it. Answers what the
agent answered."
  (let ((answer (ui:continue-run client line)))
    (if (already-running-p answer)
        (ui:steer client line)
        answer)))

(defun handle-interrupt (client)
  "Ctrl-C: cancel the run under way and answer :CANCELLED, or :EXIT when idle."
  (cond ((eq :running (ui:state-status (ui:client-state client)))
         (ignore-errors (ui:cancel client))
         :cancelled)
        (t :exit)))

(defun next-line (in)
  (if (functionp in) (funcall in) (read-line in nil)))

(defun chat (options context in out err)
  "Chat with one agent until IN, a stream or a function answering a line or
nil, ends, and return an exit code. Ctrl-C cancels a run, or leaves the chat
when none is under way."
  (declare (ignore err))
  (multiple-value-bind (provider-name tools system) (prepare options context)
    (apply #'m:mount context 'nyaa:agent :name :chat :model provider-name :system system
           (agent-options options tools))
    (unwind-protect
         (let* ((renderer (make-renderer out))
                (client (ui:attach :chat :on-change (lambda (state) (render renderer state)))))
           (bt:with-lock-held (*output-lock*)
             (write-string *prompt* out)
             (finish-output out))
           (block session
             (handler-bind ((sb-sys:interactive-interrupt
                              (lambda (condition)
                                (declare (ignore condition))
                                (if (eq :cancelled (handle-interrupt client))
                                    (a:when-let ((restart (find-restart 'continue)))
                                      (invoke-restart restart))
                                    (return-from session 0)))))
               (loop
                 (let ((line (next-line in)))
                   (cond ((null line) (return-from session 0))
                         ((string= "" (string-trim '(#\Space #\Tab) line)))
                         (t (submit client line))))))))
      (m:unmount context :chat))))
