;;; The worker's read/eval/print loop. This file is not part of the nyaa
;;; system: it is read as text at compile time and handed to a bare child
;;; Lisp on its command line, so it must stay a single form that loads
;;; nothing. See src/worker.lisp for the protocol.

(let ((p (or (find-package "NYAA-WORKER")
             (make-package "NYAA-WORKER" :use '("CL")))))
  (flet ((render (v)
           ;; Capped, so a large or circular value cannot flood the pipe.
           ;; TODO: truncation is silent and the caller cannot ask for more.
           ;; Upgrade path: report that a value was elided, and offer a
           ;; handle to it. Tracked in ~takeiteasy/nyaa#26.
           (let ((*print-length* 100) (*print-level* 8) (*print-readably* nil)
                 (*print-circle* t))
             (let ((s (prin1-to-string v)))
               (if (> (length s) 4000)
                   (concatenate 'string (subseq s 0 4000) " ...")
                   s))))
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
                             (list :ok (render value)
                                   (get-output-stream-string out)))
                         (error (e) (list :error (princ-to-string e)
                                          (get-output-stream-string out)))))
                   (error (e) (list :reader-error (princ-to-string e)))))))))))
