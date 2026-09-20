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
   #:tool-error #:tool-error-p
   ;; tools
   #:tool-fs #:tool-shell #:tool-http))
