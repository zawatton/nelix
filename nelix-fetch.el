;;; nelix-fetch.el --- Hash-verified Nelix native fetchers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Phase N3 fetch primitives.  This module fetches local/file/HTTP/ELPA/Git
;; sources into caller-provided files and verifies SHA-256 before a builder is
;; allowed to insert anything into the native store.  It also hashes and
;; verifies local source trees for copy-style native builders.

;;; Code:

(require 'nelix-core)
(require 'nelix-compat)
(require 'subr-x)

(defgroup nelix-fetch nil
  "Hash-verified Nelix native fetchers."
  :group 'nelix-core
  :prefix "nelix-fetch-")

(defcustom nelix-fetch-timeout-seconds 60
  "Default timeout for HTTP fetches."
  :type 'integer
  :group 'nelix-fetch)

(defcustom nelix-fetch-elpa-archive-urls
  '((gnu . "https://elpa.gnu.org/packages/")
    (gnu-devel . "https://elpa.gnu.org/devel/")
    (nongnu . "https://elpa.nongnu.org/nongnu/")
    (nongnu-devel . "https://elpa.nongnu.org/nongnu-devel/")
    (melpa . "https://melpa.org/packages/")
    (melpa-stable . "https://stable.melpa.org/packages/"))
  "Known ELPA archive base URLs for native source fetches."
  :type '(alist :key-type symbol :value-type string)
  :group 'nelix-fetch)

(defun nelix-fetch--normalize-hash (hash)
  "Return HASH without the optional sha256- prefix."
  (unless (and (stringp hash)
               (> (length (nelix-compat-string-trim hash)) 0))
    (signal 'nelix-error
            (list (format "nelix-fetch: hash must be a non-empty string, got %S"
                          hash))))
  (let ((trimmed (nelix-compat-string-trim hash)))
    (if (string-prefix-p "sha256-" trimmed)
        (substring trimmed 7)
      trimmed)))

;;;###autoload
(defun nelix-fetch-sha256-file (file)
  "Return FILE's SHA-256 as a `sha256-<hex>' string."
  (cond
   ((and (fboundp 'with-temp-buffer)
         (fboundp 'insert-file-contents-literally)
         (fboundp 'secure-hash))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (concat "sha256-" (secure-hash 'sha256 (current-buffer)))))
   ((nelix-compat-executable-find "sha256sum")
    (let* ((res (nelix-compat-call-process
                 "sha256sum" (list (expand-file-name file))))
           (stdout (or (plist-get res :stdout) "")))
      (unless (eq 0 (plist-get res :exit))
        (signal 'nelix-error
                (list (format "nelix-fetch: sha256sum failed for %s" file))))
      (concat "sha256-" (car (split-string stdout)))))
   (t
    (signal 'nelix-error
            (list "nelix-fetch: no SHA-256 backend available")))))

;;;###autoload
(defun nelix-fetch-verify-file (file expected-sha256)
  "Verify FILE against EXPECTED-SHA256 and return a report plist."
  (let* ((actual (nelix-fetch-sha256-file file))
         (ok (equal (nelix-fetch--normalize-hash actual)
                    (nelix-fetch--normalize-hash expected-sha256))))
    (unless ok
      (signal 'nelix-error
              (list (format "nelix-fetch: hash mismatch for %s: expected %s actual %s"
                            file expected-sha256 actual)
                    :expected expected-sha256
                    :actual actual)))
    (list :ok t
          :file (expand-file-name file)
          :sha256 actual)))

(defun nelix-fetch--hash-string (string)
  "Return STRING's SHA-256 as a `sha256-<hex>' string."
  (cond
   ((fboundp 'nelisp--sha256)
    (concat "sha256-" (nelisp--sha256 string)))
   ((fboundp 'secure-hash)
    (concat "sha256-" (secure-hash 'sha256 string)))
   ((nelix-compat-executable-find "sha256sum")
    (let ((file (nelix-compat-make-temp-file "nelix-hash-")))
      (unwind-protect
          (progn
            (nelix-compat-write-file file string)
            (nelix-fetch-sha256-file file))
        (nelix-compat-delete-file-quietly file))))
   (t
    (signal 'nelix-error
            (list "nelix-fetch: no SHA-256 string backend available")))))

;;;###autoload
(defun nelix-fetch-sha256-string (string)
  "Return STRING's SHA-256 as a `sha256-<hex>' string."
  (unless (stringp string)
    (signal 'nelix-error
            (list (format "nelix-fetch: string hash input must be a string, got %S"
                          string))))
  (nelix-fetch--hash-string string))

;;;###autoload
(defun nelix-fetch-sha256-directory (directory)
  "Return a deterministic SHA-256 digest for DIRECTORY contents."
  (unless (and (fboundp 'file-directory-p)
               (file-directory-p directory))
    (signal 'nelix-error
            (list (format "nelix-fetch: not a directory: %s" directory))))
  (let* ((root (file-name-as-directory (expand-file-name directory)))
         (files (sort (directory-files-recursively root ".*" nil)
                      #'string<))
         records)
    (dolist (file files)
      (when (and (fboundp 'file-regular-p)
                 (file-regular-p file))
        (push (format "%s\0%s"
                      (file-relative-name file root)
                      (nelix-fetch-sha256-file file))
              records)))
    (nelix-fetch--hash-string (mapconcat #'identity (nreverse records) "\n"))))

(defun nelix-fetch--local-source-path (source)
  "Return expanded local path declared by SOURCE."
  (let ((path (or (plist-get source :path)
                  (plist-get source :file)
                  (plist-get source :directory))))
    (unless (and (stringp path)
                 (> (length (nelix-compat-string-trim path)) 0))
      (signal 'nelix-error
              (list (format "nelix-fetch: local source requires :path: %S"
                            source))))
    (expand-file-name (nelix-compat-string-trim path))))

;;;###autoload
(defun nelix-fetch-verify-local-source (source)
  "Verify local SOURCE path and return a report plist."
  (let* ((path (nelix-fetch--local-source-path source))
         (sha256 (plist-get source :sha256))
         (actual
          (cond
           ((and (fboundp 'file-directory-p)
                 (file-directory-p path))
            (nelix-fetch-sha256-directory path))
           ((nelix-compat-file-exists-p path)
            (nelix-fetch-sha256-file path))
           (t
            (signal 'nelix-error
                    (list (format "nelix-fetch: local source missing: %s"
                                  path)))))))
    (unless sha256
      (signal 'nelix-error
              (list (format "nelix-fetch-verify-local-source: source has no :sha256: %S"
                            source))))
    (unless (equal (nelix-fetch--normalize-hash actual)
                   (nelix-fetch--normalize-hash sha256))
      (signal 'nelix-error
              (list (format "nelix-fetch: hash mismatch for %s: expected %s actual %s"
                            path sha256 actual)
                    :expected sha256
                    :actual actual)))
    (list :ok t
          :path path
          :sha256 actual)))

(defun nelix-fetch--copy-file (source dest)
  "Copy SOURCE to DEST preserving binary content."
  (nelix-compat-make-directory (file-name-directory dest) t)
  (cond
   ((fboundp 'copy-file)
    (copy-file source dest t))
   ((nelix-compat-executable-find "cp")
    (let ((res (nelix-compat-call-process
                "cp" (list (expand-file-name source)
                           (expand-file-name dest)))))
      (unless (eq 0 (plist-get res :exit))
        (signal 'nelix-error
                (list (format "nelix-fetch: cp failed for %s: %s"
                              source
                              (nelix-compat-string-trim
                               (or (plist-get res :stderr) ""))))))))
   (t
    (signal 'nelix-error
            (list "nelix-fetch: no binary file copy backend available"))))
  dest)

(defun nelix-fetch--write-binary-file (dest bytes)
  "Write BYTES to DEST preserving binary content where supported."
  (nelix-compat-make-directory (file-name-directory dest) t)
  (if (fboundp 'with-temp-file)
      (let ((coding-system-for-write 'binary))
        (with-temp-file dest
          (set-buffer-multibyte nil)
          (insert bytes)))
    (nelix-compat-write-file dest bytes))
  dest)

(defun nelix-fetch--download-http (url dest)
  "Download URL to DEST."
  (cond
   ((nelix-compat-executable-find "curl")
    (let ((res (nelix-compat-call-process
                "curl"
                (list "--location" "--fail" "--silent" "--show-error"
                      "--output" (expand-file-name dest)
                      url))))
      (unless (eq 0 (plist-get res :exit))
        (signal 'nelix-error
                (list (format "nelix-fetch: curl failed for %s: %s"
                              url
                              (nelix-compat-string-trim
                               (or (plist-get res :stderr) ""))))))))
   (t
    (let ((resp (nelix-compat-http-get-binary
                 url nelix-fetch-timeout-seconds)))
      (unless (and (integerp (plist-get resp :status))
                   (<= 200 (plist-get resp :status))
                   (< (plist-get resp :status) 300))
        (signal 'nelix-error
                (list (format "nelix-fetch: HTTP %s for %s"
                              (plist-get resp :status) url))))
      (nelix-fetch--write-binary-file dest (plist-get resp :body)))))
  dest)

(defun nelix-fetch--run (program args &optional directory)
  "Run PROGRAM with ARGS in DIRECTORY and signal `nelix-error' on failure."
  (unless (nelix-compat-executable-find program)
    (signal 'nelix-error
            (list (format "nelix-fetch: required program not found: %s"
                          program))))
  (let* ((default-directory (or directory default-directory))
         (res (if (fboundp 'call-process)
                  (let ((stderr-file
                         (nelix-compat-make-temp-file
                          "nelix-fetch-stderr-")))
                    (unwind-protect
                        (with-temp-buffer
                          (let ((exit (apply #'call-process
                                             program nil
                                             (list (current-buffer)
                                                   stderr-file)
                                             nil args)))
                            (list :exit (if (numberp exit) exit -1)
                                  :stdout (buffer-string)
                                  :stderr
                                  (nelix-compat-read-file
                                   stderr-file))))
                      (nelix-compat-delete-file-quietly stderr-file)))
                (nelix-compat-call-process program args))))
    (unless (eq 0 (plist-get res :exit))
      (signal 'nelix-error
              (list (format "nelix-fetch: %s failed: %s"
                            program
                            (nelix-compat-string-trim
                             (or (plist-get res :stderr) ""))))))
    res))

(defun nelix-fetch--source-url (source)
  "Return download URL/path for SOURCE."
  (pcase (plist-get source :type)
    ('url (plist-get source :url))
    ('elpa
     (or (plist-get source :url)
         (nelix-fetch--elpa-source-url source)))
    ('github-release
     (let ((base-url (or (plist-get source :base-url)
                         "https://github.com"))
           (repo (plist-get source :repo))
           (tag (plist-get source :tag))
           (asset (plist-get source :asset)))
       (unless (and repo tag asset)
         (signal 'nelix-error
                 (list (format "nelix-fetch: incomplete github-release source %S"
                               source))))
       (format "%s/%s/releases/download/%s/%s"
               (directory-file-name base-url)
               repo tag asset)))
    (_
     (signal 'nelix-error
            (list (format "nelix-fetch: unsupported source type %S"
                           (plist-get source :type)))))))

(defun nelix-fetch--required-source-string (source key)
  "Return required non-empty SOURCE string value for KEY."
  (let ((value (plist-get source key)))
    (unless (and (stringp value)
                 (> (length (nelix-compat-string-trim value)) 0))
      (signal 'nelix-error
              (list (format "nelix-fetch: source requires %S: %S"
                            key source))))
    (nelix-compat-string-trim value)))

(defun nelix-fetch--ensure-directory-url (url)
  "Return URL with a trailing slash."
  (if (string-suffix-p "/" url)
      url
    (concat url "/")))

(defun nelix-fetch--elpa-archive-url (source)
  "Return ELPA archive base URL for SOURCE."
  (let ((base (plist-get source :base-url))
        (archive (plist-get source :archive)))
    (cond
     ((stringp base)
      (nelix-fetch--ensure-directory-url base))
     ((and (stringp archive)
           (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" archive))
      (nelix-fetch--ensure-directory-url archive))
     ((symbolp archive)
      (let ((url (alist-get archive nelix-fetch-elpa-archive-urls)))
        (unless url
          (signal 'nelix-error
                  (list (format "nelix-fetch: unknown ELPA archive %S"
                                archive))))
        (nelix-fetch--ensure-directory-url url)))
     (t
      (signal 'nelix-error
              (list (format "nelix-fetch: ELPA source requires :archive or :base-url: %S"
                            source)))))))

(defun nelix-fetch--elpa-source-url (source)
  "Return package archive URL for ELPA SOURCE."
  (let ((package (plist-get source :package))
        (version (plist-get source :version))
        (file (plist-get source :file)))
    (unless (and (stringp package)
                 (> (length (nelix-compat-string-trim package)) 0))
      (signal 'nelix-error
              (list (format "nelix-fetch: ELPA source requires :package: %S"
                            source))))
    (unless (or file
                (and (stringp version)
                     (> (length (nelix-compat-string-trim version)) 0)))
      (signal 'nelix-error
              (list (format "nelix-fetch: ELPA source requires :version or :file: %S"
                            source))))
    (concat (nelix-fetch--elpa-archive-url source)
            (or file
                (format "%s-%s.tar"
                        (nelix-compat-string-trim package)
                        (nelix-compat-string-trim version))))))

(defun nelix-fetch--download-url (url dest)
  "Download or copy URL to DEST."
  (cond
   ((and (stringp url) (string-prefix-p "file://" url))
    (nelix-fetch--copy-file (substring url 7) dest))
   ((and (stringp url)
         (not (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" url))
         (nelix-compat-file-exists-p url))
    (nelix-fetch--copy-file url dest))
   ((and (stringp url)
         (string-match-p "\\`https?://" url))
    (nelix-fetch--download-http url dest))
   (t
    (signal 'nelix-error
            (list (format "nelix-fetch: unsupported URL or missing local file %S"
                          url))))))

(defun nelix-fetch--delete-directory-quietly (directory)
  "Delete DIRECTORY recursively when available."
  (when (and directory
             (fboundp 'file-directory-p)
             (file-directory-p directory))
    (delete-directory directory t)))

(defun nelix-fetch--fetch-git-source (source dest)
  "Fetch Git SOURCE at its exact rev into DEST as a tar archive."
  (let* ((url (or (plist-get source :url)
                  (plist-get source :repo)))
         (rev (nelix-fetch--required-source-string source :rev))
         (tmp (make-temp-file "nelix-git-source-" t))
         (checkout (expand-file-name "checkout" tmp)))
    (unless (and (stringp url)
                 (> (length (nelix-compat-string-trim url)) 0))
      (signal 'nelix-error
              (list (format "nelix-fetch: git source requires :url or :repo: %S"
                            source))))
    (unwind-protect
        (progn
          (nelix-fetch--run
           "git"
           (list "clone" "--quiet" "--no-checkout"
                 (nelix-compat-string-trim url)
                 checkout))
          (nelix-fetch--run
           "git"
           (list "-c" "advice.detachedHead=false"
                 "checkout" "--detach" rev)
           checkout)
          (when (plist-get source :submodules)
            (nelix-fetch--run
             "git"
             (list "submodule" "update" "--init" "--recursive")
             checkout))
          (nelix-fetch--run
           "git"
           (list "archive" "--format=tar"
                 "--output" (expand-file-name dest)
                 "HEAD")
           checkout)
          (list :url (nelix-compat-string-trim url)
                :rev rev))
      (nelix-fetch--delete-directory-quietly tmp))))

;;;###autoload
(defun nelix-fetch-source (source dest)
  "Fetch SOURCE into DEST, verify SHA-256, and return a report plist."
  (let* ((sha256 (plist-get source :sha256))
         (fetch-report nil))
    (unless sha256
      (signal 'nelix-error
              (list (format "nelix-fetch-source: source has no :sha256: %S"
                            source))))
    (setq fetch-report
          (if (eq (plist-get source :type) 'git)
              (nelix-fetch--fetch-git-source source dest)
            (let ((url (nelix-fetch--source-url source)))
              (nelix-fetch--download-url url dest)
              (list :url url))))
    (let ((verify (nelix-fetch-verify-file dest sha256)))
      (append (list :source source)
              fetch-report
              verify))))

(provide 'nelix-fetch)
;;; nelix-fetch.el ends here
