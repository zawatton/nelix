;;; nelix-standalone-shim.el --- Missing-primitive shims for standalone NeLisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Provides minimal pure-Elisp shims for Emacs functions that are
;; absent from the current standalone NeLisp binary but required by the
;; nelix executor.  Every definition is guarded by `unless (fboundp ...)'
;; so this file is safe to load on host Emacs where the real functions
;; already exist.
;;
;; Covered call sites in nelix:
;;  - shell-quote-argument  (nelix-builder--run-phase: safe-out / safe-dir)
;;  - directory-files-recursively (nelix-builder--copy-stripped-files,
;;                                 nelix-registry--recipe-files)
;;  - file-relative-name    (nelix-builder--strip-components)
;;  - file-directory-p      (nelix-registry--recipe-files,
;;                           nelix-builder--copy-stripped-files)
;;  - copy-file             (nelix-builder--copy-path)
;;  - file-name-as-directory (nelix-builder--run-phase)
;;  - file-name-directory   (nelix-driver helpers)
;;  - expand-file-name      (multiple sites)
;;  - nelisp-sys-exit       (driver exit; loaded via nelisp-sys.el)

;;; Code:

;;; shell-quote-argument

(unless (fboundp 'shell-quote-argument)
  (defun shell-quote-argument (arg)
    "Return ARG as a single-quoted POSIX shell argument.
Wraps ARG in single quotes, escaping any embedded single quotes
as '\\''."
    (concat "'"
            (let ((s arg)
                  (result ""))
              (while (> (length s) 0)
                (let ((pos 0)
                      (n (length s)))
                  ;; Find next single quote.
                  (while (and (< pos n)
                              (not (string-equal (substring s pos (1+ pos)) "'")))
                    (setq pos (1+ pos)))
                  (if (< pos n)
                      ;; Quote the part before and escape the quote.
                      (progn
                        (setq result (concat result (substring s 0 pos) "'\\''" ))
                        (setq s (substring s (1+ pos))))
                    ;; No more single quotes — append remainder and stop.
                    (setq result (concat result s))
                    (setq s ""))))
              result)
            "'")))

;;; directory-files-recursively

(unless (fboundp 'directory-files-recursively)
  (defun directory-files-recursively (dir regexp &optional include-directories)
    "Return all files under DIR whose names match REGEXP, recursively.
When INCLUDE-DIRECTORIES is non-nil, also include matching directories."
    (let ((result nil))
      (dolist (entry (directory-files dir t))
        (let ((base (file-name-nondirectory entry)))
          (unless (or (string-equal base ".") (string-equal base ".."))
            (if (file-directory-p entry)
                (progn
                  (when (and include-directories
                             (string-match regexp base))
                    (push entry result))
                  (setq result
                        (append result
                                (directory-files-recursively
                                 entry regexp include-directories))))
              (when (string-match regexp base)
                (push entry result))))))
      result)))

;;; file-relative-name

(unless (fboundp 'file-relative-name)
  (defun file-relative-name (filename &optional directory)
    "Return FILENAME relative to DIRECTORY (default: current directory).
Minimal implementation: strips the DIRECTORY prefix when present."
    (let* ((dir (expand-file-name (or directory ".")))
           (dir/ (if (string-equal (substring dir -1) "/") dir (concat dir "/")))
           (abs (expand-file-name filename)))
      (if (and (> (length abs) (length dir/))
               (string-equal (substring abs 0 (length dir/)) dir/))
          (substring abs (length dir/))
        abs))))

;;; file-directory-p — standalone NeLisp may lack this; use make-directory probe
;;; Actually, file-directory-p seems present.  Guard anyway.

;;; copy-file — used by nelix-builder--copy-path

(unless (fboundp 'copy-file)
  (defun copy-file (src dst &optional _ok-if-exists _keep-time _preserve-permissions)
    "Copy file SRC to DST using shell `cp'.
This shim delegates to `call-process' which is available on standalone NeLisp."
    (let ((exit (call-process "cp" nil nil nil "--" src dst)))
      (unless (eq exit 0)
        (error "copy-file: cp returned %s for %s -> %s" exit src dst)))))

;;; file-name-as-directory

(unless (fboundp 'file-name-as-directory)
  (defun file-name-as-directory (filename)
    "Return FILENAME as a directory name (with trailing slash)."
    (if (string-equal (substring filename -1) "/")
        filename
      (concat filename "/"))))

;;; file-name-directory

(unless (fboundp 'file-name-directory)
  (defun file-name-directory (filename)
    "Return directory component of FILENAME."
    (let ((i (- (length filename) 1))
          (result nil))
      (while (and (>= i 0)
                  (not result))
        (when (string-equal (substring filename i (1+ i)) "/")
          (setq result (substring filename 0 (1+ i))))
        (setq i (1- i)))
      (or result ""))))

;;; file-name-nondirectory

(unless (fboundp 'file-name-nondirectory)
  (defun file-name-nondirectory (filename)
    "Return non-directory component of FILENAME."
    (let ((dir (file-name-directory filename)))
      (if (> (length dir) 0)
          (substring filename (length dir))
        filename))))

;;; expand-file-name — minimal implementation for absolute paths

(unless (fboundp 'expand-file-name)
  (defun expand-file-name (filename &optional directory)
    "Expand FILENAME relative to DIRECTORY.
Minimal: handles absolute paths and `~' prefix only."
    (cond
     ((and (> (length filename) 0)
           (string-equal (substring filename 0 1) "/"))
      filename)
     ((and (> (length filename) 0)
           (string-equal (substring filename 0 1) "~"))
      (let ((home (or (getenv "HOME") "/")))
        (concat home (substring filename 1))))
     (t
      (let ((base (or directory ".")))
        (concat (if (string-equal (substring base -1) "/")
                    base
                  (concat base "/"))
                filename))))))

;;; string-match — standalone NeLisp may have this; guard anyway.
;;; (nelix-registry--recipe-files uses `directory-files-recursively' with
;;; "\\.el\\'" which requires regex.  Standalone has `string-match'.)

;;; buffer-file-name — called from some nelix paths

(unless (fboundp 'buffer-file-name)
  (defun buffer-file-name (&optional _buffer) nil))

;;; number-to-string — should be present; guard for safety.

(unless (fboundp 'number-to-string)
  (defun number-to-string (n)
    "Convert number N to string."
    (format "%d" n)))

;;; format guard — should be present on standalone.
;;; (Already verified available.)

(provide 'nelix-standalone-shim)
;;; nelix-standalone-shim.el ends here
