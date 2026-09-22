(in-package #:nyaa)

#+sbcl (eval-when (:compile-toplevel :load-toplevel :execute) (require :sb-posix))

;;; Portable primitives for tool-fs's atomic sandbox walk (~takeiteasy/nyaa#52,
;;; #53). Each path component is opened with O_NOFOLLOW -- refusing a
;;; symlink outright rather than resolving it -- and FCHDIR steps the
;;; process into it. The final component is then operated on relative to
;;; that directory, so the check that it is not a symlink and the operation
;;; itself share one file descriptor and cannot be swapped apart.
;;;
;;; Implemented for SBCL (via sb-posix), ECL (via FFI:C-INLINE, so the
;;; embedded C compiler resolves every constant) and CCL (via EXTERNAL-CALL
;;; against hand-carried constants, since CCL has no C compiler at runtime
;;; to ask). On any other implementation FS-* returns :UNAVAILABLE rather
;;; than fall back to a path re-check a symlink could race.
;;;
;;; TODO: the process's current directory is one global resource, and every
;;; step of the walk mutates it under *FS-LOCK* -- which serialises tool-fs
;;; against itself, but not against any other code in the process that
;;; reads or sets the cwd without taking this lock. Upgrade path: openat(2)
;;; and friends against a held directory fd, once all three implementations
;;; expose them (or carrying a small FFI shim for them is worth it).
;;; Tracked in ~takeiteasy/nyaa#59.

(defvar *fs-lock* (bt:make-lock :name "nyaa-fs-walk")
  "Serialises tool-fs's directory walk, which works by changing the
process's current directory. See the TODO above FS-WALK.")

#+ecl
(ffi:clines "
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
")

;;; --- errno, normalised to keywords -----------------------------------

#+ccl
(defparameter *ccl-errno-table*
  (cond ((member :darwin *features*)
         '((1 . :eperm) (2 . :enoent) (17 . :eexist) (20 . :enotdir)
           (21 . :eisdir) (22 . :einval) (62 . :eloop)))
        ((member :linux *features*)
         '((1 . :eperm) (2 . :enoent) (17 . :eexist) (20 . :enotdir)
           (21 . :eisdir) (22 . :einval) (40 . :eloop)))
        (t (error "nyaa: no errno table for ~a; tool-fs needs one for CCL on this OS."
                  (lisp-implementation-type))))
  "CCL has no portable errno-to-condition mapping (no C compiler to ask at
runtime), so the numbers are carried by hand. EPERM, ENOENT, EEXIST,
ENOTDIR, EISDIR and EINVAL are the same on Darwin and Linux; only ELOOP
differs.")

#+ccl
(defun ccl-errno-keyword (errno)
  "ERRNO must be read by the caller with CCL:GET-ERRNO in the same LET* as
the failing EXTERNAL-CALL, immediately after it and before any other
call (an IF test, a ZEROP) -- errno read even one call later can already
be a different value."
  (or (cdr (assoc errno *ccl-errno-table*)) :other))

#+ccl
(defparameter *ccl-o-flags*
  (cond ((member :darwin *features*)
         '(:rdonly 0 :wronly 1 :creat 512 :trunc 1024 :directory 1048576 :nofollow 256))
        ((member :linux *features*)
         '(:rdonly 0 :wronly 1 :creat 64 :trunc 512 :directory 65536 :nofollow 131072))
        (t (error "nyaa: no O_* flag table for CCL on ~a." (lisp-implementation-type))))
  "open(2) flag values, since CCL cannot grovel <fcntl.h> at runtime. Stable
ABI constants on both Darwin and Linux.")

#+ccl
(defun ccl-o-flag (name) (getf *ccl-o-flags* name))

#+sbcl
(defun sb-posix-errno-keyword (condition)
  (let ((errno (sb-posix:syscall-errno condition)))
    (cond ((= errno sb-posix:enoent) :enoent)
          ((= errno sb-posix:eexist) :eexist)
          ((= errno sb-posix:enotdir) :enotdir)
          ((= errno sb-posix:eisdir) :eisdir)
          ((= errno sb-posix:eperm) :eperm)
          ((= errno sb-posix:eloop) :eloop)
          (t :other))))

;; C-INLINE only runs under the compiler, not the interpreter, so each
;; constant needs its own compiled function rather than a read-time #. --
;; ECL's compile-file pass would otherwise try to interpret it directly.
#+ecl (defun ecl-c-enoent () (ffi:c-inline () () :int "ENOENT" :one-liner t))
#+ecl (defun ecl-c-eexist () (ffi:c-inline () () :int "EEXIST" :one-liner t))
#+ecl (defun ecl-c-enotdir () (ffi:c-inline () () :int "ENOTDIR" :one-liner t))
#+ecl (defun ecl-c-eisdir () (ffi:c-inline () () :int "EISDIR" :one-liner t))
#+ecl (defun ecl-c-eperm () (ffi:c-inline () () :int "EPERM" :one-liner t))
#+ecl (defun ecl-c-eloop () (ffi:c-inline () () :int "ELOOP" :one-liner t))

#+ecl
(defun ecl-errno-keyword (errno)
  (cond ((= errno (ecl-c-enoent)) :enoent)
        ((= errno (ecl-c-eexist)) :eexist)
        ((= errno (ecl-c-enotdir)) :enotdir)
        ((= errno (ecl-c-eisdir)) :eisdir)
        ((= errno (ecl-c-eperm)) :eperm)
        ((= errno (ecl-c-eloop)) :eloop)
        (t :other)))

;;; --- open a directory component, O_NOFOLLOW ---------------------------
;;; Returns an implementation-specific fd/handle, or (values nil errno-kw).

(defun fs-open-dir-component (name)
  #+sbcl
  (handler-case (values (sb-posix:open name (logior sb-posix:o-directory
                                                     sb-posix:o-nofollow))
                        nil)
    (sb-posix:syscall-error (e) (values nil (sb-posix-errno-keyword e))))
  #+ecl
  (multiple-value-bind (fd errno)
      (ffi:c-inline (name) (:cstring) (values :int :int)
       "{ int fd = open(#0, O_DIRECTORY | O_NOFOLLOW);
          @(return 0) = fd; @(return 1) = (fd < 0) ? errno : 0; }"
       :one-liner nil)
    (if (>= fd 0) (values fd nil) (values nil (ecl-errno-keyword errno))))
  #+ccl
  (ccl:with-cstrs ((p name))
    (ccl:without-interrupts
      (let* ((fd (ccl:external-call "open" :address p :int
                                    (logior (ccl-o-flag :directory) (ccl-o-flag :nofollow))
                                    :int 0 :int))
             (errno (ccl:get-errno)))
        (if (>= fd 0) (values fd nil) (values nil (ccl-errno-keyword errno))))))
  #-(or sbcl ecl ccl) (values nil :unavailable))

(defun fs-fchdir (fd)
  #+sbcl (handler-case (progn (sb-posix:fchdir fd) t)
           (sb-posix:syscall-error () nil))
  #+ecl (zerop (ffi:c-inline (fd) (:int) :int "fchdir(#0)" :one-liner t))
  #+ccl (zerop (ccl:external-call "fchdir" :int fd :int))
  #-(or sbcl ecl ccl) nil)

(defun fs-close (fd)
  #+sbcl (ignore-errors (sb-posix:close fd))
  #+ecl (ffi:c-inline (fd) (:int) :void "close(#0)" :one-liner t)
  #+ccl (ccl:external-call "close" :int fd :int)
  #-(or sbcl ecl ccl) nil)

;;; --- the leaf: open, mkdir, unlink, readlink, list --------------------

(defun fs-open-leaf (name flags mode)
  "NAME under the current directory, opened with FLAGS (a list of :RDONLY
:WRONLY :CREAT :TRUNC), always with O_NOFOLLOW added. Returns an fd, or
(values nil errno-keyword)."
  #+sbcl
  (handler-case
      (values (sb-posix:open name
                             (logior sb-posix:o-nofollow
                                     (if (member :wronly flags) sb-posix:o-wronly sb-posix:o-rdonly)
                                     (if (member :creat flags) sb-posix:o-creat 0)
                                     (if (member :trunc flags) sb-posix:o-trunc 0))
                             mode)
              nil)
    (sb-posix:syscall-error (e) (values nil (sb-posix-errno-keyword e))))
  #+ecl
  (multiple-value-bind (fd errno)
      (ffi:c-inline (name (if (member :wronly flags) 1 0)
                          (if (member :creat flags) 1 0)
                          (if (member :trunc flags) 1 0) mode)
          (:cstring :int :int :int :int) (values :int :int)
       "{ int f = O_NOFOLLOW | (#1 ? O_WRONLY : O_RDONLY);
          if (#2) f |= O_CREAT;
          if (#3) f |= O_TRUNC;
          int fd = open(#0, f, #4);
          @(return 0) = fd; @(return 1) = (fd < 0) ? errno : 0; }"
       :one-liner nil)
    (if (>= fd 0) (values fd nil) (values nil (ecl-errno-keyword errno))))
  #+ccl
  (ccl:with-cstrs ((p name))
    (ccl:without-interrupts
      (let* ((fd (ccl:external-call
                  "open" :address p :int
                  (logior (ccl-o-flag :nofollow)
                         (if (member :wronly flags) (ccl-o-flag :wronly) (ccl-o-flag :rdonly))
                         (if (member :creat flags) (ccl-o-flag :creat) 0)
                         (if (member :trunc flags) (ccl-o-flag :trunc) 0))
                  :int mode :int))
             (errno (ccl:get-errno)))
        (cond ((< fd 0) (values nil (ccl-errno-keyword errno)))
              ;; open(2)'s MODE argument is variadic (present only with
              ;; O_CREAT), and Apple's arm64 ABI passes variadic arguments on
              ;; the stack where fixed ones go in registers -- a mismatch
              ;; EXTERNAL-CALL has no way to know about, so the file can come
              ;; out with garbage permission bits. FCHMOD's arguments are
              ;; both fixed, so it sets them reliably after the fact.
              ((member :creat flags) (ccl:external-call "fchmod" :int fd :int mode :int) (values fd nil))
              (t (values fd nil))))))
  #-(or sbcl ecl ccl) (values nil :unavailable))

(defun fs-mkdir-leaf (name mode)
  "T on success, (values nil :eexist) if it is already there, or another
errno keyword."
  #+sbcl (handler-case (progn (sb-posix:mkdir name mode) t)
           (sb-posix:syscall-error (e) (values nil (sb-posix-errno-keyword e))))
  #+ecl (multiple-value-bind (rc errno)
            (ffi:c-inline (name mode) (:cstring :int) (values :int :int)
             "{ int rc = mkdir(#0, #1); @(return 0) = rc; @(return 1) = rc ? errno : 0; }"
             :one-liner nil)
          (if (zerop rc) t (values nil (ecl-errno-keyword errno))))
  #+ccl (ccl:with-cstrs ((p name))
          (ccl:without-interrupts
            (let* ((rc (ccl:external-call "mkdir" :address p :int mode :int))
                   (errno (ccl:get-errno)))
              (if (zerop rc) t (values nil (ccl-errno-keyword errno))))))
  #-(or sbcl ecl ccl) (values nil :unavailable))

(defun fs-unlink-leaf (name)
  #+sbcl (handler-case (progn (sb-posix:unlink name) t)
           (sb-posix:syscall-error (e) (values nil (sb-posix-errno-keyword e))))
  #+ecl (multiple-value-bind (rc errno)
            (ffi:c-inline (name) (:cstring) (values :int :int)
             "{ int rc = unlink(#0); @(return 0) = rc; @(return 1) = rc ? errno : 0; }"
             :one-liner nil)
          (if (zerop rc) t (values nil (ecl-errno-keyword errno))))
  #+ccl (ccl:with-cstrs ((p name))
          (ccl:without-interrupts
            (let* ((rc (ccl:external-call "unlink" :address p :int))
                   (errno (ccl:get-errno)))
              (if (zerop rc) t (values nil (ccl-errno-keyword errno))))))
  #-(or sbcl ecl ccl) (values nil :unavailable))

(defun fs-symlink-leaf-p (name)
  "True when NAME (relative to the current directory) is itself a symlink,
dangling or not. READLINK fails with EINVAL on anything else, which is
enough to tell the two apart without a full STAT."
  #+sbcl (and (ignore-errors (sb-posix:readlink name)) t)
  #+ecl (>= (ffi:c-inline (name) (:cstring) :int
             "{ char b[4]; @(return) = readlink(#0, b, sizeof(b)); }"
             :one-liner nil)
            0)
  #+ccl (ccl:with-cstrs ((p name))
          (ccl:%stack-block ((buf 4))
            (>= (ccl:external-call "readlink" :address p :address buf
                                   :unsigned-long 4 :int)
                0)))
  #-(or sbcl ecl ccl) nil)

