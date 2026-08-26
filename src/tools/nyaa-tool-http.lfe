(defmodule nyaa-tool-http
  (export
    (child_spec 0)
    (service_name 0)
    (dependencies 0)
    (metadata 0)
    (init 1)
    (handle_message 2)
    (terminate 2)))

;;; Standard tool plugin: single-shot HTTP client over the OTP stdlib
;;; (`inets` httpc) -- no streaming, no chunked upload; one request in,
;;; one response out, bounded by a caller-provided deadline. Part of
;;; the tool/skill convention (docs/tools.md): registers as
;;; 'tool-http and answers #(describe) / #(invoke req).
;;;
;;; invoke params (all optional except url):
;;;   url      required
;;;   method   verb, default GET, upper-cased before sending
;;;   headers  map or list of name/value pairs, sent verbatim
;;;   body     binary or charlist payload (sent when present)
;;;   timeout  whole-exchange ms, default 30000 (also connect ceiling)
;;;
;;; success:  #(ok #m(status headers body)) -- status integer, headers
;;;           lower-cased into a binary-keyed map, body a binary.
;;; failure:  same canonical surface as the model adapters so callers
;;;           need only one error vocabulary:
;;;             #(error unavailable)               dial failures
;;;             #(error #(bad_request msg))        malformed invoke
;;;             #(error timeout)                   deadline lapsed
;;;             #(error #(error reason))           anything else httpc
;;;                                                surfaced
;;; Redirects are NOT followed automatically (autoredirect false):
;;; callers decide what a 3xx means for them.
;;;
;;; Trust posture: arbitrary network egress from the node -- trusted
;;; operator only, like tool-shell.

(defun child_spec ()
  `#m(id tool-http
      start #(patchbay_service start_link (nyaa-tool-http #m()))
      restart transient
      shutdown 5000
      type worker
      modules (patchbay_service)))

(defun service_name () 'tool-http)
(defun dependencies () '())

(defun metadata ()
  (describe))

(defun init (_args)
  ;;; nyaa already depends on inets; defensive re-start is harmless.
  (application:ensure_all_started 'inets)
  `#(ok #m()))

(defun terminate (_reason _state) 'ok)

(defun describe ()
  #m(kind tool
     name 'tool-http
     summary #"Perform a single-shot HTTP request via stdlib httpc"
     params #m(url "target URL, http(s), required"
               method "HTTP verb (default GET, upper-cased)"
               headers "map of extra headers (optional)"
               body "request payload, binary or charlist (optional)"
               timeout "whole-exchange deadline in ms (default 30000)")))

;;; --- request assembly ------------------------------------------------------

