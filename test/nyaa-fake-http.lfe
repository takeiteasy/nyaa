(defmodule nyaa-fake-http
  (export
    (start 1)
    (start-delayed 2)
    (url 1)
    (requests 1)
    (stop 1)))

;;; Offline stand-in for an HTTP backend in tests -- docs/adapters.md
;;; tells new adapters to reuse this rather than pointing tests at real
;;; services. Deliberately tiny: a sequential single-process accept
;;; loop serving one request per connection (always answers
;;; `Connection: close'), just enough HTTP/1.1 framing to satisfy the
;;; stdlib httpc client.
;;;
;;;   (nyaa-fake-http:start handler) -> #(ok ,server-pid)
;;;
;;;     handler := (lambda (method path body-binary) ...)
;;;       -> #(code user-headers iodata-or-binary)  normal response
;;;          #'(#"raw-bytes")                       verbatim bytes, then hard close
;;;          'close                                 close without any bytes
;;;
;;;     user-headers: map or list of atom/binary/string name + value
;;;
;;;   (nyaa-fake-http:url server)      -> "http://127.0.0.1:<port>"
;;;   (nyaa-fake-http:requests server) -> newest-first list of
;;;        #m(method path content-type content-length other-headers body)
;;;   (nyaa-fake-http:stop server)


;;; binary needles/accumulators: these MUST be real binaries -- the
;;; parser rejects charlists here.
(defun b-empty () (binary))
(defun b-crlf () (iolist_to_binary (list 13 10)))
(defun b-crlf-crlf () (iolist_to_binary (list 13 10 13 10)))
(defun b-space () (iolist_to_binary (list 32)))
(defun b-colon () (iolist_to_binary (list 58)))
(defun b-qmark () (iolist_to_binary (list 63)))

(defun start (handler)
  `#(ok ,(spawn_link (lambda () (serve (list handler 0))))))

(defun serve (args)
  (let ((`(,handler ,delay) args))
    (let ((`#(ok ,lsock)
           (gen_tcp:listen 0 '(binary
                               #(packet raw)
                               #(active false)
                               #(reuseaddr true)))))
      (let ((port (fetch-local-port lsock)))
        (loop handler lsock port delay '())))))

(defun start-delayed (handler delay)
  ;;; like start/1, but multi-piece bodies are flushed piece by piece
  ;;; with `delay' ms between pieces -- that is what lets tests observe
  ;;; genuine progressive delivery rather than one buffered blob.
  `#(ok ,(spawn_link (lambda () (serve (list handler delay))))))

(defun fetch-local-port (lsock)
  (case (inet:sockname lsock)
    (`#(ok #(,_addr ,port)) port)
    (`#(error ,_why) 0)))

(defun loop (handler lsock port delay requests)
  (receive
    (`#(call ,from requests)
     (! from `#(reply ,(lists:reverse requests)))
     (loop handler lsock port delay requests))
    (`#(call ,from url)
     (! from `#(reply ,(list->chars (++ "http://127.0.0.1:"
                                        (integer_to_list port)))))
     (loop handler lsock port delay requests))
    (`#(call ,from stop)
     (catch (erlang:close lsock))
     (! from '#(stopped))
     'done)
    (_msg
     (loop handler lsock port delay requests))
    (after 0
           (case (gen_tcp:accept lsock 50)
             (`#(ok ,sock)
              (let ((record (handle-connection handler sock delay)))
                (catch (erlang:close sock))
                (loop handler lsock port delay (cons record requests))))
             ('#(error timeout)
              (loop handler lsock port delay requests))
             ('#(error closed)
              ;; listener torn down under us (stop raced an accept);
              ;; nothing left to do.
              'done)
             (_err
              (loop handler lsock port delay requests))))))

(defun list->chars (iolist)
  (if (is_list iolist) iolist (unicode:characters_to_list iolist 'utf8)))

(defun handle-connection (handler sock delay)
  (let ((request (read-request sock)))
    (let ((answer
            (catch
              (funcall handler
                       (maps:get 'method request)
                       (maps:get 'path request)
                       (maps:get 'body request)))))
      (cond
        ((=:= answer 'close)
         'no-bytes)
        ((is_tuple answer)
         (respond sock answer delay))
        ;; crashed handler: loud 5xx, test still gets its record.
        ('true
         (io:format "~p~n" (list answer))
         (respond sock `#(500 #m() "") delay))))
    request))

(defun respond (sock answer delay)
  ;;; answers are tuples now -- access with element, never car.
  (cond
    ((raw-answer? answer)
     ;; verbatim bytes then a hard drop: models servers that die
     ;; mid-body.
     (send-and-close sock (iolist_to_binary (element 2 answer))))
    ((status-answer? answer)
     (send-status sock (element 1 answer) (element 2 answer)
                  (element 3 answer) delay))
    ('true
     (send-status sock 500 #m() "" delay))))

(defun raw-answer? (a)
  (and (is_tuple a)
       (=:= 2 (erlang:tuple_size a))
       (=:= 'raw (element 1 a))))

(defun status-answer? (a)
  (and (is_tuple a)
       (=:= 3 (erlang:tuple_size a))
       (is_integer (element 1 a))))

(defun send-status (sock code user-headers body delay)
  ;;; headers leave as one frame; body pieces then go out individually,
  ;;; `delay' ms apart when the server was started with pacing -- that
  ;;; is what makes progressive delivery observable to clients.
  (let* ((pieces (pieces-of body))
         (total (iolist_to_binary pieces))
         (head-frame
           (iolist_to_binary
             (list "HTTP/1.1 "
                   (integer_to_list code)
                   " Reason\r\n"
                   (header-lines user-headers)
                   "Content-Length: "
                   (integer_to_list (erlang:byte_size total))
                   "\r\nConnection: close\r\n\r\n"))))
    (catch (gen_tcp:send sock head-frame))
    (send-pieces sock pieces delay)
    ;; kernel flush beat so late bytes are not lost on hard close.
    (timer:sleep 20)
    (catch (gen_tcp:shutdown sock 'write))
    'sent))

(defun send-pieces (sock pieces delay)
  (if (=:= pieces '())
    'done
    (let ((piece (car pieces))
          (rest (cdr pieces)))
      (catch (gen_tcp:send sock (iolist_to_binary (list piece))))
      (if (> delay 0)
        (timer:sleep delay)
        'nowait)
      (send-pieces sock rest delay))))

(defun pieces-of (body)
  (cond
    ((is_list body)
     ;; charlists arrive nested; normalize conservatively.
     (map-to-binaries body))
    ('true
     (list body))))

(defun map-to-binaries (pieces)
  (lists:map
    (lambda (p) (iolist_to_binary (list p)))
    pieces))


(defun header-lines (user-headers)
  (lists:append
    (lists:map
      (lambda (pair)
        ;;; maps:to_list emits {K,V} tuples -- element, not car.
        (list (to-chars (element 1 pair)) ": "
              (to-chars (element 2 pair)) "\r\n"))
      (pairs-of user-headers))))

(defun pairs-of (user-headers)
  (cond
    ((=:= user-headers #m()) '())
    ((is_map user-headers) (maps:to_list user-headers))
    ((is_list user-headers) user-headers)
    ('true '())))

(defun cadr (pair)
  (car (cdr pair)))

(defun caddr (trip)
  (car (cdr (cdr trip))))

(defun to-chars (v)
  (cond
    ((is_atom v) (atom_to_list v))
    ((is_binary v) (unicode:characters_to_list v 'utf8))
    ((is_list v) v)
    ('true (integer_to_list 0))))

;;; --- request reading -----------------------------------------------------

(defun read-request (sock)
  (let ((head-data (recv-until sock (b-crlf-crlf) (b-empty))))
    (let ((parts (binary:split head-data (b-crlf-crlf))))
      (let ((head (car parts))
            (rest (if (=:= (length parts) 2)
                      (cadr parts)
                      "")))
        (finish-request sock (parse-head head) rest)))))

(defun finish-request (sock head buffered)
  (let* ((want (or-zero (maps:get 'content-length head)))
         (have (erlang:byte_size buffered))
         (remaining (max 0 (- want have)))
         (body (if (=:= remaining 0)
                   buffered
                   (iolist_to_binary
                     (list buffered (gen_tcp:recv sock remaining 5000))))))
    (maps:put 'body body head)))

(defun parse-head (head-bin)
  (let ((lines (binary:split head-bin (b-crlf) (list 'global))))
    (lists:foldl
      (lambda (line acc)
        (case (binary:split line (b-colon))
          ('nomatch acc)
          (split-pair
           (store-header
             (string:lowercase (car split-pair))
             (string:trim (cadr split-pair))
             acc))))
      (parse-request-line (car lines))
      (cdr lines))))

(defun parse-request-line (first-line)
  (let ((parts (binary:split first-line (b-space) (list 'global))))
    (let ((method (string:uppercase (car parts)))
          (path-with-query (cadr parts)))
      (let ((path (car (binary:split path-with-query (b-qmark)))))
        ;;; pairs must be TUPLES built as templates: a bare #(k ,v)
        ;;; here is *data* with literal comma-junk -- the documented
        ;; LFE trap.
        (maps:from_list
          (list
            `#(method ,method)
            `#(path ,path)))))))

(defun store-header (key value acc)
  (cond
    ((=:= key #"content-length")
     (store-content-length value acc))
    ((=:= key #"content-type")
     (maps:put 'content-type value acc))
    ('true
     (maps:put 'other-headers
               (cons (list key value) (or-other acc))
               acc))))

(defun store-content-length (value acc)
  ;;; header values arrive as binaries after parse-head normalization;
  ;;; tolerate junk by silently defaulting to no-body framing.
  (let* ((chars (unicode:characters_to_list value 'utf8))
         (maybe-int
           (catch
             (list_to_integer chars))))
    (if (is_integer maybe-int)
      (maps:put 'content-length maybe-int acc)
      acc)))

(defun or-other (acc)
  (case (maps:find 'other-headers acc)
    (`#(ok ,others) others)
    ('error '())))

(defun recv-until (sock needle acc)
  (case (binary:match acc needle)
    ('nomatch
     (case (gen_tcp:recv sock 0 5000)
       (`#(ok ,data)
        (recv-until sock needle
                    (iolist_to_binary (list acc data))))
       (other acc)))
    (_ acc)))

;;; --- client-facing api ----------------------------------------------------

(defun or-zero (v)
  (if (is_integer v) v 0))

(defun send-and-close (sock bytes)
  (catch (gen_tcp:send sock bytes))
  ;; give the kernel a beat to flush before the hard close, so tests
  ;; are not flaky about whether the client saw every byte.
  (timer:sleep 20)
  (catch (gen_tcp:shutdown sock 'write))
  'sent)

(defun url (server)
  (call-server server 'url))

(defun requests (server)
  (call-server server 'requests))

(defun stop (server)
  (let ((me (self)))
    (! server `#(call ,me stop))
    (receive
      ('#(stopped) 'ok)
      (after 1000 'timeout))))

(defun call-server (server kind)
  (let ((me (self)))
    (! server `#(call ,me ,kind))
    (receive
      (`#(reply ,value) value)
      (after 2000 '#(error fake-server-unresponsive)))))
