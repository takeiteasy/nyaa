(in-package #:nyaa)

;;; Single-shot HTTP client. One request in, one response out, bounded by a
;;; caller deadline. Redirects are not followed and statuses pass through
;;; untouched: callers decide what a 3xx or a 404 means for them.
;;;
;;; The exchange runs under CALL-WITH-DEADLINE, which owns the connection so
;;; the deadline or a cancel can close it.
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
    (perform-request url method (header-alist headers) body timeout cancel-token)))

(defun perform-request (url method headers body timeout-ms &optional cancel)
  (multiple-value-bind (result reason)
      (call-with-deadline timeout-ms
                          (lambda (connect)
                            (attempt-request url method headers body connect))
                          :name "nyaa-http"
                          :cancel cancel)
    (if reason (fail reason) result)))

(defun attempt-request (url method headers body connect)
  (handler-case
      ;; Drakma returns 4xx and 5xx as values rather than signalling, which
      ;; is what lets statuses pass through with no translation layer.
      (multiple-value-bind (payload status response-headers)
          (apply #'drakma:http-request
                 url
                 :method method
                 :stream (funcall connect url)
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
            :body (response-string payload)))
    (usocket:socket-error () (fail :unavailable))
    (error (e) (fail (list :error (princ-to-string e))))))

(defun response-string (payload)
  "Drakma decodes textual content types to a string and leaves everything
else as octets."
  (if (stringp payload)
      payload
      (flexi-streams:octets-to-string payload :external-format :utf-8)))
