;;; The worker's read/eval/print loop. This file is not part of the nyaa
;;; system: it is read as text at compile time and handed to a bare child
;;; Lisp on its command line, so it must stay a single form that loads
;;; nothing. See worker.lisp for the protocol.

(let ((p (or (find-package "NYAA-WORKER")
             (make-package "NYAA-WORKER" :use '("CL")))))
  (labels ((render-under (v length level)
             (let ((*print-length* length) (*print-level* level)
                   (*print-readably* nil) (*print-circle* t))
               (prin1-to-string v)))
           (render (v)
             ;; Capped, so a large or circular value cannot flood the pipe.
             ;; Elided when the cap cuts the string outright, or when
             ;; printing one step wider would print more of it: that second
             ;; pass only runs when the first output looks cut ("..." from
             ;; *PRINT-LENGTH*, "#" from *PRINT-LEVEL*), so a value that
             ;; fits under both limits prints once.
             (let* ((s (render-under v 100 8))
                    (capped (> (length s) 4000)))
               (values (if capped (concatenate 'string (subseq s 0 4000) " ...") s)
                       (or capped
                           (and (or (find #\# s) (search "..." s))
                                (string/= s (render-under v 101 9)))))))
           (say (form)
             (prin1 form)
             (terpri)
             (finish-output)))
    (let ((*package* p) (*read-eval* nil))
      (say '(:ready))
      (loop
        (let ((message (handler-case (read *standard-input* nil :eof)
                         (error () :eof))))
          (unless (and (consp message) (eq (first message) :eval))
            (return))
          (let ((out (make-string-output-stream)))
            (say (handler-case
                     (let ((form (read-from-string (second message))))
                       (handler-case
                           (let ((value (let ((*standard-output* out)
                                              (*error-output* out))
                                          (eval form))))
                             ;; The REPL's own history, so a value the
                             ;; reply elided can still be inspected: *,
                             ;; **, *** shift the same way the standard
                             ;; toplevel's do. An erroring form below
                             ;; leaves them alone.
                             (setf *** ** ** * * value)
                             (multiple-value-bind (rendered elided) (render value)
                               (list :ok rendered (get-output-stream-string out)
                                     (if elided :elided nil))))
                         (error (e) (list :error (princ-to-string e)
                                          (get-output-stream-string out)))))
                   (error (e) (list :reader-error (princ-to-string e)))))))))))
