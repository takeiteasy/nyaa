(in-package #:nyaa/tests)
(in-suite :nyaa)

;;; DEFINE-TOOL, DEFINE-PROTOCOL and DEFINE-PROVIDER fill a table
;;; ENSURE-MOUNTED reads, so a service mounts by name.

(defmacro with-fresh-context ((context) &body body)
  `(let* ((registry (make-instance 'm:registry))
          (m:*registry* registry)
          (,context (m:start-service (make-instance 'm:context :name :definitions)
                                     :registry registry)))
     (unwind-protect (progn ,@body)
       (m:stop ,context))))

(test each-macro-records-its-definition
  (is (member :tool-shell (nyaa:definitions :kind :tool)))
  (is (member :protocol-ollama (nyaa:definitions :kind :protocol)))
  (is (member :protocol-openai (nyaa:definitions :kind :protocol)))
  (is (member :provider-ollama (nyaa:definitions :kind :provider)))
  (is (not (member :tool-shell (nyaa:definitions :kind :provider)))))

(test ensure-mounted-mounts-a-providers-protocol-first
  (with-fresh-context (context)
    (nyaa:ensure-mounted context :provider-ollama :model "llama3.2")
    (is-true (m:lookup :protocol-ollama))
    (is (equal "llama3.2" (getf (nyaa:describe-provider :provider-ollama) :model)))))

(test ensure-mounted-twice-mounts-once
  (with-fresh-context (context)
    (nyaa:ensure-mounted context :tool-shell)
    (let ((process (m:lookup :tool-shell)))
      (nyaa:ensure-mounted context :tool-shell)
      (is (eq process (m:lookup :tool-shell))))))

(test ensure-mounted-refuses-an-undefined-name
  (with-fresh-context (context)
    (signals error (nyaa:ensure-mounted context :tool-nobody-defined))))
