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
      ;;; httpc wants {Name, Value} tuples; a list pair makes
      ;;; httpc:header_parse crash with function_clause.
      (tuple (string:lowercase (car pair)) (cadr-of pair)))
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
  ;;; Shape rules learned against OTP29 httpc:
  ;;;  - verb-less methods (GET) reject four-element requests =>
  ;;;    {error,invalid_request}; only add ctype/body when sending.
  ;;;  - an upper-case verb atom yields {error,invalid_method}.
  (let* ((body-present? (/= body ""))
         (request
           (if (not body-present?)
             (tuple url headers)
             (tuple url
                    (headers-without-content-type headers)
                    (content-type-for headers)
                    body)))
         (http-opts
           (list (tuple 'autoredirect 'false)
                 (tuple 'timeout timeout-ms)
                 (tuple 'connect_timeout (min timeout-ms 10000))))
         (answer
           (catch
             (httpc:request
               (erlang:list_to_atom (string:lowercase method))
               request
               http-opts
               (list `#(full_result true))))))
    (cond
      ((exit-wrapper? answer)
       ;; keep the real reason visible instead of a blanket blob.
       `#(error #(error ,(io_lib:format "~120w" (list (element 2 answer))))))
      ((success-wrapper? answer)
       (let* ((meta (element 1 (element 2 answer)))
              (hdrs (element 2 (element 2 answer)))
              (payload (element 3 (element 2 answer))))
         `#(ok #m(status ,(element 2 meta)
                  headers ,(headers->map hdrs)
                  body ,(as-binary payload)))))
      ((and (is_tuple answer)
            (=:= 2 (erlang:tuple_size answer))
            (=:= 'error (element 1 answer)))
       (classify (element 2 answer)))
      ('true
       '#(error #(error "unexpected httpc reply shape"))))))

(defun exit-wrapper? (a)
  ;;; branch-ordered so element/tuple_size never see non-tuples.
  (cond
    ((not (is_tuple a)) 'false)
    ((/= 2 (erlang:tuple_size a)) 'false)
    ((=:= 'EXIT (element 1 a)) 'true)
    ('true 'false)))

(defun success-wrapper? (a)
  ;;; full-result success shape: {ok, {{Vsn,Code,Phrase}, Hdrs, Body}}
  (cond
    ((not (is_tuple a)) 'false)
    ((/= 2 (erlang:tuple_size a)) 'false)
    ((not (=:= 'ok (element 1 a))) 'false)
    ((not (is_tuple (body-of a))) 'false)
    ((/= 3 (erlang:tuple_size (body-of a))) 'false)
    ;; version slot is a charlist (e.g. "HTTP/1.1"), not a tuple --
    ;; anchor on the integer status code at meta position 2 instead.
    ((not (is_tuple (element 1 (body-of a)))) 'false)
    ((/= 3 (erlang:tuple_size (element 1 (body-of a)))) 'false)
    ((not (is_integer (element 2 (element 1 (body-of a))))) 'false)
    ('true 'true)))

(defun body-of (a) (element 2 a))

(defun content-type-for (headers)
  ;;; httpc wants Content-Type as a dedicated field, not left in the
  ;;; Headers list -- honor a caller-supplied value, default otherwise.
  (case (lists:keyfind "content-type" 1 headers)
    ('false "application/octet-stream")
    (`#(,_name ,value) value)))

(defun headers-without-content-type (headers)
  ;;; the dedicated ContentType field above already covers it; leaving
  ;;; a duplicate in Headers risks httpc sending it twice on the wire.
  (lists:filter
    (lambda (pair) (/= (element 1 pair) "content-type"))
    headers))

(defun headers->map (pairs)
  ;;; httpc headers are {Name, Value} tuples -- use element, never car.
  (lists:foldl
    (lambda (pair acc)
      (maps:put
        (as-lower-bin (element 1 pair))
        (as-binary (element 2 pair))
        acc))
    #m()
    pairs))

(defun as-lower-bin (name)
  (iolist_to_binary
    (to-chars (string:lowercase (unicode:characters_to_list name 'utf8)))))

(defun as-binary (payload)
  (if (is_binary payload)
    payload
    (iolist_to_binary payload)))

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
