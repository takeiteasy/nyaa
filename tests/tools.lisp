(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; The tool convention exercised through the real registry and service
;;; stack: discovery by registration props, the describe/invoke protocol,
;;; per-tool behaviour, sandbox enforcement, and the property that a hung
;;; command never wedges the tool service itself.

(defvar *sandbox* nil "The fs tool's sandbox root for the running test.")

(defun call-with-tools (body)
  (let* ((registry (make-instance 'm:registry))
         (m:*registry* registry)
         (root (make-sandbox-directory))
         (context (m:start-service (make-instance 'm:context :name :tools)
                                   :registry registry)))
    (setf *sandbox* root)
    (unwind-protect
         (progn
           (m:mount context 'nyaa:tool-fs :root root)
           (m:mount context 'nyaa:tool-shell)
           (m:mount context 'nyaa:tool-http)
           (funcall body))
      (m:stop context)
      (uiop:delete-directory-tree (uiop:ensure-directory-pathname root)
                                  :validate t :if-does-not-exist :ignore))))

(defmacro with-tools (&body body)
  `(call-with-tools (lambda () ,@body)))

(defun make-sandbox-directory ()
  (let ((path (format nil "~anyaa-tool-test-~36r"
                      (namestring (uiop:temporary-directory))
                      (random (expt 2 64) (make-random-state t)))))
    (ensure-directories-exist (concatenate 'string path "/"))
    ;; The tool normalises its root the same way; match it so assertions
    ;; about escaping compare like with like.
    (string-right-trim "/" path)))

(defun tool (name &rest args)
  (apply #'nyaa:invoke-tool name args))

(defun result-value (result key)
  (getf (second result) key))

;;; --- the convention --------------------------------------------------

(test tools-are-discoverable-via-props
  (with-tools
    ;; kind=tool in the registration props, found through names + lookup:
    ;; the context and meow's own entries must not appear.
    (is (equal '(:tool-fs :tool-http :tool-shell) (nyaa:tools)))))

(test describe-returns-convention-metadata
  (with-tools
    (let ((metadata (nyaa:describe-tool :tool-shell)))
      (is (eq :tool (getf metadata :kind)))
      (is (stringp (getf metadata :summary)))
      (is (listp (getf metadata :params))))))

(test unknown-message-is-a-bad-request
  (with-tools
    (is (equal :bad-request
               (first (nyaa:tool-error
                       (m:call (m:lookup :tool-shell) '(:nonsense))))))))

;;; --- fs ---------------------------------------------------------------

(test fs-round-trips-inside-the-root
  (with-tools
    (is (eq :ok (first (tool :tool-fs :op :write :path "a/b.txt"
                                     :data "hello fs"))))
    (is (equal "hello fs"
               (result-value (tool :tool-fs :op :read :path "a/b.txt") :data)))
    (is (member "a" (result-value (tool :tool-fs :op :list :path ".") :files)
                :test #'string=))
    (is (eq :ok (first (tool :tool-fs :op :mkdir :path "c/d"))))
    (is (member "c" (result-value (tool :tool-fs :op :list :path ".") :files)
                :test #'string=))
    (is (eq :ok (first (tool :tool-fs :op :delete :path "a/b.txt"))))))

(test fs-refuses-to-delete-a-directory
  (with-tools
    (tool :tool-fs :op :mkdir :path "keep")
    (is (equal :bad-request
               (first (nyaa:tool-error
                       (tool :tool-fs :op :delete :path "keep")))))))

(test fs-rejects-path-escapes
  (with-tools
    (dolist (path '("../outside.txt" "/etc/passwd" "../sandbox-root-evil"
                    "a/../../outside.txt"))
      (is (equal '(:forbidden "path escapes sandbox root")
                 (nyaa:tool-error (tool :tool-fs :op :read :path path))))))

  ;; The sibling-prefix trick specifically: a directory whose name merely
  ;; starts with the root's name is not inside it.
  (with-tools
    (let ((sibling (concatenate 'string *sandbox* "-evil")))
      (is (equal '(:forbidden "path escapes sandbox root")
                 (nyaa:tool-error (tool :tool-fs :op :list :path sibling)))))))

(test fs-requires-a-path
  (with-tools
    (is (equal :bad-request
               (first (nyaa:tool-error (tool :tool-fs :op :read)))))))

;;; --- shell -------------------------------------------------------------

(test shell-captures-merged-output-and-exit-status
  (with-tools
    (let ((result (tool :tool-shell :cmd "echo out; echo err 1>&2")))
      (is (eql 0 (result-value result :exit)))
      (is (equal "out
err
" (result-value result :out))))
    (is (eql 3 (result-value (tool :tool-shell :cmd "exit 3") :exit)))))

(test shell-enforces-its-timeout-and-stays-alive
  (with-tools
    (let ((started (get-internal-real-time)))
      (is (eq :timeout (nyaa:tool-error
                        (tool :tool-shell :cmd "sleep 30" :timeout 300))))
      (is (< (/ (- (get-internal-real-time) started)
                internal-time-units-per-second)
             5)))
    ;; The service must still answer afterwards.
    (is (equal "still-here
" (result-value (tool :tool-shell :cmd "echo still-here") :out)))))

(test shell-rejects-a-missing-command
  (with-tools
    (is (equal :bad-request
               (first (nyaa:tool-error (tool :tool-shell :timeout 100)))))))

(test invoke-outlives-the-default-call-timeout
  ;; M:CALL defaults to 5s. A tool given a longer deadline must not be cut
  ;; short at the caller while its own work is still within bounds.
  (with-tools
    (is (eql 0 (result-value (tool :tool-shell :cmd "sleep 8" :timeout 15000)
                             :exit)))))

;;; --- http ---------------------------------------------------------------

(defun echo-handler (&key method path headers body)
  (declare (ignore method))
  (cond
    ((string= path "/echo") (list 200 '("Content-Type" "text/plain") body))
    ((string= path "/slow") (sleep 1.5) (list 200 '() ""))
    ((string= path "/moved") (list 302 '("Location" "/echo") ""))
    ((string= path "/boom") (list 500 '() "kaboom"))
    ((string= path "/seen") (list 200 '() (or (getf-string headers "x-tag") "")))
    (t (list 404 '("Content-Type" "application/json") "{\"error\":\"nf\"}"))))

(defmacro with-fake-http ((url) &body body)
  `(let ((server (start-fake-http #'echo-handler)))
     (unwind-protect (let ((,url (fake-http-url server))) ,@body)
       (stop-fake-http server))))

(test http-passes-statuses-through-untouched
  (with-tools
    (with-fake-http (url)
      (is (eql 200 (result-value (tool :tool-http :url (format nil "~a/echo" url))
                                 :status)))
      (is (eql 404 (result-value (tool :tool-http :url (format nil "~a/nope" url))
                                 :status)))
      (is (eql 500 (result-value (tool :tool-http :url (format nil "~a/boom" url))
                                 :status))))))

(test http-does-not-follow-redirects
  (with-tools
    (with-fake-http (url)
      (is (eql 302 (result-value
                    (tool :tool-http :url (format nil "~a/moved" url))
                    :status))))))

(test http-lower-cases-response-headers
  (with-tools
    (with-fake-http (url)
      (let ((headers (result-value
                      (tool :tool-http :url (format nil "~a/echo" url))
                      :headers)))
        (is (equal "text/plain" (getf-string headers "content-type")))))))

(test http-sends-body-and-extra-headers
  (with-tools
    (with-fake-http (url)
      (is (equal "payload=1"
                 (result-value (tool :tool-http :url (format nil "~a/echo" url)
                                               :method "POST"
                                               :body "payload=1")
                               :body)))
      (is (equal "abc"
                 (result-value (tool :tool-http :url (format nil "~a/seen" url)
                                               :method "POST"
                                               :headers '(:x-tag "abc")
                                               :body "x")
                               :body))))))

(test http-honours-a-caller-supplied-content-type
  (with-tools
    (let ((server (start-fake-http #'echo-handler)))
      (unwind-protect
           (progn
             (tool :tool-http :url (format nil "~a/echo" (fake-http-url server))
                              :method "POST"
                              :headers '("Content-Type" "application/json")
                              :body "{\"a\":1}")
             (let ((headers (getf (first (fake-http-requests server)) :headers)))
               ;; Sent once, as the caller asked -- not clobbered to
               ;; application/octet-stream, and not duplicated.
               (is (equal "application/json"
                          (getf-string headers "content-type")))
               (is (eql 1 (count "content-type"
                                 (loop for (name) on headers by #'cddr
                                       collect name)
                                 :test #'string=)))))
        (stop-fake-http server)))))

(test http-rejects-a-missing-url-without-hitting-the-wire
  (with-tools
    (let ((server (start-fake-http #'echo-handler)))
      (unwind-protect
           (progn
             (is (equal :bad-request
                        (first (nyaa:tool-error (tool :tool-http :method "GET")))))
             (is (null (fake-http-requests server))))
        (stop-fake-http server)))))

(test http-timeout-is-bounded-and-surfaces-as-an-error
  (with-tools
    (with-fake-http (url)
      (is (eq :timeout
              (nyaa:tool-error (tool :tool-http :url (format nil "~a/slow" url)
                                                :timeout 300)))))))

(test http-unreachable-host-is-unavailable
  (with-tools
    (let* ((server (start-fake-http #'echo-handler))
           (url (fake-http-url server)))
      (stop-fake-http server)
      (is (eq :unavailable
              (nyaa:tool-error (tool :tool-http :url (format nil "~a/echo" url))))))))
