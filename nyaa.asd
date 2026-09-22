(defsystem "nyaa"
  :description "Not Your Average Agent: an agent harness built on meow."
  :author "George Watson"
  :license "GPLv3"
  :version "0.1.0"
  :depends-on ("meow" "alexandria" "com.inuoe.jzon" "drakma" "flexi-streams"
               "usocket" "bordeaux-threads" "uiop")
  :serial t
  :components ((:file "package")
               (:file "nyaa")
               (:file "schema")
               (:file "tool")
               (:file "protocol")
               (:file "worker")
               (:static-file "worker-program.lisp")
               (:module "tools"
                :components ((:file "fs")
                             (:file "shell")
                             (:file "http")
                             (:file "eval")
                             (:file "repl")))
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
                :components ((:file "ollama"))))
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
               (:file "worker")
               (:file "tools"))
  :perform (test-op (o c)
             (unless (symbol-call :fiveam :run! :nyaa)
               (error "nyaa tests failed"))))
