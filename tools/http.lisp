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
        :trust :operator
        :summary "Perform a single-shot HTTP request"
        :params `((:url string :required t :doc "target URL, http or https")
                  (:method (member :get :post :put :patch :delete :head :options)
                   :default :get :doc "HTTP verb")
                  (:headers (map-of string) :doc "extra request headers")
                  (:body string :doc "request payload")
                  (:timeout (integer 1) :default ,+default-tool-timeout+
                   :doc "whole-exchange deadline in milliseconds"))))

(define-tool-handler tool-http (service args)
  (perform-request (getf args :url)
                   (getf args :method)
                   (header-alist (getf args :headers))
                   (getf args :body)
                   (getf args :timeout)))

(defun header-alist (headers)
  "HEADERS, a coerced plist of names and values, as a lower-cased alist."
  (loop for (name value) on headers by #'cddr
        collect (cons (string-downcase name) value)))

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
                 :method method
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
