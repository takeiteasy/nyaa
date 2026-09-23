(in-package #:nyaa/tests)

(def-suite :nyaa)
(in-suite :nyaa)

(defun eventually (function &optional (timeout 2))
  "Poll FUNCTION until it returns true or TIMEOUT seconds pass."
  (loop with deadline = (+ (get-internal-real-time) (* timeout internal-time-units-per-second))
        for value = (funcall function)
        until (or value (> (get-internal-real-time) deadline))
        do (sleep 0.01)
        finally (return value)))
