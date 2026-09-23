(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; TOOL-PLAN, the DSL gate (~takeiteasy/nyaa#6): checking a whole plan
;;; before any step runs, threading a value through :REF, and the reasons a
;;; step or a whole plan is refused.

;;; A minimal :TRUST :AGENT tool that sleeps, so PLAN-HONOURS-ITS-TIMEOUT can
;;; force real elapsed time between two steps without a tool this trust
;;; level otherwise offering one.

(nyaa:define-tool :tool-sleep
    (:trust :agent
     :summary "Sleep for :ms milliseconds"
     :params ((:ms (integer 0) :required t :doc "milliseconds to sleep")))
  (:invoke (ms)
    (sleep (/ ms 1000.0))
    (nyaa::ok)))

(defvar *plan-sandbox* nil "The fs tool's sandbox root for the running test.")

(defun call-with-plan (allow max-steps body &key sleep-tool)
  (let* ((registry (make-instance 'm:registry))
         (m:*registry* registry)
         (root (make-sandbox-directory))
         (context (m:start-service (make-instance 'm:context :name :plan-tools)
                                   :registry registry)))
    (setf *plan-sandbox* root)
    (unwind-protect
         (progn
           (m:mount context 'nyaa:tool-fs :root root)
           (m:mount context 'nyaa:tool-shell)
           (when sleep-tool (m:mount context 'tool-sleep))
           (m:mount context 'nyaa:tool-plan :allow allow :max-steps max-steps)
           (funcall body))
      (m:stop context)
      (uiop:delete-directory-tree (uiop:ensure-directory-pathname root)
                                  :validate t :if-does-not-exist :ignore))))

(defmacro with-plan (&body body)
  "The common case: TOOL-FS allowed, the default step limit."
  `(call-with-plan '(:tool-fs) 16 (lambda () ,@body)))

(defun plan (steps &optional (timeout nil timeout-p))
  (if timeout-p
      (nyaa:invoke-tool :tool-plan :steps steps :timeout timeout)
      (nyaa:invoke-tool :tool-plan :steps steps)))

(defun plan-results (result)
  (getf (second result) :results))

(defun sandbox-file-exists-p (name)
  (uiop:file-exists-p (concatenate 'string *plan-sandbox* "/" name)))

;;; --- running a plan ----------------------------------------------------

(test plan-threads-a-value-through-ref
  (with-plan
    (let ((result (plan (list (list :as "w" :tool "tool-fs"
                                    :args (list :op :write :path "src.txt" :data "hello ref"))
                              (list :as "r" :tool "tool-fs"
                                    :args (list :op :read :path "src.txt"))
                              (list :as "c" :tool "tool-fs"
                                    :args (list :op :write :path "dst.txt"
                                               :data (list :ref "r.data")))
                              (list :as "final" :tool "tool-fs"
                                    :args (list :op :read :path "dst.txt"))))))
      (is (not (nyaa:tool-error-p result)))
      (is (equal "hello ref" (getf (getf (plan-results result) :final) :data)))
      (is (equal 4 (getf (second result) :steps))))))

;;; --- refused before any step runs ---------------------------------------

(test plan-refuses-a-tool-outside-its-allow-list
  (with-plan
    ;; tool-shell is mounted but not in this plan's :allow.
    (let ((result (plan (list (list :tool "tool-shell" :args (list :cmd "true"))
                              (list :as "w" :tool "tool-fs"
                                    :args (list :op :write :path "never.txt" :data "x"))))))
      (is (search "allow-list" (second (nyaa:tool-error result))))
      (is (not (sandbox-file-exists-p "never.txt"))))))

(test plan-refuses-an-operator-trusted-tool-even-when-allowed
  (call-with-plan '(:tool-fs :tool-shell) 16
    (lambda ()
      (let ((result (plan (list (list :tool "tool-shell" :args (list :cmd "true"))))))
        (is (search "agent-trusted" (second (nyaa:tool-error result))))))))

(test plan-refuses-an-unregistered-tool
  ;; Allowed by name, but nothing is mounted under it.
  (call-with-plan '(:tool-fs :tool-nonexistent) 16
    (lambda ()
      (let ((result (plan (list (list :tool "tool-nonexistent" :args nil)))))
        (is (search "no tool named" (second (nyaa:tool-error result))))))))

(test plans-do-not-nest
  (call-with-plan '(:tool-fs :tool-plan) 16
    (lambda ()
      (let ((result (plan (list (list :tool "tool-plan" :args (list :steps nil))))))
        (is (search "nest" (second (nyaa:tool-error result))))))))

(test plan-refuses-a-duplicate-step-name
  (with-plan
    (let ((result (plan (list (list :as "x" :tool "tool-fs"
                                    :args (list :op :read :path "a.txt"))
                              (list :as "x" :tool "tool-fs"
                                    :args (list :op :read :path "b.txt"))))))
      (is (search "duplicate" (second (nyaa:tool-error result)))))))

(test plan-refuses-a-ref-to-an-unknown-or-later-step
  (with-plan
    (let ((result (plan (list (list :tool "tool-fs"
                                    :args (list :op :read :path (list :ref "later.data")))
                              (list :as "later" :tool "tool-fs"
                                    :args (list :op :read :path "a.txt"))))))
      (is (search "unknown or later step" (second (nyaa:tool-error result)))))))

(test plan-refuses-a-malformed-ref
  (with-plan
    (let ((result (plan (list (list :tool "tool-fs"
                                    :args (list :op :read :path (list :ref "no-dot")))))))
      (is (search "malformed ref" (second (nyaa:tool-error result)))))))

(test plan-refuses-more-than-max-steps
  (call-with-plan '(:tool-fs) 1
    (lambda ()
      (let ((result (plan (list (list :as "a" :tool "tool-fs"
                                      :args (list :op :read :path "a.txt"))
                                (list :as "b" :tool "tool-fs"
                                      :args (list :op :read :path "b.txt"))))))
        (is (search "exceeds" (second (nyaa:tool-error result))))))))

;;; --- a step that fails ends the plan -------------------------------------

(test a-failing-step-ends-the-plan-with-the-results-so-far
  (with-plan
    (let ((result (plan (list (list :as "ok" :tool "tool-fs"
                                    :args (list :op :write :path "a.txt" :data "x"))
                              (list :tool "tool-fs" :args (list :op :bogus))
                              (list :tool "tool-fs"
                                    :args (list :op :write :path "never.txt" :data "x"))))))
      (is (nyaa:tool-error-p result))
      (let ((detail (nyaa:tool-error result)))
        (is (equal 2 (getf detail :step)))
        (is (equal "tool-fs" (getf detail :tool)))
        (is (member :ok (getf detail :results))))
      (is (not (sandbox-file-exists-p "never.txt"))))))

;;; --- the whole-plan deadline, checked between steps ----------------------

(test plan-honours-its-timeout-between-steps
  (call-with-plan '(:tool-fs :tool-sleep) 16
    (lambda ()
      (let ((result (plan (list (list :as "s" :tool "tool-sleep" :args (list :ms 50))
                                (list :tool "tool-fs"
                                      :args (list :op :write :path "never.txt" :data "x")))
                          1)))
        (is (eq :timeout (nyaa:tool-error result)))
        (is (not (sandbox-file-exists-p "never.txt")))))
    :sleep-tool t))
