(defsystem "nyaa"
  :description "Not Your Average Agent: an agent harness built on meow."
  :author "George Watson"
  :license "GPLv3"
  :version "0.1.0"
  :depends-on ("meow" "alexandria" "com.inuoe.jzon" "drakma")
  :pathname "src/"
  :serial t
  :components ((:file "package")
               (:file "nyaa"))
  :in-order-to ((test-op (test-op "nyaa/tests"))))

(defsystem "nyaa/tests"
  :depends-on ("nyaa" "fiveam" "uiop")
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "suite")
               (:file "smoke"))
  :perform (test-op (o c)
             (unless (symbol-call :fiveam :run! :nyaa)
               (error "nyaa tests failed"))))
