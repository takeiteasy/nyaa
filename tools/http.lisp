(in-package #:nyaa)

;;; Single-shot HTTP client. One request in, one response out, bounded by a
;;; caller deadline. Redirects are not followed and statuses pass through
;;; untouched: callers decide what a 3xx or a 404 means for them.
;;;
;;; The connection is opened here rather than left to drakma, so the
;;; deadline has a socket of its own to close: drakma's :connection-timeout
;;; only bounds connecting, not the whole exchange, and closing what it
;;; opened internally is not an option it offers. See PERFORM-REQUEST.
;;;
;;; Trust posture: arbitrary network egress. Trusted operator only.

(define-tool :tool-http
    (:trust :operator
     :summary "Perform a single-shot HTTP request"
     :params ((:url string :required t :doc "target URL, http or https")
              (:method (member :get :post :put :patch :delete :head :options)
               :default :get :doc "HTTP verb")
              (:headers (map-of string) :doc "extra request headers")
              (:body string :doc "request payload")
              (:timeout (integer 1) :default +default-tool-timeout+
               :doc "whole-exchange deadline in milliseconds")))
  (:invoke (url method headers body timeout)
    (perform-request url method (header-alist headers) body timeout)))

(defun header-alist (headers)
  "HEADERS, a coerced plist of names and values, as a lower-cased alist."
  (loop for (name value) on headers by #'cddr
        collect (cons (string-downcase name) value)))

(defun perform-request (url method headers body timeout-ms)
  ;; SOCKET-BOX carries the connection out of the worker thread as soon as
  ;; ATTEMPT-REQUEST opens it, so a lapsed deadline -- or the worker's own
  ;; unwind -- has something to close. ABANDONABLE-BOX is true only while
  ;; the worker is inside ATTEMPT-REQUEST, so ABANDON-REQUEST's interrupt
  ;; never throws to a catch tag that isn't there.
  (let* ((result nil)
         (socket-box (list nil))
         (abandonable-box (list nil))
         (done (bt:make-semaphore))
         (worker (bt:make-thread
                  (lambda ()
                    (unwind-protect
                         (setf result
                               (catch 'abandoned
                                 (setf (car abandonable-box) t)
                                 (unwind-protect
                                      (attempt-request url method headers body
                                                       socket-box timeout-ms)
                                   (setf (car abandonable-box) nil))))
                      ;; Whatever unwound the worker -- a normal return, an
                      ;; error, or ABANDON-REQUEST's interrupt -- its own
                      ;; socket is its own to close.
                      (let ((socket (car socket-box)))
                        (when socket (ignore-errors (usocket:socket-close socket))))
                      (bt:signal-semaphore done)))
                  :name "nyaa-http-request")))
    (if (bt:wait-on-semaphore done :timeout (/ timeout-ms 1000))
        result
        (progn (abandon-request worker socket-box abandonable-box)
               (fail :timeout)))))

(defun abandon-request (worker socket-box abandonable-box)
  "Unblocks WORKER wherever the deadline found it -- connecting, writing, or
waiting on a response -- so it errors out and unwinds instead of running
until the server answers or the connection drops.

#-ecl: closing the socket from its own thread reliably wakes the worker's
blocked read.

#+ecl: closing a socket from another thread does not wake a thread already
blocked reading from it there -- the close call blocks right alongside it
until the peer resolves the connection. The worker is interrupted directly
instead; ABANDONABLE-BOX guards the throw, since outside ATTEMPT-REQUEST
there is no 'ABANDONED catch waiting for it. The worker's own unwind then
closes its socket."
  (declare (ignorable worker socket-box abandonable-box))
  #-ecl
  (let ((socket (car socket-box)))
    (when socket
      (bt:make-thread (lambda () (ignore-errors (usocket:socket-close socket)))
                      :name "nyaa-http-close")))
  #+ecl
  (ignore-errors
   (when (bt:thread-alive-p worker)
     (bt:interrupt-thread
      worker (lambda () (when (car abandonable-box) (throw 'abandoned nil)))))))

(defun attempt-request (url method headers body socket-box timeout-ms)
  (handler-case
      (let* ((uri (puri:parse-uri url))
             (securep (eq (puri:uri-scheme uri) :https))
             (socket (usocket:socket-connect
                      (puri:uri-host uri) (or (puri:uri-port uri) (if securep 443 80))
                      :element-type '(unsigned-byte 8)
                      ;; Bounds the connect phase alone, ahead of the whole-
                      ;; exchange deadline above -- a bound drakma does not
                      ;; offer on ECL, where :connection-timeout is a no-op.
                      :timeout (max 1 (ceiling timeout-ms 1000))
                      :nodelay :if-supported)))
        (setf (car socket-box) socket)
        ;; Drakma returns 4xx and 5xx as values rather than signalling, which
        ;; is what lets statuses pass through with no translation layer.
        (multiple-value-bind (payload status response-headers)
            (apply #'drakma:http-request
                   url
                   :method method
                   :stream (wrap-http-stream socket (puri:uri-host uri) securep)
                   :close t
                   :redirect nil
                   ;; Content-Type is drakma's own argument. Leaving it in
                   ;; ADDITIONAL-HEADERS too would send it twice; dropping it
                   ;; without folding it in would silently override what the
                   ;; caller asked for.
                   :additional-headers (remove "content-type" headers
                                               :key #'car :test #'string=)
                   (when body
                     (list :content body
                           :content-type (or (cdr (assoc "content-type" headers
                                                         :test #'string=))
                                             "application/octet-stream"))))
          (ok :status status
              :headers (loop for (name . value) in response-headers
                             collect (string-downcase (string name))
                             collect value)
              :body (response-string payload))))
    (usocket:socket-error () (fail :unavailable))
    (error (e) (fail (list :error (princ-to-string e))))))

(defun wrap-http-stream (socket host securep)
  "SOCKET's stream, wrapped exactly as drakma wraps one it opens itself:
chunked framing under a flexi-stream, with SSL attached first when
SECUREP. Passing :stream skips drakma's own wrapping entirely -- it only
adjusts the flexi-stream's element-type and external-format -- so a stream
given raw fails outright, and one without SSL attached sends a TLS
handshake in the clear."
  (let ((raw (usocket:socket-stream socket)))
    (flexi-streams:make-flexi-stream
     (chunga:make-chunked-stream
      (if securep
          (cl+ssl:make-ssl-client-stream raw :hostname host)
          raw))
     ;; Matches drakma's own +LATIN-1+ (specials.lisp), which is internal.
     :external-format (flexi-streams:make-external-format :latin-1 :eol-style :lf))))

(defun response-string (payload)
  "Drakma decodes textual content types to a string and leaves everything
else as octets."
  (if (stringp payload)
      payload
      (flexi-streams:octets-to-string payload :external-format :utf-8)))
