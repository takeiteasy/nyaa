(in-package #:nyaa/tests)

;;; Offline stand-in for an HTTP backend. A sequential accept loop serving
;;; one request per connection and always answering Connection: close --
;;; just enough HTTP/1.1 framing to satisfy a real client.
;;;
;;;   (start-fake-http handler) -> server
;;;
;;;     handler := (lambda (&key method path headers body) ...)
;;;       -> (code headers body)  a normal response; headers is a plist
;;;       -> (:raw "bytes")       verbatim bytes, then a hard close
;;;       -> :close               close without sending anything
;;;
;;;   (fake-http-url server)      -> "http://127.0.0.1:<port>"
;;;   (fake-http-requests server) -> oldest-first list of request plists
;;;   (stop-fake-http server)

(defstruct (fake-http (:conc-name fake-))
  socket port thread handler (requests '()) (lock (bt:make-lock)) (running t))

(defun start-fake-http (handler)
  (let* ((socket (usocket:socket-listen "127.0.0.1" 0
                                        :reuse-address t
                                        :element-type '(unsigned-byte 8)))
         (server (make-fake-http :socket socket
                                 :port (usocket:get-local-port socket)
                                 :handler handler)))
    (setf (fake-thread server)
          (bt:make-thread (lambda () (fake-http-loop server))
                          :name "nyaa-fake-http"))
    server))

(defun fake-http-url (server)
  (format nil "http://127.0.0.1:~d" (fake-port server)))

(defun fake-http-requests (server)
  (bt:with-lock-held ((fake-lock server))
    (reverse (fake-requests server))))

(defun stop-fake-http (server)
  (setf (fake-running server) nil)
  ;; Wake the blocked accept with a throwaway connection, and close the
  ;; listener only once the loop has left it.
  (ignore-errors
   (usocket:socket-close (usocket:socket-connect "127.0.0.1" (fake-port server))))
  (ignore-errors (bt:join-thread (fake-thread server)))
  (ignore-errors (usocket:socket-close (fake-socket server)))
  t)

(defun fake-http-loop (server)
  (loop while (fake-running server)
        do (handler-case
               (let ((connection (usocket:socket-accept
                                  (fake-socket server)
                                  :element-type '(unsigned-byte 8))))
                 (unwind-protect
                      (when (fake-running server)
                        (serve-connection server connection))
                   (ignore-errors (usocket:socket-close connection))))
             ;; A half-open wake-up connection, or a listener already gone.
             (error () (return)))))

(defun serve-connection (server connection)
  (let* ((stream (usocket:socket-stream connection))
         (request (read-fake-request stream)))
    (bt:with-lock-held ((fake-lock server))
      (push request (fake-requests server)))
    (let ((answer (apply (fake-handler server) request)))
      (cond
        ((eq answer :close))
        ((and (consp answer) (eq (first answer) :raw))
         (write-fake-bytes stream (second answer)))
        (t (destructuring-bind (code headers body) answer
             (write-fake-response stream code headers body)))))))

;;; --- wire format -----------------------------------------------------

(defun write-fake-bytes (stream text)
  (write-sequence (flexi-streams:string-to-octets text :external-format :utf-8)
                  stream)
  (finish-output stream))

(defun write-fake-response (stream code headers body)
  (let ((payload (flexi-streams:string-to-octets body :external-format :utf-8)))
    (write-fake-bytes
     stream
     (with-output-to-string (out)
       (format out "HTTP/1.1 ~d Reason~c~c" code #\Return #\Newline)
       (loop for (name value) on headers by #'cddr
             do (format out "~a: ~a~c~c" name value #\Return #\Newline))
       (format out "Content-Length: ~d~c~c" (length payload) #\Return #\Newline)
       (format out "Connection: close~c~c~c~c"
               #\Return #\Newline #\Return #\Newline)))
    (write-sequence payload stream)
    (finish-output stream)))

(defun read-fake-line (stream)
  (let ((line (make-array 0 :element-type '(unsigned-byte 8)
                            :adjustable t :fill-pointer t)))
    (loop for byte = (read-byte stream nil nil)
          while (and byte (/= byte 10))
          unless (= byte 13) do (vector-push-extend byte line))
    (flexi-streams:octets-to-string line :external-format :utf-8)))

(defun read-fake-request (stream)
  (let* ((request-line (uiop:split-string (read-fake-line stream)
                                          :separator " "))
         (headers (loop for line = (read-fake-line stream)
                        until (string= line "")
                        for colon = (position #\: line)
                        when colon
                          collect (string-downcase (subseq line 0 colon))
                          and collect (string-trim " " (subseq line (1+ colon)))))
         (length (parse-integer (or (getf-string headers "content-length") "0")
                                :junk-allowed t)))
    (list :method (string-upcase (first request-line))
          :path (subseq (second request-line) 0
                        (position #\? (second request-line)))
          :headers headers
          :body (read-fake-body stream (or length 0)))))

(defun read-fake-body (stream length)
  (let ((octets (make-array length :element-type '(unsigned-byte 8))))
    (read-sequence octets stream)
    (flexi-streams:octets-to-string octets :external-format :utf-8)))

(defun getf-string (plist key)
  (loop for (name value) on plist by #'cddr
        when (string= name key) return value))

;;; --- server-sent events ----------------------------------------------

(defun sse-body (&rest payloads)
  "PAYLOADS, each a JSON chunk, as an SSE body of one data event each."
  (with-output-to-string (out)
    (dolist (payload payloads)
      (format out "data: ~a~c~c~c~c"
              payload #\Return #\Newline #\Return #\Newline))))

(defun sse-response (&rest payloads)
  "An answer a fake handler returns: 200, text/event-stream, PAYLOADS."
  (list 200 '("Content-Type" "text/event-stream")
        (apply #'sse-body payloads)))

;;; --- newline-delimited JSON --------------------------------------------

(defun ndjson-body (&rest payloads)
  "PAYLOADS, each a JSON chunk, as one object per line."
  (format nil "~{~a~%~}" payloads))

(defun ndjson-response (&rest payloads)
  "An answer a fake handler returns: 200, application/x-ndjson, PAYLOADS."
  (list 200 '("Content-Type" "application/x-ndjson")
        (apply #'ndjson-body payloads)))
