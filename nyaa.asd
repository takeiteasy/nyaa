(defsystem "nyaa"
  :description "Not Your Average Agent: an agent harness built on meow."
  :author "George Watson"
  :license "GPLv3"
  :version "0.1.0"
  :depends-on ("meow" "alexandria" "com.inuoe.jzon" "drakma" "flexi-streams"
               "usocket" "bordeaux-threads" "uiop")
  :pathname "src/"
  :serial t
  :components ((:file "package")
               (:file "nyaa")
               (:file "schema")
               (:file "tools")
               (:file "protocol")
               (:file "tool-fs")
               (:file "tool-shell")
               (:file "tool-http")
               (:file "worker")
               (:static-file "worker-program.lisp")
               (:file "tool-eval")
               (:file "tool-repl"))
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
               (:file "worker")
               (:file "tools"))
  :perform (test-op (o c)
             (unless (symbol-call :fiveam :run! :nyaa)
               (error "nyaa tests failed"))))
