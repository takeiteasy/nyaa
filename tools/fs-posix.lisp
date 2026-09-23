(in-package #:nyaa)

(eval-when (:compile-toplevel :load-toplevel :execute) (require :sb-posix))

;;; Primitives for tool-fs's atomic sandbox walk (~takeiteasy/nyaa#52, #53),
;;; via sb-posix. Each path component is opened with O_NOFOLLOW -- refusing
;;; a symlink outright rather than resolving it -- and FCHDIR steps the
;;; process into it. The final component is then operated on relative to
;;; that directory, so the check that it is not a symlink and the operation
;;; itself share one file descriptor and cannot be swapped apart.
;;;
;;; TODO: the process's current directory is one global resource, and every
;;; step of the walk mutates it under *FS-LOCK* -- which serialises tool-fs
;;; against itself, but not against any other code in the process that
;;; reads or sets the cwd without taking this lock. Upgrade path: openat(2),
;;; mkdirat(2), unlinkat(2) and fdopendir(2)/readdir(2) against a held
;;; directory fd, via sb-alien, once worth the FFI surface. Tracked in
;;; ~takeiteasy/nyaa#59.

(defvar *fs-lock* (bt:make-lock :name "nyaa-fs-walk")
  "Serialises tool-fs's directory walk, which works by changing the
process's current directory. See the TODO above FS-WALK.")

;;; --- errno, normalised to keywords -----------------------------------

(defun sb-posix-errno-keyword (condition)
  (let ((errno (sb-posix:syscall-errno condition)))
    (cond ((= errno sb-posix:enoent) :enoent)
          ((= errno sb-posix:eexist) :eexist)
          ((= errno sb-posix:enotdir) :enotdir)
          ((= errno sb-posix:eisdir) :eisdir)
          ((= errno sb-posix:eperm) :eperm)
          ((= errno sb-posix:eloop) :eloop)
          (t :other))))

;;; --- open a directory component, O_NOFOLLOW ---------------------------
;;; Returns an fd, or (values nil errno-kw).

(defun fs-open-dir-component (name)
  (handler-case (values (sb-posix:open name (logior sb-posix:o-directory
                                                     sb-posix:o-nofollow))
                        nil)
    (sb-posix:syscall-error (e) (values nil (sb-posix-errno-keyword e)))))

(defun fs-fchdir (fd)
  (handler-case (progn (sb-posix:fchdir fd) t)
    (sb-posix:syscall-error () nil)))

(defun fs-close (fd)
  (ignore-errors (sb-posix:close fd)))

;;; --- the leaf: open, mkdir, unlink, readlink, list --------------------

(defun fs-open-leaf (name flags mode)
  "NAME under the current directory, opened with FLAGS (a list of :RDONLY
:WRONLY :CREAT :TRUNC), always with O_NOFOLLOW added. Returns an fd, or
(values nil errno-keyword)."
  (handler-case
      (values (sb-posix:open name
                             (logior sb-posix:o-nofollow
                                     (if (member :wronly flags) sb-posix:o-wronly sb-posix:o-rdonly)
                                     (if (member :creat flags) sb-posix:o-creat 0)
                                     (if (member :trunc flags) sb-posix:o-trunc 0))
                             mode)
              nil)
    (sb-posix:syscall-error (e) (values nil (sb-posix-errno-keyword e)))))

(defun fs-mkdir-leaf (name mode)
  "T on success, (values nil :eexist) if it is already there, or another
errno keyword."
  (handler-case (progn (sb-posix:mkdir name mode) t)
    (sb-posix:syscall-error (e) (values nil (sb-posix-errno-keyword e)))))

(defun fs-unlink-leaf (name)
  (handler-case (progn (sb-posix:unlink name) t)
    (sb-posix:syscall-error (e) (values nil (sb-posix-errno-keyword e)))))

(defun fs-symlink-leaf-p (name)
  "True when NAME (relative to the current directory) is itself a symlink,
dangling or not. READLINK fails with EINVAL on anything else, which is
enough to tell the two apart without a full STAT."
  (and (ignore-errors (sb-posix:readlink name)) t))

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
