(in-package #:nyaa/tests)
(in-suite :nyaa)

(test system-loads
  (is (find-package '#:nyaa))
  (is (stringp nyaa:*version*)))

(test meow-is-available
  (is (find-package '#:meow))
  (is (fboundp 'meow:start-service)))
