(defmodule nyaa-tool-fs
  (export
    (child_spec 1)
    (service_name 0)
    (dependencies 0)
    (metadata 0)
    (init 1)
    (handle_message 2)
    (terminate 2)))

;;; Standard tool plugin: filesystem, sandboxed to a root directory
;;; given at mount time. Supported ops: read, write, list, mkdir,
;;; delete -- all with paths resolved inside the sandbox; anything that
;;; escapes it (../ tricks, absolute paths outside the root) is rejected.
;;; Part of the tool/skill convention (see docs/tools.md): registers as
;;; 'tool-fs, answers #(describe) and #(invoke ...).
;;;
;;; Known limitation: a symlink inside the sandbox pointing out of it is
;;; followed by the OS -- this sandbox is path-based only. Trusted
;;; operator posture (docs/getting-started.md "Security & trust"); a
;;; symlink-hardened sandbox would be an improvement ticket if this tool
;;; ever faces untrusted input.

(defun child_spec (root)
  `#m(id tool-fs
      start #(patchbay_service start_link (nyaa-tool-fs ,root))
      restart transient
      shutdown 5000
      type worker
      modules (patchbay_service)))

(defun service_name () 'tool-fs)
(defun dependencies () '())

(defun metadata ()
  ;;; Published as registration props (patchbay_service metadata/0);
  ;;; this is what makes the tool discoverable via kind=tool.
  (describe))

(defun init (root)
  ;; normalize once: no trailing slash, so under-root's boundary check
  ;; below stays simple
  `#(ok #m(root ,(string:trim (filename:absname root) 'trailing "/"))))

(defun describe ()
  #m(kind tool
     name 'tool-fs
     summary #"Read/write/list/delete files inside the sandboxed root"
     params #m(op "read | write | list | mkdir | delete"
               path "path relative to the sandbox root, binary"
               data "file contents for write, binary")))

(defun handle_message
  (('describe state) `#(reply ,(describe) ,state))
  ((`#(invoke ,req) state)
   `#(reply ,(dispatch req state) ,state)))

(defun terminate (_reason _state) 'ok)

;;; --- implementation -------------------------------------------------

(defun dispatch (req state)
  (let ((root (maps:get 'root state))
        (op (maps:get 'op req 'undefined)))
    (case (maps:find 'path req)
      (`#(ok ,path) (when (orelse (is_binary path) (is_list path)))
       (let ((path-ls (normalize-abs
                       (filename:absname (arg->list path) root))))
         ;; normalize collapses ".." segments lexically, so a leading
         ;; "../" lands outside the root and under-root rejects it --
         ;; without this the raw "root/../x" string would prefix-match.
         (if (under-root root path-ls)
           (apply-op op path-ls req)
           '#(error #(forbidden "path escapes sandbox root")))))
      (_ '#(error #(bad_request "path required, string or binary"))))))

;; LFE string literals are char lists; model-supplied args may well be
;; binaries. Accept both everywhere.
(defun acceptable-string (v)
  (orelse (is_list v) (is_binary v)))

(defun arg->list (v)
  (if (is_binary v) (binary_to_list v) v))

;; Lexical normalization of an absolute path: collapse "." and ".."
;; segments without touching the filesystem. (This OTP has no
;; file:normalize; and even where one exists it is symlink-aware in ways
;; a pure path sandbox must not depend on.) "../" escapes therefore land
;; outside the root and under-root rejects them -- the raw un-normalized
;; string would prefix-match.
(defun normalize-abs (path)
  (let ((segs
          (lists:foldl
            (lambda (seg acc)
              (cond
                ((=:= seg ".") acc)
                ((=:= seg "..") (tl acc))  ; pop; at root, tl([]) is []
                ('true (cons seg acc))))
            '()
            (string:split path "/" 'all))))
    (string:join (lists:reverse segs) "/")))

;; True when abs is the root itself or lives strictly beneath it. A bare
;; string prefix is not enough -- it would admit siblings like
;; "/sandbox-root-evil".
(defun under-root (root abs)
  (let ((n (string:length root))
        (m (string:length abs)))
    (andalso (>= m n)
             (=:= (string:slice abs 0 n) root)
             (orelse (=:= m n)
                     (=:= (string:slice abs n 1) "/")))))

(defun apply-op
  (('read path _req)
   (case (file:read_file path)
     (`#(ok ,bin) `#(ok #m(data ,bin)))
     (`#(error ,r) `#(error ,r))))
  (('write path req)
   (case (maps:find 'data req)
     (`#(ok ,data) (when (orelse (is_binary data) (is_list data)))
      (case (ensure_dirname path)
        ('ok (case (file:write_file path data)
               ('ok 'ok)
               (`#(error ,r) `#(error ,r))))
        (`#(error ,r) `#(error ,r))))
     (_ '#(error #(bad_request "data must be a string or binary")))))
  (('list path _req)
   (case (file:list_dir path)
     (`#(ok ,names) `#(ok #m(files ,(lists:sort names))))
     (`#(error ,r) `#(error ,r))))
  (('mkdir path _req)
   (case (filelib:ensure_path path)
     ('ok 'ok)
     (`#(error ,r) `#(error ,r))))
  (('delete path _req)
   ;; file:delete refuses directories; recursive delete is deliberately
   ;; not offered -- a tool this easy to call should not be able to rm -rf.
   (case (file:delete path)
     ('ok 'ok)
     (`#(error ,r) `#(error ,r))))
  ((_op _path _req)
   '#(error #(bad_request "op must be read|write|list|mkdir|delete"))))

(defun ensure_dirname (path)
  (let ((dir (filename:dirname path)))
    (if (=:= dir ".")
      'ok
      (filelib:ensure_path dir))))
