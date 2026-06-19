;;; compare-nelix-json.el --- Compare Nelix runtime JSON summaries -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Batch helper used by packaging gates.  It compares selected user-visible
;; result rows between Emacs runtime JSON and the NeLisp AOT fast lane while
;; tolerating representation differences such as null versus [].

;;; Code:

(require 'json)
(require 'cl-lib)

(defun nelix-json-compare--read (file)
  "Read JSON object FILE as an alist."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (json-parse-buffer :object-type 'alist
                       :array-type 'list
                       :null-object nil
                       :false-object nil)))

(defun nelix-json-compare--field (object path)
  "Return nested value from OBJECT at PATH."
  (let ((value object))
    (dolist (key path value)
      (setq value
            (and (listp value)
                 (alist-get key value nil nil #'equal))))))

(defun nelix-json-compare--as-list (value)
  "Return VALUE as a list, treating nil as an empty list."
  (cond
   ((null value) nil)
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t (list value))))

(defun nelix-json-compare--row-name (row)
  "Return comparable name for ROW."
  (cond
   ((stringp row) row)
   ((listp row)
    (or (alist-get 'name row nil nil #'equal)
        (alist-get "name" row nil nil #'equal)
        (alist-get 'target row nil nil #'equal)
        (alist-get "target" row nil nil #'equal)
        (prin1-to-string row)))
   (t (format "%s" row))))

(defun nelix-json-compare--names (object path)
  "Return sorted names from OBJECT at PATH."
  (sort (mapcar #'nelix-json-compare--row-name
                (nelix-json-compare--as-list
                 (nelix-json-compare--field object path)))
        #'string<))

(defun nelix-json-compare--command-key (row)
  "Return order-sensitive command identity for ROW."
  (cond
   ((listp row)
    (let ((action (or (alist-get 'action row nil nil #'equal)
                      (alist-get "action" row nil nil #'equal)))
          (name (or (alist-get 'name row nil nil #'equal)
                    (alist-get "name" row nil nil #'equal)))
          (target (or (alist-get 'target row nil nil #'equal)
                      (alist-get "target" row nil nil #'equal))))
      (format "%s:%s:%s"
              (or action "")
              (or name "")
              (or target ""))))
   (t (format "%s" row))))

(defun nelix-json-compare--commands (object path)
  "Return order-sensitive command identities from OBJECT at PATH."
  (mapcar #'nelix-json-compare--command-key
          (nelix-json-compare--as-list
           (nelix-json-compare--field object path))))

(defun nelix-json-compare--fail (label path left right)
  "Signal comparison failure for LABEL PATH LEFT RIGHT."
  (error "%s mismatch at %s: emacs=%S nelisp=%S"
         label
         (mapconcat (lambda (key) (format "%s" key)) path ".")
         left
         right))

(defun nelix-json-compare--field= (label emacs nelisp path)
  "Assert comparable PATH is equal between EMACS and NELISP."
  (let ((left (if (equal path '(commands))
                  (nelix-json-compare--commands emacs path)
                (nelix-json-compare--names emacs path)))
        (right (if (equal path '(commands))
                   (nelix-json-compare--commands nelisp path)
                 (nelix-json-compare--names nelisp path))))
    (unless (equal left right)
      (nelix-json-compare--fail label path left right))))

(defun nelix-json-compare-files (label emacs-json nelisp-json paths)
  "Compare selected PATHS in EMACS-JSON and NELISP-JSON."
  (let ((emacs (nelix-json-compare--read emacs-json))
        (nelisp (nelix-json-compare--read nelisp-json)))
    (dolist (path paths)
      (nelix-json-compare--field= label emacs nelisp path))
    (princ (format "nelix json compare ok: %s\n" label))))

(defun nelix-json-compare-main ()
  "Run the command-line JSON comparison helper."
  (let* ((args (if (equal (car command-line-args-left) "--")
                   (cdr command-line-args-left)
                 command-line-args-left))
         (label (pop args))
         (emacs-json (pop args))
         (nelisp-json (pop args))
         paths)
    (unless (and label emacs-json nelisp-json args)
      (error "usage: compare-nelix-json.el LABEL EMACS.json NELISP.json PATH..."))
    (dolist (arg args)
      (push (mapcar #'intern (split-string arg "\\." t)) paths))
    (nelix-json-compare-files label emacs-json nelisp-json (nreverse paths))))

(when noninteractive
  (nelix-json-compare-main))

;;; compare-nelix-json.el ends here
