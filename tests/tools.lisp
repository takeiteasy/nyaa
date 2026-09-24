(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; The tool convention exercised through the real registry and service
;;; stack: discovery by registration props, the describe/invoke protocol,
;;; per-tool behaviour, sandbox enforcement, and the property that a hung
;;; command never wedges the tool service itself.

(defvar *sandbox* nil "The fs tool's sandbox root for the running test.")
(defvar *context* nil "The context the running test's tools are mounted in.")

(defun call-with-tools (body)
  (let* ((registry (make-instance 'm:registry))
         (m:*registry* registry)
         (root (make-sandbox-directory))
         (context (m:start-service (make-instance 'm:context :name :tools)
                                   :registry registry)))
    (setf *sandbox* root
          *context* context)
    (unwind-protect
         (progn
           (m:mount context 'nyaa:tool-fs :root root)
           (m:mount context 'nyaa:tool-shell)
           (m:mount context 'nyaa:tool-http)
           (m:mount context 'nyaa:tool-eval)
           (m:mount context 'nyaa:tool-repl)
           (m:mount context 'nyaa:tool-plan :allow '(:tool-fs))
           (m:mount context 'nyaa:tool-image)
           (m:mount context 'nyaa:tool-services)
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
    ;; The tool truenames its root the same way (/tmp is itself a symlink
    ;; on macOS); match it so assertions about escaping compare like with
    ;; like.
    (string-right-trim "/" (uiop:native-namestring (uiop:truename* path)))))

(defun tool (name &rest args)
  (apply #'nyaa:invoke-tool name args))

(defun result-value (result key)
  (getf (second result) key))

(defmacro tool-thread (&body body)
  ;; A plain BT:MAKE-THREAD does not inherit dynamic bindings, and
  ;; M:*REGISTRY* is one WITH-TOOLS establishes with a LET -- so a thread
  ;; that calls TOOL needs it carried across explicitly.
  `(let ((registry m:*registry*))
     (bt:make-thread (lambda () (let ((m:*registry* registry)) ,@body)))))

(defparameter +getpid-form+
  ;; A worker runs the host implementation, so the bare image it starts has
  ;; exactly the internals this one does.
  "(sb-unix:unix-getpid)")

(defun unix-process-alive-p (pid)
  (zerop (nth-value 2 (uiop:run-program (list "kill" "-0" (princ-to-string pid))
                                        :ignore-error-status t))))

(defun wait-for-exit (pid &optional (deadline 2.0))
  "True once PID is gone. A kill is not documented to block until the
process has actually exited, so the check polls rather than assume."
  (loop repeat (ceiling deadline 0.05)
        while (unix-process-alive-p pid)
        do (sleep 0.05))
  (not (unix-process-alive-p pid)))

(defun unix-pgid (pid)
  "PID's process group id, or NIL if it is already gone."
  (let ((out (with-output-to-string (s)
              (uiop:run-program (list "ps" "-o" "pgid=" "-p" (princ-to-string pid))
                                :output s :ignore-error-status t))))
    (parse-integer out :junk-allowed t)))

(defun process-group-containment-available-p ()
  "True unless the host has fallen all the way back to :TREE -- the racy
last resort with no dedicated OS mechanism behind it."
  (not (eq nyaa::*process-group-strategy* :tree)))

(defun poll-until (predicate &optional (deadline 5.0) (interval 0.1))
  "True once PREDICATE is false, polled rather than assumed instant."
  (loop repeat (ceiling deadline interval)
        while (funcall predicate)
        do (sleep interval))
  (not (funcall predicate)))

;;; --- M:CALL failures folded into the result vocabulary (~takeiteasy/nyaa#106)

(test call-result-passes-through-a-real-reply
  (is (equal '(:ok (:value "1")) (nyaa::%call-result '(:ok (:value "1")) nil))))

(test call-result-folds-a-timeout
  (is (equal '(:error :timeout) (nyaa::%call-result nil :timeout))))

(test call-result-folds-a-down-status-to-unavailable
  (is (equal '(:error :unavailable) (nyaa::%call-result nil (list :down :shutdown)))))

(test call-result-stringifies-a-deadlock-status
  (let ((result (nyaa::%call-result nil (list :deadlock (list :some-process)))))
    (is (eq :error (first result)))
    (is (eq :error (first (second result))))
    (is (stringp (second (second result))))))

;;; --- the convention --------------------------------------------------

(test tools-are-discoverable-via-props
  (with-tools
    ;; kind=tool in the registration props, found through names + lookup:
    ;; the context and meow's own entries must not appear.
    (is (equal '(:tool-eval :tool-fs :tool-http :tool-image :tool-plan
                 :tool-repl :tool-services :tool-shell)
               (nyaa:tools)))))

(test metadata-carries-a-trust-level
  (with-tools
    (is (eq :operator (nyaa:tool-trust (nyaa:describe-tool :tool-shell))))
    (is (eq :agent (nyaa:tool-trust (nyaa:describe-tool :tool-fs))))
    (is (eq :agent (nyaa:tool-trust (nyaa:describe-tool :tool-plan))))
    (is (eq :agent (nyaa:tool-trust (nyaa:describe-tool :tool-image))))
    (is (eq :agent (nyaa:tool-trust (nyaa:describe-tool :tool-services))))
    ;; A tool that names none is an agent tool.
    (is (eq :agent (nyaa:tool-trust '(:kind :tool))))))

(test describe-returns-convention-metadata
  (with-tools
    (let ((metadata (nyaa:describe-tool :tool-shell)))
      (is (eq :tool (getf metadata :kind)))
      (is (stringp (getf metadata :summary)))
      ;; The schema renders, so a protocol can put it in a tools array.
      (is (nyaa:schema->json-schema (nyaa:tool-schema metadata))))))

(test arguments-are-coerced-against-the-schema
  (with-tools
    ;; A model supplies strings whatever the declared type.
    (is (equal (format nil "ok~%")
               (result-value (tool :tool-shell :cmd "echo ok" :timeout "5000")
                             :out)))
    ;; :op is a member, so the string and the keyword name the same op.
    (tool :tool-fs :op "write" :path "m.txt" :data "x")
    (is (equal "x" (result-value (tool :tool-fs :op :read :path "m.txt") :data)))))

(test an-unknown-parameter-is-a-bad-request
  (with-tools
    (is (equal :bad-request
               (first (nyaa:tool-error
                       (tool :tool-shell :cmd "echo hi" :colour t)))))))

(test a-bare-call-is-coerced-too
  ;; INVOKE-TOOL is not the only way in, so the handler coerces as well.
  (with-tools
    (is (eql 0 (result-value (m:call (m:lookup :tool-shell)
                                     '(:invoke :cmd "true" :timeout "5000")
                                     :timeout 10)
                             :exit)))))

(test a-string-timeout-outlives-the-default-call-timeout
  ;; %CALLER-TIMEOUT reads the coerced arguments: a model-supplied "15000"
  ;; must extend the caller's wait the same way 15000 does.
  (with-tools
    (is (eql 0 (result-value (tool :tool-shell :cmd "sleep 8" :timeout "15000")
                             :exit)))))

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

;;; --- fs: symlinks (~takeiteasy/nyaa#15) --------------------------------

(defun make-symlink (target link)
  (uiop:run-program (list "ln" "-s" target link) :output nil :error-output nil))

(defun write-file (path contents)
  (with-open-file (s path :direction :output :if-exists :supersede
                          :if-does-not-exist :create)
    (write-string contents s)))

(test fs-refuses-a-symlink-to-a-file-outside-the-root
  (with-tools
    (let ((outside (format nil "~a-outside.txt" *sandbox*)))
      (write-file outside "secret")
      (unwind-protect
           (progn
             (make-symlink outside (concatenate 'string *sandbox* "/link.txt"))
             (is (equal '(:forbidden "path escapes sandbox root")
                        (nyaa:tool-error (tool :tool-fs :op :read :path "link.txt")))))
        (delete-file outside)))))

(test fs-refuses-traversal-through-a-symlinked-directory
  (with-tools
    (let ((outside (format nil "~a-outside" *sandbox*)))
      (ensure-directories-exist (concatenate 'string outside "/"))
      (write-file (concatenate 'string outside "/x.txt") "secret")
      (unwind-protect
           (progn
             (make-symlink outside (concatenate 'string *sandbox* "/linkdir"))
             (is (equal '(:forbidden "path escapes sandbox root")
                        (nyaa:tool-error (tool :tool-fs :op :read :path "linkdir/x.txt")))))
        (uiop:delete-directory-tree (uiop:ensure-directory-pathname outside)
                                    :validate t :if-does-not-exist :ignore)))))

(test fs-refuses-a-dangling-symlink
  (with-tools
    (let ((target (format nil "~a-created-by-attack.txt" *sandbox*)))
      (make-symlink target (concatenate 'string *sandbox* "/dangle"))
      (is (equal '(:forbidden "path escapes sandbox root")
                 (nyaa:tool-error (tool :tool-fs :op :write :path "dangle" :data "x"))))
      (is (not (uiop:file-exists-p target))))))

(test fs-refuses-any-symlink-below-the-root
  ;; ~takeiteasy/nyaa#52: the atomic walk refuses every symlink below the
  ;; root outright, rather than resolving an in-root one and re-checking
  ;; it -- there is no path-based re-check left to race.
  (with-tools
    (tool :tool-fs :op :write :path "real.txt" :data "hello")
    (make-symlink (concatenate 'string *sandbox* "/real.txt")
                  (concatenate 'string *sandbox* "/alias.txt"))
    (is (equal '(:forbidden "path escapes sandbox root")
               (nyaa:tool-error (tool :tool-fs :op :read :path "alias.txt"))))))

(test fs-refuses-to-delete-a-symlink-leaf
  (with-tools
    (tool :tool-fs :op :write :path "real.txt" :data "hello")
    (make-symlink (concatenate 'string *sandbox* "/real.txt")
                  (concatenate 'string *sandbox* "/alias.txt"))
    (is (equal '(:forbidden "path escapes sandbox root")
               (nyaa:tool-error (tool :tool-fs :op :delete :path "alias.txt"))))
    (is (equal "hello" (result-value (tool :tool-fs :op :read :path "real.txt") :data)))))

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

(test shell-registers-a-command-only-while-it-runs
  (nyaa::run-command "true" 5000)
  (is (null nyaa::*live-commands*))
  (nyaa::run-command "sleep 30" 200)
  (is (null nyaa::*live-commands*)))

(test kill-live-commands-kills-a-running-command
  (let* ((result nil)
         (thread (bt:make-thread (lambda () (setf result (nyaa::run-command "sleep 30" 30000))))))
    (is-true (eventually (lambda () nyaa::*live-commands*)))
    (nyaa::kill-live-commands)
    (is-true (eventually (lambda () (not (bt:thread-alive-p thread)))))
    (is (not (eql 0 (getf (second result) :exit))))
    (is (null nyaa::*live-commands*))))

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

(test shell-kills-a-backgrounded-descendant-on-timeout
  ;; ~takeiteasy/nyaa#16: the deadline used to signal the direct `sh` child
  ;; only, so a backgrounded grandchild outlived it.
  (if (not (process-group-containment-available-p))
      (skip "no process-group mechanism on this host")
      (with-tools
        (let ((pidfile (format nil "~a/nyaa-shell-pgid-test.pid"
                               (uiop:native-namestring (uiop:temporary-directory)))))
          (unwind-protect
               (progn
                 (is (eq :timeout
                        (nyaa:tool-error
                         (tool :tool-shell
                               :cmd (format nil "sleep 30 & echo $! > ~a; wait" pidfile)
                               :timeout 500))))
                 (let ((grandchild (with-open-file (s pidfile) (parse-integer (read-line s)))))
                   (is (wait-for-exit grandchild))))
            (ignore-errors (delete-file pidfile)))))))

(test shell-kills-a-backgrounded-descendant-under-the-tree-fallback
  ;; ~takeiteasy/nyaa#54: with no OS grouping mechanism at all, containment
  ;; falls back to walking and killing the descendant tree by hand.
  (let ((nyaa::*process-group-strategy* :tree))
    (with-tools
      (let ((pidfile (format nil "~a/nyaa-shell-tree-test.pid"
                             (uiop:native-namestring (uiop:temporary-directory)))))
        (unwind-protect
             (progn
               (is (eq :timeout
                      (nyaa:tool-error
                       (tool :tool-shell
                             :cmd (format nil "sleep 30 & echo $! > ~a; wait" pidfile)
                             :timeout 500))))
               (let ((grandchild (with-open-file (s pidfile) (parse-integer (read-line s)))))
                 (is (wait-for-exit grandchild))))
          (ignore-errors (delete-file pidfile)))))))

;;; --- http ---------------------------------------------------------------

(defvar *stall* nil
  "Set around a request to /stall to hold the fake server's response, and
cleared again so STOP-FAKE-HTTP's join does not wait on it.")

(defun echo-handler (&key method path headers body)
  (declare (ignore method))
  (cond
    ((string= path "/echo") (list 200 '("Content-Type" "text/plain") body))
    ((string= path "/slow") (sleep 1.5) (list 200 '() ""))
    ((string= path "/stall") (loop while *stall* do (sleep 0.02)) (list 200 '() ""))
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

(test http-rejects-malformed-headers
  (with-tools
    ;; An alist has an even length too; it must not pass as one empty header.
    (dolist (headers '((("X-Tag" . "a") ("Y" . "b")) ("X-Tag") (:x-tag 7)))
      (is (equal :bad-request
                 (first (nyaa:tool-error
                         (tool :tool-http :url "http://127.0.0.1:1/x"
                                          :headers headers))))))))

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
              (nyaa:tool-error (tool :tool-http :url (format nil "~a/echo" url)
                                                :timeout 5000)))))))

(test http-timeout-does-not-leak-its-worker-thread
  ;; An abandoned request used to keep its worker thread -- and the
  ;; separate thread that closes its socket -- alive until the server
  ;; answered. *STALL* holds the fake server's response so the
  ;; test controls exactly when that happens -- SETF rather than LET,
  ;; since the handler runs on the fake server's own thread, which does
  ;; not see a dynamic binding made on this one.
  (with-tools
    (with-fake-http (url)
      (setf *stall* t)
      (unwind-protect
           (progn
             (is (eq :timeout
                    (nyaa:tool-error (tool :tool-http :url (format nil "~a/stall" url)
                                                      :timeout 300))))
             ;; *STALL* is still held here, so the fake server has not
             ;; answered -- the worker and any close thread can only be
             ;; gone because the deadline reclaimed them.
             (is (poll-until (lambda ()
                              (or (find "nyaa-http-request" (bt:all-threads)
                                        :key #'bt:thread-name :test #'equal)
                                  (find "nyaa-http-close" (bt:all-threads)
                                        :key #'bt:thread-name :test #'equal))))))
        (setf *stall* nil)))))

(test http-https-round-trip
  ;; Off by default: CI must not depend on the network. Exercises the
  ;; SSL-wrapped stream PERFORM-REQUEST builds for :STREAM
  ;; (~takeiteasy/nyaa#17), which drakma never attaches on its own.
  (if (uiop:getenv "NYAA_LIVE_HTTP")
      (with-tools
        (is (eql 404 (result-value
                      (tool :tool-http :url "https://httpbingo.org/status/404")
                      :status))))
      (skip "set NYAA_LIVE_HTTP to run live HTTP tests")))

;;; --- eval --------------------------------------------------------------

(test eval-returns-the-value-and-the-output
  (with-tools
    (let ((result (tool :tool-eval :form "(progn (princ \"printed\") (+ 1 2))")))
      (is (equal "3" (result-value result :value)))
      (is (equal "printed" (result-value result :out))))))

(test eval-reports-a-reader-error-as-a-bad-request
  (with-tools
    (is (equal :bad-request
               (first (nyaa:tool-error (tool :tool-eval :form "(+ 1")))))))

(test eval-reports-a-signalled-form-as-an-error
  (with-tools
    (let ((reason (nyaa:tool-error (tool :tool-eval :form "(error \"boom\")"))))
      (is (eq :error (first reason)))
      (is (search "boom" (second reason))))))

(test eval-does-not-evaluate-at-read-time
  ;; *READ-EVAL* is nil in the worker, so #. never runs.
  (with-tools
    (is (equal :bad-request
               (first (nyaa:tool-error
                       (tool :tool-eval :form "'#.(error \"read-eval ran\")")))))))

(test eval-keeps-no-state-between-calls
  (with-tools
    (is (eq :ok (first (tool :tool-eval :form "(defparameter *x* 1)"))))
    (let ((reason (nyaa:tool-error (tool :tool-eval :form "*x*"))))
      (is (eq :error (first reason))))))

(test eval-enforces-its-timeout-and-stays-alive
  (with-tools
    (is (eq :timeout (nyaa:tool-error (tool :tool-eval :form "(loop)"
                                                       :timeout 500))))
    (is (equal "4" (result-value (tool :tool-eval :form "(+ 2 2)") :value)))))

(test eval-requires-a-form
  (with-tools
    (is (equal :bad-request
               (first (nyaa:tool-error (tool :tool-eval :timeout 100)))))))

;;; --- repl --------------------------------------------------------------

(test repl-threads-state-through-one-session
  (with-tools
    (tool :tool-repl :id "a" :form "(defparameter *x* 41)")
    (is (equal "42" (result-value (tool :tool-repl :id "a" :form "(incf *x*)")
                                  :value)))))

(test repl-sessions-are-isolated
  (with-tools
    (tool :tool-repl :id "a" :form "(defparameter *x* 1)")
    (is (eq :error (first (nyaa:tool-error
                           (tool :tool-repl :id "b" :form "*x*")))))))

(test repl-pristine-restarts-the-session-empty
  (with-tools
    (tool :tool-repl :id "a" :form "(defparameter *x* 1)")
    (is (eq :error (first (nyaa:tool-error
                           (tool :tool-repl :id "a" :form "*x*"
                                            :pristine t)))))))

(test repl-timeout-restarts-the-session-empty
  (with-tools
    (tool :tool-repl :id "a" :form "(defparameter *x* 1)")
    (is (eq :timeout (nyaa:tool-error (tool :tool-repl :id "a" :form "(loop)"
                                                       :timeout 500))))
    ;; The killed worker is forgotten, so the id answers again -- empty.
    (is (eq :error (first (nyaa:tool-error
                           (tool :tool-repl :id "a" :form "*x*")))))))

(test repl-session-from-an-earlier-image-is-reported-lost-then-starts-empty
  ;; Bumping *BOOT* makes the live worker read as inherited from a saved
  ;; core: it must be dropped without being signalled.
  (with-tools
    (tool :tool-repl :id "a" :form "(defparameter *x* 1)")
    (let ((old-pid (parse-integer
                    (result-value (tool :tool-repl :id "a" :form +getpid-form+) :value)))
          (boot nyaa::*boot*))
      (unwind-protect
           (progn
             (setf nyaa::*boot* (list :later-boot))
             (let ((lost (tool :tool-repl :id "a" :form "*x*")))
               (is (eq :error (first (nyaa:tool-error lost))))
               (is (search "relaunch" (second (nyaa:tool-error lost)))))
             (is (unix-process-alive-p old-pid))
             (is (equal "NIL" (result-value (tool :tool-repl :id "a" :form "(boundp '*x*)")
                                            :value)))
             ;; the second worker dies under the token it started with
             (m:stop-and-wait *context*))
        (setf nyaa::*boot* boot)
        (uiop:run-program (list "/bin/kill" "-9" (princ-to-string old-pid))
                          :ignore-error-status t)))))

(test repl-workers-die-with-the-service
  (let ((pids '()))
    (with-tools
      (dolist (id '("a" "b"))
        (push (parse-integer
               (result-value (tool :tool-repl :id id :form +getpid-form+) :value))
              pids))
      (is (every #'unix-process-alive-p pids)))
    ;; The fixture stopped the context, which unwinds the effect holding
    ;; each worker.
    (dolist (pid pids)
      (is (wait-for-exit pid)))))

(test worker-leads-its-own-process-group
  ;; ~takeiteasy/nyaa#16 also covers workers: a form that backgrounds a
  ;; process must be signalled along with the worker at kill time, which
  ;; needs the worker itself to lead its own group.
  (if (not (process-group-containment-available-p))
      (skip "no process-group mechanism on this host")
      (with-tools
        (let ((pid (parse-integer
                    (result-value (tool :tool-repl :id "g" :form +getpid-form+) :value))))
          (is (eql pid (unix-pgid pid)))))))

(test repl-requires-a-form
  (with-tools
    (is (equal :bad-request
               (first (nyaa:tool-error (tool :tool-repl :timeout 100)))))))

;;; --- repl concurrency (~takeiteasy/nyaa#27) ------------------------------

(test repl-sessions-run-concurrently
  ;; A long eval on one id must not block another, or the tool's own
  ;; :describe, which every id's session shares no process with.
  (with-tools
    (let ((thread (tool-thread (tool :tool-repl :id "slow" :form "(sleep 2)"))))
      (sleep 0.2) ;; let "slow"'s session start its eval first
      (let ((start (get-internal-real-time)))
        (is (equal "3" (result-value (tool :tool-repl :id "fast" :form "(+ 1 2)")
                                     :value)))
        (is (< (- (get-internal-real-time) start)
               internal-time-units-per-second))
        (is (nyaa:describe-tool :tool-repl)))
      (bt:join-thread thread))))

(test repl-calls-on-one-id-still-run-in-order
  (with-tools
    (tool :tool-repl :id "a" :form "(defparameter *log* nil)")
    (let ((threads (list (tool-thread (tool :tool-repl :id "a"
                                            :form "(push 1 *log*)"))
                         (tool-thread (tool :tool-repl :id "a"
                                           :form "(push 2 *log*)")))))
      (mapc #'bt:join-thread threads)
      (is (equal "2" (result-value (tool :tool-repl :id "a" :form "(length *log*)")
                                   :value))))))

(test unmounting-tool-repl-answers-a-queued-call-promptly
  ;; Whichever settles the caller's cell first -- the session replying
  ;; (:error :unavailable), or tool-repl's own process exiting under it as
  ;; an ordinary M:CALL failure, folded by INVOKE-TOOL into the same shape
  ;; (~takeiteasy/nyaa#106) -- the caller must not be left waiting out its
  ;; full timeout, and either way sees a proper (:error ...) result.
  (with-tools
    (let* ((result nil)
           (thread (tool-thread
                    (setf result (tool :tool-repl :id "a" :form "(sleep 5)")))))
      (sleep 0.2) ;; let the session start its eval first
      (let ((start (get-internal-real-time)))
        (m:unmount *context* :tool-repl)
        (bt:join-thread thread)
        (is (< (- (get-internal-real-time) start)
               (* 2 internal-time-units-per-second))))
      (is-true (nyaa:tool-error-p result)))))

(test unmounting-tool-repl-refuses-an-eval-queued-behind-the-live-one
  ;; The second call sits in the session's mailbox behind the first, so it
  ;; is still there when the cleanup's own :stop reaches the session --
  ;; it must not start a fresh worker for CLOSED to leave unkilled.
  (with-tools
    (let* ((first-result nil) (second-result nil)
           (first (tool-thread
                   (setf first-result (tool :tool-repl :id "a" :form "(sleep 5)"))))
           (second (progn
                     (sleep 0.1) ;; let the first eval actually start
                     (tool-thread
                      (setf second-result (tool :tool-repl :id "a" :form "1"))))))
      (sleep 0.1) ;; let the second cast actually queue behind the first
      (let ((start (get-internal-real-time)))
        (m:unmount *context* :tool-repl)
        (bt:join-thread first)
        (bt:join-thread second)
        (is (< (- (get-internal-real-time) start)
               (* 2 internal-time-units-per-second))))
      (is-true (nyaa:tool-error-p first-result))
      (is-true (nyaa:tool-error-p second-result)))))

;;; --- elision and REPL history (~takeiteasy/nyaa#26) ---------------------

(test repl-history-reaches-an-elided-value
  (with-tools
    (let ((made (tool :tool-repl :id "a" :form "(make-list 200)")))
      (is (eq t (result-value made :elided)))
      (is (equal "200" (result-value (tool :tool-repl :id "a" :form "(length *)")
                                     :value))))))

(test repl-history-keeps-two-evals-back
  (with-tools
    (tool :tool-repl :id "a" :form "1")
    (tool :tool-repl :id "a" :form "2")
    (is (equal "1" (result-value (tool :tool-repl :id "a" :form "**") :value)))))

(test repl-history-is-untouched-by-an-erroring-form
  (with-tools
    (tool :tool-repl :id "a" :form "41")
    (nyaa:tool-error (tool :tool-repl :id "a" :form "(error \"boom\")"))
    (is (equal "41" (result-value (tool :tool-repl :id "a" :form "*") :value)))))

;;; --- multiple values (~takeiteasy/nyaa#105) -----------------------------

(test repl-form-returning-several-values-carries-them-all
  (with-tools
    (let ((result (tool :tool-repl :id "a" :form "(floor 7 2)")))
      (is (equal "3" (result-value result :value)))
      (is (equal '("3" "1") (result-value result :values))))))

(test repl-slash-history-reaches-the-second-value
  ;; / holds the whole value list as one object, the same as the standard
  ;; toplevel's: evaluating it returns that list as a single value, from
  ;; which the second value is reachable.
  (with-tools
    (tool :tool-repl :id "a" :form "(floor 7 2)")
    (is (equal "1" (result-value (tool :tool-repl :id "a" :form "(second /)")
                                 :value)))))

(test repl-elides-when-one-of-several-values-is-large
  (with-tools
    (let ((result (tool :tool-repl :id "a" :form "(values 1 (make-list 200))")))
      (is (eq t (result-value result :elided)))
      (is (equal "1" (first (result-value result :values)))))))

;;; --- idle reaping (~takeiteasy/nyaa#104) --------------------------------

(test idle-tool-repl-reaps-an-unused-id
  (with-tools
    (m:unmount *context* :tool-repl)
    (m:mount *context* 'nyaa:tool-repl :idle 0.3)
    (let ((pid (parse-integer
                (result-value (tool :tool-repl :id "a" :form +getpid-form+) :value))))
      (is (wait-for-exit pid 2.0))
      ;; the id starts empty again, against a freshly started worker
      (is (not (equal (princ-to-string pid)
                       (result-value (tool :tool-repl :id "a" :form +getpid-form+)
                                     :value)))))))

(test idle-tool-repl-keeps-a-session-with-an-eval-still-in-flight
  (with-tools
    (m:unmount *context* :tool-repl)
    (m:mount *context* 'nyaa:tool-repl :idle 0.3)
    (tool :tool-repl :id "a" :form "(defparameter *x* 1)")
    ;; the sleep runs well past :idle; the idle timer must see the eval as
    ;; in flight and re-arm rather than drop the session out from under it
    (tool :tool-repl :id "a" :form "(sleep 1)" :timeout 5000)
    (is (equal "1" (result-value (tool :tool-repl :id "a" :form "*x*") :value)))))

(test idle-nil-never-reaps
  (with-tools
    (m:unmount *context* :tool-repl)
    (m:mount *context* 'nyaa:tool-repl :idle nil)
    (let ((pid (parse-integer
                (result-value (tool :tool-repl :id "a" :form +getpid-form+) :value))))
      (sleep 0.5)
      (is (equal (princ-to-string pid)
                 (result-value (tool :tool-repl :id "a" :form +getpid-form+) :value))))))
