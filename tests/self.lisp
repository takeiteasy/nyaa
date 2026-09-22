(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; TOOL-SELF (~takeiteasy/nyaa#12): the write ops refused unless :ENABLE
;;; names them, the checkpoint-then-log sequence around each write, and
;;; :EVAL, :DEFINE and :RELOAD themselves.
;;;
;;; Definitions made through :EVAL/:DEFINE land in NYAA-SELF-TEST, a scratch
;;; package created before and deleted after every test -- nothing here
;;; ever redefines a NYAA:: symbol. STATEFUL-THING, THING and SET-THING are
;;; tests/checkpoint.lisp's.

(defvar *self-context* nil)
(defvar *self-log-path* nil)
(defvar *self-dir* nil)

(defun make-self-log-path ()
  (format nil "~anyaa-self-test-~36r.log"
          (namestring (uiop:temporary-directory))
          (random (expt 2 64) (make-random-state t))))

(defun call-with-self (enable body)
  (let* ((registry (make-instance 'm:registry))
         (m:*registry* registry)
         (log (make-self-log-path)))
    (setf *self-log-path* log)
    (or (find-package "NYAA-SELF-TEST") (make-package "NYAA-SELF-TEST" :use '("CL")))
    (unwind-protect
         (with-generations-directory (dir)
           (setf *self-dir* dir)
           (let ((context (m:start-service (make-instance 'm:context :name :self-tools)
                                           :registry registry)))
             (setf *self-context* context)
             (unwind-protect
                  (progn
                    (m:mount context 'stateful-thing)
                    (m:mount context 'nyaa:tool-self :enable enable :dir dir :log log)
                    (funcall body))
               (m:stop context))))
      (delete-package "NYAA-SELF-TEST")
      (ignore-errors (delete-file log)))))

(defmacro with-self ((&optional (enable ''(:eval :define :reload))) &body body)
  `(call-with-self ,enable (lambda () ,@body)))

(defun self (op &rest args)
  (apply #'nyaa:invoke-tool :tool-self :op op args))

;;; --- trust and gating --------------------------------------------------

(test tool-self-is-operator-trusted
  (with-self ()
    (is (eq :operator (nyaa:tool-trust (nyaa:describe-tool :tool-self))))))

(test tool-self-write-ops-refused-when-not-enabled
  (with-self (nil)
    (dolist (call (list (list :eval :form "1")
                        (list :define :form "(defun nyaa-self-test::f () 1)")
                        (list :reload :name "stateful-thing")))
      (let ((result (apply #'self call)))
        (is (equal :forbidden (first (nyaa:tool-error result))))))))

(test tool-self-log-always-answers-even-disabled
  (with-self (nil)
    (is (eq :ok (first (self :log))))))

;;; --- :eval ---------------------------------------------------------

(test self-eval-returns-value-and-output
  (with-self ()
    (let ((result (self :eval :form "(progn (princ \"hi\") (+ 1 2))")))
      (is (eq :ok (first result)))
      (is (equal "3" (getf (second result) :value)))
      (is (equal "hi" (getf (second result) :out))))))

(test self-eval-a-signalling-form-is-an-error-not-a-crash
  (with-self ()
    (let ((result (self :eval :form "(error \"boom\")")))
      (is (eq :error (first result))))
    ;; the service is still answering afterwards
    (is (eq :ok (first (self :eval :form "1"))))))

(test self-eval-unreadable-source-is-a-bad-request-with-no-checkpoint
  (with-self ()
    (let ((before (length (nyaa:generations :dir *self-dir*)))
          (result (self :eval :form "(+ 1")))
      (is (equal :bad-request (first (nyaa:tool-error result))))
      (is (= before (length (nyaa:generations :dir *self-dir*)))))))

(test self-eval-past-its-timeout-times-out-and-recovers
  (with-self ()
    (let ((result (self :eval :form "(sleep 1)" :timeout 50)))
      (is (equal :timeout (nyaa:tool-error result))))
    (is (eq :ok (first (self :eval :form "1"))))))

;;; --- :define -------------------------------------------------------

(test self-define-defines-a-function-in-the-named-package
  (with-self ()
    (let ((result (self :define :form "(defun greet () :hi)" :package "NYAA-SELF-TEST")))
      (is (eq :ok (first result))))
    (is (eq :hi (funcall (find-symbol "GREET" "NYAA-SELF-TEST"))))))

(test self-define-refuses-a-non-definition-form
  (with-self ()
    (let ((result (self :define :form "(+ 1 2)")))
      (is (equal :bad-request (first (nyaa:tool-error result)))))))

(test self-define-redefines-a-class-and-updates-a-live-instance
  (with-self ()
    (eval (read-from-string
           "(defclass nyaa-self-test::thing ()
              ((x :initform 1 :accessor nyaa-self-test::thing-x)))"))
    (let ((instance (make-instance (find-symbol "THING" "NYAA-SELF-TEST"))))
      (self :define :package "NYAA-SELF-TEST"
            :form "(defclass thing () ((x :initform 1 :accessor thing-x) (y :initform 2 :accessor thing-y)))")
      (is (= 2 (funcall (find-symbol "THING-Y" "NYAA-SELF-TEST") instance))))))

;;; --- :reload ---------------------------------------------------------

(test self-reload-restarts-a-named-child
  (with-self ()
    (set-thing 9)
    (let ((result (self :reload :name "stateful-thing")))
      (is (eq :ok (first result))))
    ;; reload keeps the instance's own slots (meow's reload.md): still
    ;; answering, and still holding the value set before the reload.
    (is (eql 9 (thing)))))

(test self-reload-an-unknown-name-is-a-bad-request
  (with-self ()
    (let ((result (self :reload :name "no-such-child")))
      (is (equal :bad-request (first (nyaa:tool-error result)))))))

(test self-reload-of-itself-is-an-error-not-a-deadlock
  (with-self ()
    (let ((result (self :reload :name "tool-self")))
      (is (eq :error (first result))))))

;;; --- checkpoint + log around every write --------------------------

(test self-write-checkpoints-and-logs-intent-and-outcome
  (with-self ()
    (let ((before (length (nyaa:generations :dir *self-dir*))))
      (self :eval :form "1" :label "probe")
      (is (= (1+ before) (length (nyaa:generations :dir *self-dir*))))
      (let* ((entries (getf (second (self :log)) :entries))
             (last-two (last entries 2)))
        (is (eq :intent (getf (first last-two) :kind)))
        (is (equal "probe" (getf (first last-two) :label)))
        (is (eq :outcome (getf (second last-two) :kind)))
        (is (eq :ok (getf (second last-two) :outcome)))))))

(test self-log-reading-never-evaluates
  (with-self ()
    (self :eval :form "1")
    (with-open-file (stream *self-log-path* :direction :output
                            :if-exists :append :if-does-not-exist :create)
      (write-string "(:kind :evil :form #.(error \"read-eval ran\"))" stream)
      (terpri stream))
    (is (eq :ok (first (self :log))))))

;;; --- kept off the plan gate ------------------------------------------

(test tool-plan-refuses-tool-self
  (with-self ()
    (m:mount *self-context* 'nyaa:tool-plan :allow '(:tool-self))
    (let ((result (nyaa:invoke-tool :tool-plan
                                    :steps (list (list :tool "tool-self"
                                                        :args (list :op :eval :form "1"))))))
      (is (equal :bad-request (first (nyaa:tool-error result))))
      (is (search "agent-trusted" (second (nyaa:tool-error result)))))))
