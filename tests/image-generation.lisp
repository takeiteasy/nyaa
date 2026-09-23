(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; Image generations (~takeiteasy/nyaa#48): the refusals SAVE-IMAGE makes
;;; before ever suspending anything, GENERATIONS' :image field, and a real
;;; end-to-end save/relaunch in a subprocess.

(nyaa:define-provider :test-image-credentialed
  :protocol :protocol-openai
  :base-url "http://127.0.0.1:1"
  :auth :none)

(m:defservice image-test-thing () ((value :initform 0 :accessor image-thing-value))
  (:name :image-test-thing))

(defmethod nyaa:snapshot ((service image-test-thing))
  (list :value (image-thing-value service)))

(defmethod nyaa:restore ((service image-test-thing) state)
  (setf (image-thing-value service) (getf state :value))
  t)

(defmethod m:handle ((service image-test-thing) message)
  (case (first message)
    (:set (setf (image-thing-value service) (second message)))
    (:get (image-thing-value service))
    (t nil)))

(defun call-with-image-context (dir body)
  (let* ((registry (make-instance 'm:registry))
         (m:*registry* registry)
         (context (m:start-service (make-instance 'm:context :name :image-tools)
                                   :registry registry)))
    (unwind-protect (funcall body context dir)
      ;; M:STOP-AND-WAIT, not M:STOP: a plain STOP only sends the request,
      ;; so the next test's own SAVE-IMAGE could still see this context's
      ;; thread mid-unwind and refuse (~takeiteasy/nyaa#72).
      (m:stop-and-wait context))))

(defmacro with-image-context ((context &optional (dir-var (gensym))) &body body)
  `(with-generations-directory (,dir-var)
     (call-with-image-context ,dir-var (lambda (,context ,dir-var) (declare (ignorable ,dir-var)) ,@body))))

;;; --- refusals ------------------------------------------------------------

(test save-image-off-the-main-thread-is-refused
  (with-image-context (ctx)
    (let ((condition nil))
      (bt:join-thread
       (bt:make-thread (lambda ()
                        (handler-case (nyaa:save-image ctx :dir (uiop:temporary-directory))
                          (error (e) (setf condition e))))))
      (is (typep condition 'error))
      (is (search "main thread" (princ-to-string condition))))))

(test save-image-refuses-a-credentialed-provider-before-suspending-anything
  (with-image-context (ctx dir)
    (m:mount ctx 'nyaa:protocol-openai)
    (m:mount ctx 'nyaa/tests::provider-test-image-credentialed :api-key "super-secret")
    (let ((before (length (nyaa:generations :dir dir))))
      (signals error (nyaa:save-image ctx :dir dir))
      ;; refused ahead of CHECKPOINT: no generation was written
      (is (= before (length (nyaa:generations :dir dir)))))))

(test relaunch-of-a-missing-core-is-refused
  (signals error (nyaa:relaunch "/no/such/file.core")))

;;; --- a stray thread outside the tree (~takeiteasy/nyaa#72) ---------------

(test save-image-refuses-and-resumes-when-a-stray-thread-outlives-its-timeout
  (with-image-context (ctx dir)
    (m:mount ctx 'image-test-thing)
    (let* ((gate (bt:make-semaphore))
           (stray (bt:make-thread (lambda () (bt:wait-on-semaphore gate)) :name "nyaa-test-stray")))
      (unwind-protect
           (let ((condition nil))
             (handler-case (nyaa:save-image ctx :dir dir :timeout 0.2)
               (error (e) (setf condition e)))
             (is (typep condition 'error))
             (is (search "nyaa-test-stray" (princ-to-string condition)))
             ;; refused before ever forking, so the tree is still up and the
             ;; context's own service still answers -- SAVE-IMAGE's
             ;; UNWIND-PROTECT resumed it even though it never reached FORK
             (is (eql 0 (m:call (m:lookup :image-test-thing) '(:get)))))
        (bt:signal-semaphore gate)
        (bt:join-thread stray)))))

(test save-image-succeeds-once-a-stray-thread-exits-within-the-timeout
  (with-image-context (ctx dir)
    (m:mount ctx 'image-test-thing)
    (let ((stray (bt:make-thread (lambda () (sleep 0.2)) :name "nyaa-test-stray-brief")))
      (unwind-protect
           (is-true (probe-file (nyaa:save-image ctx :dir dir :timeout 2)))
        (bt:join-thread stray)))))

;;; --- generations' :image field ------------------------------------------

(test generations-image-is-nil-with-no-image-taken
  (with-image-context (ctx dir)
    (m:mount ctx 'image-test-thing)
    (nyaa:checkpoint ctx :dir dir)
    (is (null (getf (first (nyaa:generations :dir dir)) :image)))))

(test save-image-writes-a-sibling-core-generations-reports
  (with-image-context (ctx dir)
    (m:mount ctx 'image-test-thing)
    (let ((core (nyaa:save-image ctx :dir dir)))
      (is-true (probe-file core))
      (let ((entry (first (nyaa:generations :dir dir))))
        (is (equal (namestring (truename core)) (getf entry :image)))))))

;;; --- end to end, a real fork + save + relaunch --------------------------

;;; The relaunch below starts a brand new process from the saved core: no
;;; dynamic LET binding of m:*registry* survives that (a saved core keeps
;;; the heap, not the call stack), so this SETFs it globally instead of
;;; going through WITH-IMAGE-CONTEXT, and puts it back after.

(test save-image-round-trips-state-and-code-through-a-real-relaunch
  (with-generations-directory (dir)
    (let ((saved-registry m:*registry*)
          (registry (make-instance 'm:registry)))
      (unwind-protect
           (let ((ctx (progn (setf m:*registry* registry)
                             (m:start-service (make-instance 'm:context :name :image-tools)
                                              :registry registry))))
             (unwind-protect
                  (progn
                    (m:mount ctx 'image-test-thing)
                    (m:call (m:lookup :image-test-thing) '(:set 42))
                    (let* ((core (namestring (nyaa:save-image ctx :dir dir)))
                           (out-file (format nil "~anyaa-image-test-out-~36r.txt"
                                             (namestring (uiop:temporary-directory))
                                             (random (expt 2 64) (make-random-state t)))))
                      ;; the live context is unaffected: SAVE-IMAGE
                      ;; suspends and resumes around the fork, so it still
                      ;; answers afterwards
                      (is (eql 42 (m:call (m:lookup :image-test-thing) '(:get))))
                      (unwind-protect
                           (multiple-value-bind (out err code)
                               (uiop:run-program
                                (list (namestring sb-ext:*runtime-pathname*) "--core" core "--noinform"
                                      "--non-interactive" "--eval"
                                      (format nil "(with-open-file (s ~s :direction :output :if-exists :supersede) ~
                                                    (format s \"~~s\" (meow:call (meow:lookup :image-test-thing) '(:get))))"
                                              out-file))
                                :output :string :error-output :string :ignore-error-status t)
                             (declare (ignore out))
                             (is (zerop code) "relaunched core exited ~a: ~a" code err)
                             (is (equal "42" (uiop:read-file-string out-file))))
                        (ignore-errors (delete-file out-file)))))
               (m:stop-and-wait ctx)))
        (setf m:*registry* saved-registry)))))

;;; --- SELF-DEFINE and :require-image (~takeiteasy/nyaa#63) ---------------
;;;
;;; *LAST-IMAGE* and *SELF-DIRTY* (tools/self.lisp) are process-wide, not
;;; per mount, so every test here LETs them rather than touching the
;;; ambient value -- a dynamic binding a FiveAM test's own unwind restores
;;; regardless of how the test ends.

(or (find-package "NYAA-SELF-DEFINE-TEST") (make-package "NYAA-SELF-DEFINE-TEST" :use '("CL")))

;;; TOOL-SELF's own dispatch runs on its mounted process's thread, not the
;;; test's -- a LET's dynamic binding is per-thread, so it would never be
;;; seen there. SETF plus UNWIND-PROTECT mutates the actual global value
;;; instead, restoring it once the test is done either way.

(defmacro with-self-image-state ((last-image self-dirty) &body body)
  (let ((old-image (gensym)) (old-dirty (gensym)))
    `(let ((,old-image nyaa::*last-image*) (,old-dirty nyaa::*self-dirty*))
       (setf nyaa::*last-image* ,last-image nyaa::*self-dirty* ,self-dirty)
       (unwind-protect (progn ,@body)
         (setf nyaa::*last-image* ,old-image nyaa::*self-dirty* ,old-dirty)))))

(test require-image-refuses-eval-and-define-with-no-image-taken
  (with-self-image-state (nil nil)
    (with-image-context (ctx)
      (m:mount ctx 'nyaa:tool-self :enable '(:eval :define) :require-image t)
      (let ((result (nyaa:invoke-tool :tool-self :op :eval :form "1")))
        (is (equal :bad-request (first (nyaa:tool-error result))))))))

(test require-image-accepts-after-a-clean-image-then-refuses-once-dirty
  (with-self-image-state ("/tmp/pretend.core" nil)
    (with-image-context (ctx)
      (m:mount ctx 'nyaa:tool-self :enable '(:eval :define) :require-image t)
      (let ((before (nyaa:invoke-tool :tool-self :op :eval :form "1")))
        (is (eq :ok (first before)))
        ;; that write just made the image stale
        (let ((after (nyaa:invoke-tool :tool-self :op :eval :form "1")))
          (is (equal :bad-request (first (nyaa:tool-error after)))))))))

(test self-define-refuses-a-non-definition-form
  (let ((nyaa::*last-image* nil) (nyaa::*self-dirty* nil))
    (with-image-context (ctx)
      (signals error (nyaa:self-define ctx "(+ 1 2)")))))

(test self-define-redefines-and-takes-a-fresh-image
  (let ((nyaa::*last-image* nil) (nyaa::*self-dirty* t))
    (with-image-context (ctx dir)
      ;; SELF-DEFINE has no :dir of its own -- it goes through
      ;; *GENERATIONS-DIRECTORY*, same as CHECKPOINT's own default
      (let ((nyaa:*generations-directory* dir))
        (multiple-value-bind (result image-path)
            (nyaa:self-define ctx "(defun greet () :hi)" :package "NYAA-SELF-DEFINE-TEST")
          (declare (ignore result))
          (is (eq :hi (funcall (find-symbol "GREET" "NYAA-SELF-DEFINE-TEST"))))
          (is (equal image-path nyaa::*last-image*))
          ;; the eval SELF-DEFINE just did is itself a write the image it
          ;; took doesn't cover -- :REQUIRE-IMAGE must see the image as
          ;; stale again, not as still covering this redefinition
          (is-true nyaa::*self-dirty*)
          (is-true (probe-file image-path))
          (is (search "self-define"
                      (getf (first (nyaa:generations :dir dir)) :label))))))))

