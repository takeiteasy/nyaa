(defpackage #:nyaa/cli
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria)
                    (#:m #:meow)
                    (#:ui #:nyaa/ui)
                    (#:bt #:bordeaux-threads-2))
  (:export #:main #:exit-code))
