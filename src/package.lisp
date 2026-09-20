(defpackage #:nyaa
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:m #:meow)
                    (#:json #:com.inuoe.jzon)
                    (#:bt #:bordeaux-threads-2))
  (:export
   #:*version*
   ;; tool convention
   #:tools #:describe-tool #:invoke-tool
   #:tool-error #:tool-error-p #:tool-trust #:tool-schema
   ;; parameter schemas
   #:validate-schema #:coerce-args
   #:schema->json-schema #:json-schema->schema
   #:array-of #:object #:map-of
   ;; workers
   #:*worker-command*
   ;; tools
   #:tool-fs #:tool-shell #:tool-http #:tool-eval #:tool-repl))
