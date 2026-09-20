(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; The provider layer against the fake HTTP backend: what a declaration
;;; publishes, what a mount may override, where a credential comes from and
;;; what it looks like on the wire, and that a turn crosses the extra hop
;;; without losing anything.

;;; Every declaration pins a base URL nothing listens on, because the fake
;;; backend's port is only known at run time: each mount overrides it, which
;;; is the same override a remote Ollama host or a proxy uses.

(nyaa:define-provider :test-keyed
  :protocol :protocol-openai
  :base-url "http://127.0.0.1:1"
  :auth '(:bearer :env "NYAA_TEST_KEY_NEVER_SET")
  :models '("test-model" "test-model-large")
  :defaults '(:temperature 0.25)
  :headers '("x-quirk" "on")
  :summary "A bearer-keyed provider for tests")

(nyaa:define-provider :test-header-keyed
  :protocol :protocol-openai
  :base-url "http://127.0.0.1:1"
  :auth '(:header "x-api-key" :env "NYAA_TEST_KEY_NEVER_SET"))

(nyaa:define-provider :test-keyless
  :protocol :protocol-openai
  :base-url "http://127.0.0.1:1"
  :auth :none)

;;; PATH rather than a variable the test sets: no implementation nyaa runs on
;;; offers a portable SETENV, and PATH is the one variable guaranteed to be
;;; there. What is under test is that the key is read from the variable the
;;; declaration names, not which variable that is.

(nyaa:define-provider :test-env-keyed
  :protocol :protocol-openai
  :base-url "http://127.0.0.1:1"
  :auth '(:bearer :env "PATH"))

(nyaa:define-provider :test-orphan
  :protocol :protocol-nobody-mounted
  :base-url "http://127.0.0.1:1")

;;; --- the harness ------------------------------------------------------

(defun call-with-providers (answer mounts body)
  "Run BODY with the OpenAI protocol and MOUNTS up against a fake backend.
Each mount is (class . initargs), with :base-url filled in."
  (let* ((registry (make-instance 'm:registry))
         (m:*registry* registry)
         (context (m:start-service (make-instance 'm:context :name :providers)
                                   :registry registry))
         (server (start-fake-http
                  (lambda (&rest request)
                    (if (functionp answer) (apply answer request) answer)))))
    (setf *backend* server)
    (unwind-protect
         (progn
           (m:mount context 'nyaa:protocol-openai)
           (dolist (mount mounts)
             (apply #'m:mount context (first mount)
                    :base-url (fake-http-url server) (rest mount)))
           (funcall body))
      (m:stop context)
      (stop-fake-http server))))

(defmacro with-providers ((answer &rest mounts) &body body)
  `(call-with-providers ,answer (list ,@mounts) (lambda () ,@body)))

(defun keyed (&rest initargs)
  "The bearer-keyed mount. INITARGS come first, since the leftmost initarg
is the one MAKE-INSTANCE takes."
  (append (list* 'provider-test-keyed initargs)
          '(:model "test-model" :api-key "sk-secret")))

(defun turn (name &rest extra)
  (apply #'nyaa:complete name :messages '((:role :user :content "hello")) extra))

(defun sent-header (name)
  (getf-string (getf (first (fake-http-requests *backend*)) :headers) name))

;;; --- the declaration --------------------------------------------------

(test a-provider-is-discoverable-and-describes-itself
  (with-providers ((json-response +hello-reply+) (keyed))
    (is (equal '(:provider-test-keyed) (nyaa:providers)))
    (let ((metadata (nyaa:describe-provider :provider-test-keyed)))
      (is (eq :provider (getf metadata :kind)))
      (is (eq :protocol-openai (getf metadata :protocol)))
      (is (stringp (getf metadata :summary)))
      (is (equal '("test-model" "test-model-large") (getf metadata :models)))
      (is (equal '(:temperature 0.25) (getf metadata :defaults)))
      (is (eq :ready (getf metadata :status)))
      ;; The auth form names its kind and where the key comes from, never
      ;; the key.
      (is (eq :bearer (getf (getf metadata :auth) :kind)))
      (is (equal "NYAA_TEST_KEY_NEVER_SET" (getf (getf metadata :auth) :env))))))

(test metadata-carries-no-key-material
  (with-providers ((json-response +hello-reply+) (keyed))
    (is (null (search "sk-secret"
                      (princ-to-string
                       (nyaa:describe-provider :provider-test-keyed)))))))

(test a-mount-overrides-the-declaration
  ;; The declaration pins a dead port; only the override makes the turn land.
  (with-providers ((json-response +hello-reply+) (keyed :model "override-model"))
    (let ((metadata (nyaa:describe-provider :provider-test-keyed)))
      (is (equal (fake-http-url *backend*) (getf metadata :base-url)))
      (is (equal "override-model" (getf metadata :model))))
    (is (eq :ok (first (turn :provider-test-keyed))))
    (is (equal "override-model" (gethash "model" (sent-body))))))

(test a-declaration-outside-the-vocabulary-is-a-definition-error
  (flet ((declaration (&rest plist)
           (signals error
             (nyaa::check-provider-declaration
              :provider-broken
              (append plist '(:protocol :protocol-openai
                              :base-url "http://127.0.0.1:1"))))))
    (declaration :auth :oauth)                     ; not one of the three kinds
    (declaration :auth '(:bearer))                 ; a bearer with no :env
    (declaration :auth '(:header :env "VAR"))      ; a header with no name
    (declaration :defaults '(:temperature))        ; not a plist
    (declaration :quirk t))                        ; not a key at all
  ;; And the two the declaration cannot do without.
  (signals error (nyaa::check-provider-declaration :b '(:base-url "http://x")))
  (signals error (nyaa::check-provider-declaration :b '(:protocol :protocol-openai)))
  (signals error (nyaa::check-provider-declaration
                  :b '(:protocol :protocol-openai :base-url "127.0.0.1:11434"))))

;;; --- credentials ------------------------------------------------------

(test bearer-auth-reaches-the-wire
  (with-providers ((json-response +hello-reply+) (keyed))
    (is (eq :ok (first (turn :provider-test-keyed))))
    (is (equal "Bearer sk-secret" (sent-header "authorization")))))

(test header-auth-reaches-the-wire-under-its-own-name
  (with-providers ((json-response +hello-reply+)
                   (list 'provider-test-header-keyed
                         :model "test-model" :api-key "sk-secret"))
    (is (eq :ok (first (turn :provider-test-header-keyed))))
    (is (equal "sk-secret" (sent-header "x-api-key")))
    (is (null (sent-header "authorization")))))

(test a-keyless-provider-authenticates-with-nothing
  (with-providers ((json-response +hello-reply+)
                   (list 'provider-test-keyless :model "test-model"))
    (is (eq :ok (first (turn :provider-test-keyless))))
    (is (null (sent-header "authorization")))
    (is (eq :none (getf (getf (nyaa:describe-provider :provider-test-keyless)
                              :auth)
                        :kind)))))

(test a-key-comes-from-the-environment-variable-the-declaration-names
  (with-providers ((json-response +hello-reply+)
                   (list 'provider-test-env-keyed :model "test-model"))
    (is (eq :ok (first (turn :provider-test-env-keyed))))
    (is (equal (format nil "Bearer ~a" (uiop:getenv "PATH"))
               (sent-header "authorization")))))

(test a-provider-with-no-key-mounts-unavailable-and-stays-off-the-wire
  ;; It mounts, so discovery lists it and the reason is legible without a
  ;; call; the call itself is a bad request rather than an outage.
  (with-providers ((json-response +hello-reply+)
                   (list 'provider-test-keyed :model "test-model"))
    (is (eq :unavailable (getf (nyaa:describe-provider :provider-test-keyed)
                               :status)))
    (let ((reason (nyaa:tool-error (turn :provider-test-keyed))))
      (is (eq :bad-request (first reason)))
      (is (search "NYAA_TEST_KEY_NEVER_SET" (second reason))))
    (is (null (fake-http-requests *backend*)))))

;;; --- layering ---------------------------------------------------------

(test defaults-layer-under-the-request
  (with-providers ((json-response +hello-reply+) (keyed))
    (turn :provider-test-keyed)
    (is (= 0.25d0 (gethash "temperature" (sent-body)))))
  (with-providers ((json-response +hello-reply+) (keyed))
    (turn :provider-test-keyed :temperature 0.9)
    (is (= 0.9d0 (gethash "temperature" (sent-body))))))

(test quirk-headers-travel-and-the-caller-outranks-them
  (with-providers ((json-response +hello-reply+) (keyed))
    (turn :provider-test-keyed)
    (is (equal "on" (sent-header "x-quirk"))))
  (with-providers ((json-response +hello-reply+) (keyed))
    ;; Matched without case, as HTTP names are.
    (turn :provider-test-keyed :headers '("X-Quirk" "off"))
    (is (equal "off" (sent-header "x-quirk")))))

(test a-mount-that-binds-no-model-leaves-the-requirement-to-the-caller
  (with-providers ((json-response +hello-reply+)
                   (list 'provider-test-keyless))
    (is (eq :bad-request (first (nyaa:tool-error (turn :provider-test-keyless)))))
    (is (eq :ok (first (turn :provider-test-keyless :model "asked-for"))))
    (is (equal "asked-for" (gethash "model" (sent-body))))))

;;; --- the turn crosses the hop -----------------------------------------

(test a-turn-crosses-the-provider-unchanged
  (with-providers ((json-response +hello-reply+) (keyed))
    (let ((reply (second (turn :provider-test-keyed))))
      (is (equal "hi there" (nyaa:content-text (getf reply :content))))
      (is (eq :stop (getf (getf reply :meta) :finish-reason)))
      (is (= 7 (getf (getf (getf reply :meta) :usage) :prompt-tokens))))))

(test a-streamed-turn-crosses-the-provider
  (with-providers ((sse-response
                    "{\"choices\":[{\"delta\":{\"content\":\"hi \"}}]}"
                    "{\"choices\":[{\"delta\":{\"content\":\"there\"}}]}"
                    "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"
                    "[DONE]")
                   (keyed))
    (let* ((events '())
           (result (turn :provider-test-keyed :ref :r1
                         :stream (lambda (event) (push event events)))))
      (is (equal '(:text-delta :text-delta :done)
                 (mapcar (lambda (event) (getf event :type)) (nreverse events))))
      (is (equal "hi there" (nyaa:content-text (getf (second result) :content)))))))

(test a-tool-call-crosses-the-provider-ready-to-invoke
  (with-providers ((json-response
                     "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,
                        \"tool_calls\":[{\"id\":\"c9\",\"type\":\"function\",
                          \"function\":{\"name\":\"tool-shell\",
                            \"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}]},
                        \"finish_reason\":\"tool_calls\"}]}")
                   (keyed))
    (let ((call (first (getf (second (turn :provider-test-keyed)) :tool-calls))))
      (is (eq :tool-shell (getf call :name)))
      (is (equal "ls" (getf (getf call :arguments) :cmd))))))

;;; --- errors -----------------------------------------------------------

(test a-backend-error-crosses-the-provider-intact
  (with-providers ('(429 ("Content-Type" "application/json")
                     "{\"error\":{\"message\":\"rate limited\"}}")
                   (keyed))
    (let ((reason (nyaa:tool-error (turn :provider-test-keyed))))
      (is (eq :backend-error (first reason)))
      (is (= 429 (second reason)))
      (is (search "rate limited" (third reason))))))

(test an-unreachable-backend-crosses-the-provider-as-unavailable
  (with-providers (:close (keyed))
    (is (eq :unavailable (nyaa:tool-error (turn :provider-test-keyed))))))

(test a-malformed-request-never-leaves-the-provider
  (with-providers ((json-response +hello-reply+) (keyed))
    (is (eq :bad-request
            (first (nyaa:tool-error (nyaa:complete :provider-test-keyed
                                                   :messages '((:role :wizard)))))))
    (is (null (fake-http-requests *backend*)))))

(test a-provider-whose-protocol-is-not-mounted-is-unavailable
  (with-providers ((json-response +hello-reply+)
                   (list 'provider-test-orphan :model "test-model"))
    (is (eq :unavailable (nyaa:tool-error (turn :provider-test-orphan))))))

;;; --- the ollama provider ----------------------------------------------

(test ollama-declares-a-keyless-openai-backend
  (with-providers ((json-response +hello-reply+)
                   (list 'nyaa:provider-ollama :model "llama3.2"))
    (let ((metadata (nyaa:describe-provider :provider-ollama)))
      (is (eq :provider (getf metadata :kind)))
      (is (eq :protocol-openai (getf metadata :protocol)))
      (is (eq :none (getf (getf metadata :auth) :kind)))
      (is (eq :ready (getf metadata :status)))
      (is (member "llama3.2" (getf metadata :models) :test #'equal)))
    (is (eq :ok (first (turn :provider-ollama))))
    (is (equal "llama3.2" (gethash "model" (sent-body))))
    (is (null (sent-header "authorization")))))

(test ollama-pins-the-local-endpoint-by-default
  ;; Read from the declaration rather than a mount, so the default cannot
  ;; drift without this failing.
  (is (equal "http://127.0.0.1:11434/v1"
             (getf (nyaa::provider-declaration
                    (make-instance 'nyaa:provider-ollama))
                   :base-url))))

;;; --- live -------------------------------------------------------------

(test ollama-live-completion-through-the-provider
  ;; Off by default: CI must not depend on a model being installed.
  (let ((base-url (uiop:getenv "NYAA_OLLAMA_URL"))
        (model (or (uiop:getenv "NYAA_OLLAMA_MODEL") "llama3.2")))
    (if (null base-url)
        (skip "set NYAA_OLLAMA_URL to run live Ollama tests")
        (let* ((registry (make-instance 'm:registry))
               (m:*registry* registry)
               (context (m:start-service (make-instance 'm:context :name :live)
                                         :registry registry)))
          (unwind-protect
               (progn
                 (m:mount context 'nyaa:protocol-openai)
                 (m:mount context 'nyaa:provider-ollama
                          :base-url base-url :model model)
                 (let ((result (nyaa:complete
                                :provider-ollama :timeout 120000
                                :messages '((:role :user
                                             :content "Reply with the word ok.")))))
                   (if (model-missing-p result)
                       (skip "~a has no model ~a; set NYAA_OLLAMA_MODEL" base-url model)
                       (progn
                         (is (eq :ok (first result)))
                         (is (plusp (length (nyaa:content-text
                                             (getf (second result) :content)))))))))
            (m:stop context))))))
