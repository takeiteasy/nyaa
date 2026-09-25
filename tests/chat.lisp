(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; `nyaa chat` (~takeiteasy/nyaa#99): the session against the echo provider,
;;; and its pieces against a stalling backend.

(defun count-prompts (text)
  (loop with start = 0
        for at = (search "> " text :start2 start)
        while at count t do (setf start (+ at 2))))

(defun chat-session (lines &rest args)
  "ARGS after `chat`, with LINES typed one at a time, each once the last run has
drawn its prompt. Answers the exit code, everything printed and, from the
agent as the input ended, its conversation's roles."
  (let* ((out (make-string-output-stream))
         (text "")
         (roles nil)
         (needed 1)
         (reader (lambda ()
                   (is-true (eventually
                             (lambda ()
                               (setf text (concatenate
                                           'string text
                                           (bt:with-lock-held (nyaa/cli::*output-lock*)
                                             (get-output-stream-string out))))
                               (>= (count-prompts text) needed))
                             5))
                   (if lines
                       (let ((line (pop lines)))
                         (unless (string= "" (string-trim " " line))
                           (incf needed))
                         line)
                       (progn
                         (setf roles (mapcar (lambda (message) (getf message :role))
                                             (getf (m:call (m:lookup :chat) '(:snapshot))
                                                   :messages)))
                         nil))))
         (err (make-string-output-stream))
         (code (nyaa/cli:main (cons "chat" args) :context *protocol-context*
                                                  :in reader :out out :err err)))
    (values code text roles (get-output-stream-string err))))

(test chat-answers-each-line-and-continues-the-conversation
  (with-protocol
    (multiple-value-bind (code text roles)
        (chat-session '("hello" "again") "--model" "test-echo:any")
      (is (= 0 code))
      (is (search "hello!" text))
      (is (search "again!" text))
      (is (equal '(:system :user :assistant :user :assistant) roles)))))

(test chat-ignores-blank-lines-and-ends-at-once-on-no-input
  (with-protocol
    (multiple-value-bind (code text roles err)
        (chat-session '("" "   ") "--model" "test-echo:any")
      (is (= 0 code) "~a" err)
      (is (equal "> " text))
      (is (null roles)))))

(test chat-unmounts-its-agent
  (with-protocol
    (chat-session '("hi") "--model" "test-echo:any")
    (is (null (m:lookup :chat)))))

(test chat-takes-no-prompt-and-shares-run-s-options
  (with-protocol
    (dolist (args '(("chat" "hello") ("chat" "--model" "nobody:x") ("chat" "--max-turns" "0")
                    ("chat" "--system-replace")))
      (multiple-value-bind (code out err) (apply #'cli args)
        (is (= 2 code) "~s exited ~a" args code)
        (is (equal "" out))
        (is (search "nyaa chat" err))))
    (is (= 3 (getf (nyaa/cli::parse-args '("--max-turns" "3") :takes-prompt nil) :max-turns)))))

;;; --- drawing --------------------------------------------------------------

(defun rendered (&rest event-lists)
  "What a renderer prints as each of EVENT-LISTS, in turn, is folded into a state."
  (let ((out (make-string-output-stream))
        (renderer (nyaa/cli::make-renderer nil))
        (state (ui:make-state))
        (printed '()))
    (setf (nyaa/cli::renderer-out renderer) out)
    (dolist (events event-lists)
      (setf state (ui:fold-events events state))
      (nyaa/cli::render renderer state)
      (push (get-output-stream-string out) printed))
    (nreverse printed)))

(test the-renderer-prints-only-what-a-state-adds
  (destructuring-bind (one two three four)
      (rendered (list (ev :run-start :messages '((:role :user :content "hi")) :continue nil)
                      (ev :turn :turn 1)
                      (ev :text-delta :text "hel"))
                (list (ev :text-delta :text "lo"))
                (list (ev :tool-call :id "c1" :name :shell :arguments '(:cmd "ls"))
                      (ev :tool-result :id "c1" :result '(:ok "x")))
                (list (ev :text-delta :text "done")
                      (ev :run-done :reason :stop)))
    (is (equal "hel" one))
    (is (equal "lo" two))
    (is (equal (format nil "~&[shell (:CMD \"ls\")]~%[result (:OK \"x\")]~%") (string-left-trim '(#\Newline) three)))
    (is (equal (format nil "done~%> ") four))))

(test a-run-that-does-not-stop-says-why
  (destructuring-bind (text)
      (rendered (list (ev :turn :turn 1) (ev :text-delta :text "x") (ev :run-done :reason :max-turns)))
    (is (search "[run ended: max-turns]" text))
    (is (equal "> " (subseq text (- (length text) 2))))))

(test a-long-result-is-abbreviated
  (let ((text (nyaa/cli::abbreviate (make-string 500 :initial-element #\a))))
    (is (< (length text) 300))
    (is (search "..." text))))

;;; --- the session against a run under way -----------------------------------

(test a-line-typed-mid-run-is-a-steer
  (let ((release (list nil)))
    (with-agent ((interruptible-backend release))
      (unwind-protect
           (progn
             (mount-assistant)
             (let ((client (ui:attach :assistant)))
               (is (eq :ok (nyaa/cli::submit client "go")))
               (is-true (eventually (lambda ()
                                      (entries-of :text (ui:state-root (ui:client-state client))))
                                    5))
               (is (eq :ok (nyaa/cli::submit client "shorter"))
                   "the second line is a steer, not a refused run")
               (is (eq :ok (nyaa/cli::submit client "shorter still")))))
        (setf (car release) t)))))

(test ctrl-c-cancels-a-run-and-leaves-an-idle-chat
  (let ((release (list nil)))
    (with-agent ((interruptible-backend release))
      (unwind-protect
           (progn
             (mount-assistant)
             (let ((client (ui:attach :assistant)))
               (is (eq :exit (nyaa/cli::handle-interrupt client)))
               (nyaa/cli::submit client "go")
               (is-true (eventually (lambda ()
                                      (entries-of :text (ui:state-root (ui:client-state client))))
                                    5))
               (is (eq :cancelled (nyaa/cli::handle-interrupt client)))
               (wait-for-status client :done)
               (is (eq :cancelled (ui:state-reason (ui:client-state client))))
               (is (eq :exit (nyaa/cli::handle-interrupt client)))))
        (setf (car release) t)))))