(defun handle_message
  (('describe state) `#(reply ,(describe) ,state))
  ((`#(invoke ,req) state)
   (if (not (is_map req))
     `#(reply #(error #(bad_request "request must be a map")) ,state)
     `#(reply ,(run-invoke req) ,state))))

(defun run-invoke (req)
  (case (require-url req)
    (`#(error ,reason) `#(error ,reason))
    (`#(ok ,url-chars)
     (case (validate-common req)
       (`#(error ,reason) `#(error ,reason))
       (`#(ok ,headers ,body ,timeout-ms)
        (do-request (method-of req) url-chars headers body timeout-ms))))))

(defun method-of (req)
  (let ((given (maps:get 'method req 'absent)))
    (if (=:= given 'absent)
      "GET"
      (upper-verb given))))

(defun upper-verb (v)
  (cond
    ((is_atom v) (string:uppercase (atom_to_list v)))
    ((is_binary v) (string:uppercase (unicode:characters_to_list v 'utf8)))
    ((is_list v) (string:uppercase v))
    ('true "GET")))

(defun require-url (req)
  (case (maps:find 'url req)
    (`#(ok ,url)
     (case (to-text url)
       (`#(ok ,chars) `#(ok ,chars))
       (`#(error ,_) `#(error #(bad_request "url must be a string")))))
    ('error
     '#(error #(bad_request "url required")))))

(defun to-text (v)
  (cond
    ((is_binary v) `#(ok ,(unicode:characters_to_list v 'utf8)))
    ((is_list v) `#(ok ,v))
    ('true '#(error bad))))

(defun validate-common (req)
  (let* ((header-pairs (pairs-of (maps:get 'headers req 'absent)))
         (body (body-normalized (maps:get 'body req 'absent)))
         (timeout (maps:get 'timeout req 30000))
         (timeout-ok (and (is_integer timeout) (> timeout 0))))
    (cond
      ((=:= header-pairs 'bad)
       '#(error #(bad_request "headers must be a map or pair list")))
      ((=:= body 'bad)
       '#(error #(bad_request "body must be binary or charlist")))
      ((not timeout-ok)
       '#(error #(bad_request "timeout must be positive ms")))
      ('true
       `#(ok ,(lowered-headers header-pairs) ,body ,timeout)))))

(defun pairs-of (absent-or-headers)
  (cond
    ((=:= absent-or-headers 'absent) '())
    ((is_map absent-or-headers)
     (lists:map
       (lambda (pair)
         (list (to-chars (element 1 pair))
               (to-chars (element 2 pair))))
       (maps:to_list absent-or-headers)))
    ((is_list absent-or-headers) absent-or-headers)
    ('true 'bad)))

(defun body-normalized (given)
  (cond
    ((=:= given 'absent) "")
    ((orelse (is_binary given) (is_list given)) given)
    ('true 'bad)))

(defun lowered-headers (pairs)
  (lists:map
    (lambda (pair)
      (list (string:lowercase (car pair)) (cadr-of pair)))
    pairs))

(defun to-chars (v)
  (cond
    ((is_atom v) (atom_to_list v))
    ((is_binary v) (unicode:characters_to_list v 'utf8))
    ((is_list v) v)
    ('true "")))

(defun cadr-of (l) (car (cdr l)))

;;; --- transport ---------------------------------------------------------------
(defun do-request (method url headers body timeout-ms)
  (let* ((request
           (tuple url
                  headers
                  (content-type-for headers body)
                  body))
         (http-opts
           (list '(autoredirect false)
                 (tuple 'timeout timeout-ms)
                 (tuple 'connect_timeout (min timeout-ms 10000))))
         ;;; VALUE-style catch (no clauses): failures arrive wrapped as
         ;;; #(EXIT _) and are classified below -- avoids the try/catch
         ;;; clause-syntax minefield entirely.
         (answer
           (catch
             (httpc:request
               (erlang:list_to_atom method)
               request
               http-opts
               '(full_result false)))))
    (cond
      ((httpc-exit? answer)
       '#(error #(error "httpc raised unexpectedly")))
      ((httpc-success? answer)
       (let* ((meta (element 1 (element 2 answer)))
              (hdrs (element 2 (element 2 answer)))
              (payload (element 3 (element 2 answer)))
              (code (element 2 meta)))
         `#(ok #m(status ,code
                  headers ,(headers->map hdrs)
                  body ,(as-binary payload)))))
      ((and (is_tuple answer) (=:= 2 (erlang:tuple_size answer))
            (=:= 'error (element 1 answer)))
       (classify (element 2 answer)))
      ('true
       '#(error #(error "unexpected httpc reply shape"))))))

(defun httpc-exit? (a)
  (and (is_tuple a)
       (=:= 2 (erlang:tuple_size a))
       (=:= 'EXIT (element 1 a))))

(defun httpc-success? (a)
  (and (is_tuple a)
       (=:= 2 (erlang:tuple_size a))
       (=:= 'ok (element 1 a))
       (is_tuple (element 2 a))
       (=:= 3 (erlang:tuple_size (element 2 a)))
       (is_tuple (element 1 (element 2 a)))))
(defun content-type-for (headers body)
  (case (lists:keyfind "content-type" 1 headers)
    ('false
     (if (=:= body "") ""
       "application/octet-stream"))
    (_found "")))

(defun headers->map (pairs)
  (lists:foldl
    (lambda (pair acc)
      (maps:put
        (iolist_to_binary (to-chars (string:lowercase (car pair))))
        (as-binary (cadr-of pair))
        acc))
    #m()
    pairs))

(defun as-binary (payload)
  (cond
    ((is_binary payload) payload)
    ('true (iolist_to_binary payload))))

(defun classify (reason)
  (cond
    ((dial-failure? reason) '#(error unavailable))
    ((=:= reason 'timeout) '#(error timeout))
    ('true
     `#(error #(error ,(term-detail reason))))))

(defun term-detail (reason)
  (let ((printed (catch (list_to_binary (io_lib:format "~200w" (list reason))))))
    (if (is_binary printed)
      printed
      #"unexpected transport failure")))

(defun dial-failure? (reason)
  (cond
    ((not (orelse (is_tuple reason) (is_atom reason))) 'false)
    ((is_tuple reason)
     (=:= (element 1 reason) 'failed_connect))
    ('true
     (lists:member reason
                   '(econnrefused nxdomain ehostunreach enetunreach
                     etimedout econnreset)))))
