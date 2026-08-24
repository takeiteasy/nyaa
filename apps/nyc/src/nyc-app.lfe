(defmodule nyc-app
  (behaviour application)
  (export
    (start 2)
    (stop 1)))

;;; OTP application callback for the `nyc` core. Starts the root
;;; supervisor, which in turn starts the registry (see nyc-sup).

(defun start (_type _args)
  (nyc-sup:start_link))

(defun stop (_state)
  'ok)
