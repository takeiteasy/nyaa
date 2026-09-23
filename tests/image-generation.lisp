(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; SBCL image generations (~takeiteasy/nyaa#48): the refusals SAVE-IMAGE
;;; makes before ever suspending anything, GENERATIONS' :image field, and
;;; -- #+sbcl, always on -- a real end-to-end save/relaunch in a subprocess.

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
      (m:stop context))))

(defmacro with-image-context ((context &optional (dir-var (gensym))) &body body)
  `(with-generations-directory (,dir-var)
     (call-with-image-context ,dir-var (lambda (,context ,dir-var) (declare (ignorable ,dir-var)) ,@body))))

;;; --- refusals, every implementation ------------------------------------

#-sbcl
(test save-image-is-unsupported-off-sbcl
  (with-image-context (ctx)
    (signals error (nyaa:save-image ctx))))

#+sbcl
(test save-image-off-the-main-thread-is-refused
  (with-image-context (ctx)
    (let ((condition nil))
      (bt:join-thread
       (bt:make-thread (lambda ()
                        (handler-case (nyaa:save-image ctx :dir (uiop:temporary-directory))
                          (error (e) (setf condition e))))))
      (is (typep condition 'error))
      (is (search "main thread" (princ-to-string condition))))))

#+sbcl
(test save-image-refuses-a-credentialed-provider-before-suspending-anything
  (with-image-context (ctx dir)
    (m:mount ctx 'nyaa:protocol-openai)
    (m:mount ctx 'nyaa/tests::provider-test-image-credentialed :api-key "super-secret")
    (let ((before (length (nyaa:generations :dir dir))))
      (signals error (nyaa:save-image ctx :dir dir))
      ;; refused ahead of CHECKPOINT: no generation was written
      (is (= before (length (nyaa:generations :dir dir)))))))

#+sbcl
(test relaunch-of-a-missing-core-is-refused
  (signals error (nyaa:relaunch "/no/such/file.core")))

;;; --- generations' :image field ------------------------------------------

#+sbcl
(test generations-image-is-nil-with-no-image-taken
  (with-image-context (ctx dir)
    (m:mount ctx 'image-test-thing)
    (nyaa:checkpoint ctx :dir dir)
    (is (null (getf (first (nyaa:generations :dir dir)) :image)))))

#+sbcl
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

#+sbcl
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
               (m:stop ctx)))
        (setf m:*registry* saved-registry)))))
