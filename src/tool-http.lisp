(in-package #:nyaa)

;;; Single-shot HTTP client. One request in, one response out, bounded by a
;;; caller deadline. Redirects are not followed and statuses pass through
;;; untouched: callers decide what a 3xx or a 404 means for them.
;;;
;;; Trust posture: arbitrary network egress. Trusted operator only.
;;;
;;; TODO: a request abandoned at the deadline leaves its worker thread
;;; running until the server answers or the connection drops. Upgrade path:
;;; drive the socket directly so the deadline can close it. Tracked in
;;; ~takeiteasy/nyaa#17.

(m:defservice tool-http () ()
  (:name :tool-http))

(defmethod m:metadata ((service tool-http))
  (list :kind :tool
        :name :tool-http
        :summary "Perform a single-shot HTTP request"
        :params '(:url "target URL, http or https"
                  :method "HTTP verb, default GET"
                  :headers "plist of extra request headers"
                  :body "request payload"
                  :timeout "whole-exchange deadline in milliseconds")))

(define-tool-handler tool-http (service args)
  (let ((url (arg-string (getf args :url)))
        (timeout (arg-timeout args))
        (headers (header-alist (getf args :headers))))
    (cond
      ((null url) (bad-request "url required, a string"))
      ((null timeout) (bad-request "timeout must be a positive number of ms"))
      ((eq headers :bad) (bad-request "headers must be a plist"))
      (t (perform-request url
                          (string-upcase (or (arg-string (getf args :method))
                                             "GET"))
                          headers
                          (arg-string (getf args :body))
                          timeout)))))

(defun header-alist (headers)
  "HEADERS, a flat plist of names and values, as a lower-cased alist, or :BAD.
Every element must be usable as text: an alist of pairs has an even length too,
and would otherwise pass as one empty header."
  (cond
    ((null headers) '())
    ((and (listp headers)
          (evenp (length headers))
          (every #'arg-string headers))
     (loop for (name value) on headers by #'cddr
           collect (cons (string-downcase (arg-string name))
                         (arg-string value))))
    (t :bad)))

(defun perform-request (url method headers body timeout-ms)
  (let ((result nil)
        (done (bt:make-semaphore)))
    (bt:make-thread
     (lambda ()
       (unwind-protect
            (setf result (attempt-request url method headers body))
         (bt:signal-semaphore done)))
     :name "nyaa-http-request")
    (if (bt:wait-on-semaphore done :timeout (/ timeout-ms 1000))
        result
        (fail :timeout))))

(defun attempt-request (url method headers body)
  ;; The deadline is PERFORM-REQUEST's, not the client's: drakma only offers
  ;; :connection-timeout, and only on implementations ECL is not among.
  (handler-case
      ;; Drakma returns 4xx and 5xx as values rather than signalling, which
      ;; is what lets statuses pass through with no translation layer.
      (multiple-value-bind (payload status response-headers)
          (apply #'drakma:http-request
                 url
                 :method (a:make-keyword method)
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
            :body (response-string payload)))
    (usocket:socket-error () (fail :unavailable))
    (error (e) (fail (list :error (princ-to-string e))))))

(defun response-string (payload)
  "Drakma decodes textual content types to a string and leaves everything
else as octets."
  (if (stringp payload)
      payload
      (flexi-streams:octets-to-string payload :external-format :utf-8)))