(defun fs-list-names ()
  "Every entry of the current directory, sorted. Listing is not part of the
O_NOFOLLOW walk above -- by the time this runs, FS-WALK has already
positioned the process inside a directory it verified was not a symlink,
so an ordinary (and portable) directory listing is safe here.

UIOP:DIRECTORY-FILES and UIOP:SUBDIRECTORIES merge \".\" against
*DEFAULT-PATHNAME-DEFAULTS*, a Lisp-level variable FCHDIR does not touch --
not against the OS's own idea of the current directory -- so the walk's
FCHDIR is invisible to them unless the directory is named explicitly.
UIOP:GETCWD does call GETCWD(2), so it is used here instead of \".\".

This does mean :LIST re-resolves a path by name rather than reading the fd
FS-WALK already validated -- a narrower race than the one #52 closed for
the other ops, since all it can do is list the wrong directory's names,
never open, write or delete outside the root. Covered by the same TODO
above."
  (let ((here (uiop:getcwd)))
    (sort (append (mapcar #'fs-entry-name (uiop:subdirectories here))
                 (mapcar #'fs-entry-name (uiop:directory-files here)))
          #'string<)))

(defun fs-entry-name (pathname)
  (if (uiop:directory-pathname-p pathname)
      (car (last (pathname-directory pathname)))
      (file-namestring pathname)))

;;; --- the walk ----------------------------------------------------------

(defun fs-walk (root components &key create)
  "Change the current directory to ROOT, then step into each of COMPONENTS
in turn -- each one opened with O_NOFOLLOW before FCHDIR steps into it, so
a symlink anywhere along the way is refused rather than followed. Returns
T once positioned in the last component's directory, or (values nil
errno-keyword) at the component that failed.

CREATE makes a missing component with MKDIR first and retries the open --
still through O_NOFOLLOW, so a symlink swapped in between the two is
refused exactly as an existing one would be, rather than trusted because
this walk just created it."
  (multiple-value-bind (root-fd errno) (fs-open-dir-component root)
    (unless root-fd (return-from fs-walk (values nil errno)))
    (unless (fs-fchdir root-fd)
      (fs-close root-fd)
      (return-from fs-walk (values nil :other)))
    (fs-close root-fd)
    (dolist (component components t)
      (multiple-value-bind (fd errno) (fs-open-dir-component component)
        (when (and (not fd) create (eq errno :enoent))
          (fs-mkdir-leaf component #o755)
          (setf (values fd errno) (fs-open-dir-component component)))
        (unless fd (return-from fs-walk (values nil errno)))
        (let ((ok (fs-fchdir fd)))
          (fs-close fd)
          (unless ok (return-from fs-walk (values nil :other))))))))

(defmacro with-fs-cwd-saved (&body body)
  "Save and restore the process's current directory around BODY, so
tool-fs's walk never leaves the process pointed somewhere else -- even
though nothing but *FS-LOCK* stops another thread from observing it
mid-walk (see the TODO above)."
  (let ((saved (gensym)))
    `(let ((,saved (fs-open-dir-component ".")))
       (unwind-protect (progn ,@body)
         (when ,saved (fs-fchdir ,saved) (fs-close ,saved))))))
