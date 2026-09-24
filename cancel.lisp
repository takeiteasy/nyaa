(in-package #:nyaa)

;;; A caller-held handle rather than a message: it reaches a turn through
;;; every layer without the caller knowing which service holds it, and
;;; without a service to address it to.

(defstruct (cancel-token (:constructor make-cancel-token ()))
  (lock (bt:make-lock)) cancelled actions)

(defun cancelled-p (token)
  (bt:with-lock-held ((cancel-token-lock token))
    (cancel-token-cancelled token)))

(defun on-cancel (token function)
  "Call FUNCTION when TOKEN is cancelled, at once if it already is."
  (when (bt:with-lock-held ((cancel-token-lock token))
          (or (cancel-token-cancelled token)
              (progn (push function (cancel-token-actions token)) nil)))
    (funcall function)))

(defun cancel (token)
  "Cancel whatever TOKEN was passed to as :CANCEL. Idempotent; true the first
time."
  (let ((actions (bt:with-lock-held ((cancel-token-lock token))
                   (unless (cancel-token-cancelled token)
                     (setf (cancel-token-cancelled token) t)
                     (shiftf (cancel-token-actions token) nil)))))
    (mapc #'funcall actions)
    (and actions t)))
