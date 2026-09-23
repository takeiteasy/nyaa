#-sbcl
(error "nyaa requires SBCL; running on ~a." (lisp-implementation-type))

(defsystem "nyaa"
  :description "Not Your Average Agent: an agent harness built on meow."
  :author "George Watson"
  :license "GPLv3"
  :version "0.1.0"
  :depends-on ("meow" "meow/logger" "alexandria" "com.inuoe.jzon" "drakma" "flexi-streams"
               "usocket" "bordeaux-threads" "uiop" "puri" "chunga" "cl+ssl")
  :serial t
  :components ((:file "package")
               (:file "nyaa")
               ;; Ahead of worker.lisp and tools/shell.lisp: both launch and
               ;; kill through the process-group helpers declared here.
               (:file "process")
               (:file "schema")
               (:file "tool")
               ;; Right after tool.lisp: CHECKPOINT and ROLLBACK need only
               ;; the SNAPSHOT/RESTORE convention it declares, and every
               ;; tool, protocol and provider file below can then use them
               ;; without a forward reference. The agent's own SNAPSHOT
               ;; method lives in agent.lisp instead, where its slots are.
               (:file "checkpoint")
               ;; After checkpoint.lisp: the vault's log uses its shared
               ;; %APPEND-LOG/%READ-LOG. Ahead of agent.lisp, which records
               ;; and folds a steer through it.
               (:file "vault")
               (:file "protocol")
               (:file "worker")
               (:static-file "worker-program.lisp")
               (:module "tools"
                :components (;; Ahead of "fs": the atomic sandbox walk it
                             ;; uses is declared here.
                             (:file "fs-posix")
                             (:file "fs")
                             (:file "shell")
                             (:file "http")
                             (:file "eval")
                             (:file "repl")
                             (:file "plan")
                             (:file "image")
                             (:file "services")
                             (:file "checkpoint")
                             (:file "self")
                             (:file "vault")))
               (:module "protocols"
                :components ((:file "openai")
                             (:file "ollama")))
               ;; After the protocols: a provider layers its data onto one,
               ;; and DEFINE-PROVIDER is a macro, so :serial order is what
               ;; makes both available to a definition. The shared helpers
               ;; both protocols use -- name/key conversion, JSON value
               ;; coercion, the tools array, the deadline-bounded exchange --
               ;; live in protocol.lisp, ahead of either.
               (:file "provider")
               (:module "providers"
                :components ((:file "ollama")))
               ;; After providers: the loop reaches a model by name through
               ;; COMPLETE, and defaults its tool allow-list from the
               ;; discovered tools, so both must already be defined.
               (:file "agent")
               ;; Last: SAVE-IMAGE needs CHECKPOINT (checkpoint.lisp),
               ;; M:SUSPEND/M:RESUME, and PROVIDER-API-KEY (provider.lisp)
               ;; to refuse a credentialed mount.
               (:file "image-generation"))
  :in-order-to ((test-op (test-op "nyaa/tests"))))

(defsystem "nyaa/tests"
  :depends-on ("nyaa" "fiveam" "uiop" "usocket")
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "suite")
               (:file "schema")
               (:file "smoke")
               (:file "protocol")
               (:file "fake-http")
               (:file "protocol-openai")
               (:file "protocol-ollama")
               (:file "provider")
               (:file "agent")
               (:file "worker")
               (:file "tools")
               (:file "plan")
               (:file "introspect")
               (:file "checkpoint")
               (:file "image-generation")
               (:file "self")
               (:file "vault"))
  :perform (test-op (o c)
             (unless (symbol-call :fiveam :run! :nyaa)
               (error "nyaa tests failed"))))
