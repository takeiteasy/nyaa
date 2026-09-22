(in-package #:nyaa)

;;; The DSL gate for untrusted input (~takeiteasy/nyaa#6). A plan may only
;;; express a sequence of declared tool calls with typed arguments, never a
;;; form: there is no EVAL and no host-side reader, so the audit surface is
;;; this interpreter plus each named tool's own schema.
;;;
;;; This gates *what a plan may call*, not arbitrary evaluation: tool-eval
;;; and tool-repl stay :trust :operator, untouched. The other shape #6
;;; named -- an allowlist over raw Lisp, so tool-eval itself could be
;;; reached -- is not this ticket's; tracked as a follow-up in
;;; ~takeiteasy/nyaa#44.
;;;
;;; A step:
;;;
;;;   (:as "name" :tool "tool-fs" :args (:op :read :path "README.md"))
;;;
;;; :AS binds the step's result plist under a name a later step's :ARGS may
;;; reach with (:ref "name.key"), substituted before that step runs. :TOOL
;;; must be in this service's own :ALLOW *and* the named tool's own
;;; :trust must be :agent -- an :ALLOW naming an operator-trusted tool is
;;; refused, so the gate cannot be used to re-export tool-shell. tool-plan
;;; is never itself reachable from a plan, so plans do not nest.
;;;
;;; The whole plan is checked before any step runs: every :tool resolvable,
;;; allowed and agent-trusted; every :as unique; every :ref naming an
;;; earlier step. A step that errors ends the plan, with the results so far.
;;;
;;; TODO: :timeout bounds the plan only between steps, so one long step can
;;; run past it. Upgrade path: thread the remaining time into each step's
;;; own deadline. Tracked in ~takeiteasy/nyaa#43.

(define-tool :tool-plan
    (:trust :agent
     :summary "Run a checked sequence of declared tool calls"
     :slots ((allow :initarg :allow :initform nil :reader plan-allow)
             (max-steps :initarg :max-steps :initform 16 :reader plan-max-steps))
     :params ((:steps (array-of
                       (object (:as (or null string)
                                :doc "name to bind this step's result under")
                               (:tool string :required t
                                :doc "tool name, e.g. \"tool-fs\"")
                               (:args any
                                :doc "arguments for the tool; (:ref \"name.key\")
substitutes an earlier step's result")))
               :required t :doc "the steps to run, in order")
              (:timeout (integer 1) :default +default-tool-timeout+
               :doc "whole-plan deadline in milliseconds, checked between steps")))
  (:invoke (steps timeout)
    ;; INVOKE-TOOL has no registry argument of its own -- it reads
    ;; M:*REGISTRY*, which this service's own thread does not inherit from
    ;; whichever thread mounted it. Rebind it here, as the agent loop does
    ;; before its own calls back into INVOKE-TOOL.
    (let ((m:*registry* (m:service-registry service)))
      (run-plan service steps timeout))))

;;; --- validation, before any step runs ---------------------------------

(defun run-plan (service steps timeout-ms)
  (a:if-let (problem (validate-plan service steps))
    (bad-request "~a" problem)
    (execute-plan service steps timeout-ms)))

(defun validate-plan (service steps)
  "NIL when STEPS may run as given, or a message naming the problem."
  (unless (listp steps)
    (return-from validate-plan "steps must be a list"))
  (when (> (length steps) (plan-max-steps service))
    (return-from validate-plan
      (format nil "plan exceeds ~d steps" (plan-max-steps service))))
  (let ((seen '()))
    (dolist (step steps)
      (a:when-let (problem (or (validate-step service step seen)
                               (check-refs (getf step :args) seen)))
        (return-from validate-plan problem))
      (a:when-let (as (getf step :as)) (push as seen))))
  nil)

(defun validate-step (service step seen)
  (let ((as (getf step :as))
        (tool-name (getf step :tool)))
    (cond
      ((null tool-name) "a step is missing :tool")
      ((and as (member as seen :test #'string=))
       (format nil "duplicate step name ~s" as))
      ((string-equal tool-name "tool-plan") "plans do not nest")
      (t (multiple-value-bind (process props)
             (m:lookup (lisp-tool-name tool-name) :registry (m:service-registry service))
           (cond
             ((not (member (lisp-tool-name tool-name) (plan-allow service)))
              (format nil "~a is not in this plan's allow-list" tool-name))
             ((null process) (format nil "no tool named ~a" tool-name))
             ((not (eq (tool-trust props) :agent))
              (format nil "~a is not agent-trusted" tool-name))
             (t nil)))))))

(defun ref-form-p (value)
  "True when VALUE is (:ref \"name.key\") -- a one-key plist, so it survives
the JSON round trip unchanged.

There is no escape for a step that means this shape literally, rather than
as a reference. Tracked in ~takeiteasy/nyaa#45."
  (and (consp value) (eq (first value) :ref) (stringp (second value))
       (null (cddr value))))

(defun parse-ref (text)
  "TEXT, \"name.key\", as (name . key) split on its first \".\", or NIL if
TEXT does not have that shape."
  (let ((dot (position #\. text)))
    (and dot (plusp dot) (< (1+ dot) (length text))
         (cons (subseq text 0 dot) (subseq text (1+ dot))))))

(defun check-refs (args seen)
  "NIL when every (:ref ...) in ARGS names one of SEEN, the steps declared
before this one, or a message naming the first problem found."
  (cond
    ((ref-form-p args)
     (let ((parsed (parse-ref (second args))))
       (cond
         ((null parsed) (format nil "malformed ref ~s" (second args)))
         ((not (member (car parsed) seen :test #'string=))
          (format nil "ref ~s names an unknown or later step" (second args)))
         (t nil))))
    ((consp args) (or (check-refs (car args) seen) (check-refs (cdr args) seen)))
    (t nil)))

;;; --- execution ---------------------------------------------------------

(defun execute-plan (service steps timeout-ms)
  (let ((deadline (+ (get-internal-real-time)
                     (round (* timeout-ms internal-time-units-per-second) 1000)))
        (results (make-hash-table :test #'equal))
        (n 0))
    (dolist (step steps)
      (when (> (get-internal-real-time) deadline)
        (return-from execute-plan (fail :timeout)))
      (incf n)
      (let* ((as (getf step :as))
             (tool-name (getf step :tool))
             (args (resolve-refs (getf step :args) results))
             (result (apply #'invoke-tool (lisp-tool-name tool-name) args)))
        (when (tool-error-p result)
          (return-from execute-plan
            (fail (list :step n :tool tool-name :reason (tool-error result)
                        :results (plan-results-plist results)))))
        (when as
          (setf (gethash as results) (second result)))))
    (ok :results (plan-results-plist results) :steps n)))

(defun resolve-refs (value results)
  (cond
    ((ref-form-p value) (resolve-ref (second value) results))
    ((consp value) (cons (resolve-refs (car value) results)
                         (resolve-refs (cdr value) results)))
    (t value)))

(defun resolve-ref (text results)
  "TEXT's value, read out of RESULTS -- VALIDATE-PLAN has already checked
TEXT names an earlier step; the key within that step's own result is not
checked ahead of time, and is simply absent if TEXT names none it has."
  (let ((parsed (parse-ref text)))
    (getf (gethash (car parsed) results) (a:make-keyword (string-upcase (cdr parsed))))))

(defun plan-results-plist (results)
  (let ((out '()))
    (maphash (lambda (name value)
               ;; PUSH is LIFO: the value goes on first, so each pair comes
               ;; back out as (key value), not reversed.
               (push value out)
               (push (a:make-keyword (string-upcase name)) out))
             results)
    out))
