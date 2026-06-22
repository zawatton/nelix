;;; nelix-substitute.el --- Nelix native substitute metadata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Phase N8 substitute support.  This module records precomputed native
;; substitute descriptors, verifies payload hashes, materializes payloads into
;; the native store, and creates profile generations from substitute entries.
;; The descriptors remain plain data so registry servers, local mirrors, and a
;; Nix substitute bridge can share the same validation path.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'nelix-core)
(require 'nelix-compat)
(require 'nelix-store)
(require 'nelix-fetch)
(require 'nelix-builder)

(defgroup nelix-substitute nil
  "Nelix native substitute metadata."
  :group 'nelix-core
  :prefix "nelix-substitute-")

(defcustom nelix-substitute-root nil
  "Root directory for native Nelix substitute metadata.
When nil, `nelix-substitute-root' computes an OS-appropriate default."
  :type '(choice (const :tag "Auto" nil) directory)
  :group 'nelix-substitute)

(defcustom nelix-substitute-trusted-signers nil
  "Trusted substitute signing key names.
This is the policy gate for metadata verification.  Cryptographic
signature verification is handled separately by
`nelix-substitute-public-keys' when a descriptor signature declares a
supported algorithm."
  :type '(repeat string)
  :group 'nelix-substitute)

(defcustom nelix-substitute-public-keys nil
  "Trusted public keys for cryptographic substitute signature verification.
Each entry is a plist with `:key', `:algorithm', and either
`:public-key-file' or `:public-key' for public-key algorithms.
The verifier supports `openssl-rsa-sha256' keys through the local
openssl command, Nix binary-cache Ed25519 public keys in
`key-name:base64' or raw base64 form, and OpenSSL-free
`nelix-sha256-digest' descriptor digest entries for native bootstrap
integrity checks."
  :type '(repeat sexp)
  :group 'nelix-substitute)

(defcustom nelix-substitute-crypto-verifiers
  '((nelix-sha256-digest . nelix-substitute--sha256-digest-verify)
    (sha256-digest . nelix-substitute--sha256-digest-verify))
  "Registered cryptographic verifier functions by algorithm.
Each function receives MESSAGE, SIGNATURE, KEY-ENTRY, and ALGORITHM,
and returns a plist with at least `:verified'.  This hook lets the
NeLisp runtime provide native Ed25519/RSA implementations without
changing substitute trust-policy code."
  :type '(repeat sexp)
  :group 'nelix-substitute)

(defcustom nelix-substitute-require-cryptographic-signatures nil
  "Whether trusted substitute signatures must pass cryptographic verification.
When nil, legacy string signatures remain policy-only.  Signatures that
declare a cryptographic algorithm are always verified."
  :type 'boolean
  :group 'nelix-substitute)

(defcustom nelix-substitute-require-signature-on-materialize nil
  "Whether `nelix-substitute-materialize' requires a trusted signature.
Individual descriptors can also set `:require-signature' to non-nil."
  :type 'boolean
  :group 'nelix-substitute)

(defvar nelix-substitute-last nil
  "Most recently loaded `nelix-substitute' plist.")

;;;###autoload
(defun nelix-substitute-root ()
  "Return the native Nelix substitute metadata root."
  (expand-file-name
   (or nelix-substitute-root
       (expand-file-name "nelix/substitutes"
                         (nelix-store--local-data-home)))))

(defun nelix-substitute--required-string (caller plist key)
  "Return non-empty string value for KEY in PLIST."
  (let ((value (plist-get plist key)))
    (cond
     ((and (stringp value)
           (> (length (nelix-compat-string-trim value)) 0))
      (nelix-compat-string-trim value))
     ((symbolp value) (symbol-name value))
     (t
      (signal 'nelix-error
              (list (format "%s: %S must be a non-empty string or symbol, got %S"
                            caller key value)))))))

(defun nelix-substitute--plist-keys (plist)
  "Return keyword keys in PLIST, rejecting malformed input."
  (let ((rest plist)
        keys)
    (while rest
      (unless (and (consp rest) (consp (cdr rest)))
        (signal 'nelix-error
                (list (format "nelix-substitute: malformed plist %S" plist))))
      (push (car rest) keys)
      (setq rest (cddr rest)))
    (nreverse keys)))

(defun nelix-substitute--signature-key (signature)
  "Return key name from SIGNATURE, or nil when unavailable."
  (cond
   ((and (stringp signature)
         (string-match "\\`\\([^:]+\\):" signature))
    (match-string 1 signature))
   ((and (consp signature)
         (plist-get signature :key))
    (plist-get signature :key))
   (t nil)))

(defun nelix-substitute--signature-algorithm (signature)
  "Return cryptographic algorithm from SIGNATURE, or nil."
  (and (consp signature)
       (or (plist-get signature :algorithm)
           (plist-get signature :type))))

(defun nelix-substitute--signature-value (signature)
  "Return encoded signature bytes from SIGNATURE, or nil."
  (cond
   ((and (stringp signature)
         (string-match "\\`[^:]+:\\(.+\\)\\'" signature))
    (match-string 1 signature))
   ((consp signature)
    (or (plist-get signature :value)
        (plist-get signature :signature)
        (plist-get signature :sig)))
   (t nil)))

(defun nelix-substitute--effective-signature-algorithm (substitute signature)
  "Return cryptographic algorithm for SUBSTITUTE SIGNATURE, when declared."
  (or (nelix-substitute--signature-algorithm signature)
      (plist-get substitute :signature-algorithm)
      (and (eq (plist-get substitute :signature-format) 'nix-narinfo)
           'nix-ed25519)))

(defun nelix-substitute--plist-without-keys (plist keys)
  "Return PLIST without keyword KEYS."
  (let ((rest plist)
        out)
    (while rest
      (unless (and (consp rest) (consp (cdr rest)))
        (signal 'nelix-error
                (list (format "nelix-substitute: malformed plist %S" plist))))
      (unless (memq (car rest) keys)
        (push (car rest) out)
        (push (cadr rest) out))
      (setq rest (cddr rest)))
    (nreverse out)))

(defun nelix-substitute--canonical-plist (plist)
  "Return PLIST with pairs sorted for stable signature input."
  (let ((rest plist)
        pairs
        out)
    (while rest
      (push (list (car rest) (cadr rest)) pairs)
      (setq rest (cddr rest)))
    (setq pairs
          (sort pairs
                (lambda (a b)
                  (string< (symbol-name (car a))
                           (symbol-name (car b))))))
    (dolist (pair pairs (nreverse out))
      (push (car pair) out)
      (push (cadr pair) out))))

;;;###autoload
(defun nelix-substitute-canonical-message (substitute)
  "Return canonical signed text for SUBSTITUTE.
The signature fields themselves are excluded so the returned text is
stable before and after a descriptor is signed."
  (let* ((unsigned
          (nelix-substitute--plist-without-keys
           substitute
           '(:sig :signature)))
         (normalized (apply #'nelix-substitute unsigned)))
    (nelix-store--format-plist-call
     'nelix-substitute
     (nelix-substitute--canonical-plist normalized))))

(defun nelix-substitute--public-key-entry (key algorithm public-keys)
  "Return public-key entry for KEY and ALGORITHM from PUBLIC-KEYS."
  (let ((keys (or public-keys nelix-substitute-public-keys))
        found)
    (while (and keys (not found))
      (let ((entry (car keys)))
        (when (and (equal key (plist-get entry :key))
                   (eq algorithm (plist-get entry :algorithm)))
          (setq found entry)))
      (setq keys (cdr keys)))
    found))

;;;###autoload
(defun nelix-substitute-register-crypto-verifier (algorithm function)
  "Register FUNCTION as cryptographic verifier for ALGORITHM.
FUNCTION is called with MESSAGE, SIGNATURE, KEY-ENTRY, and ALGORITHM."
  (unless (symbolp algorithm)
    (signal 'nelix-error
            (list (format "nelix-substitute: verifier algorithm must be a symbol, got %S"
                          algorithm))))
  (unless (functionp function)
    (signal 'nelix-error
            (list (format "nelix-substitute: verifier must be callable, got %S"
                          function))))
  (setq nelix-substitute-crypto-verifiers
        (cons (cons algorithm function)
              (assq-delete-all algorithm
                               nelix-substitute-crypto-verifiers)))
  function)

(defun nelix-substitute--crypto-verifier (algorithm)
  "Return registered verifier function for ALGORITHM, or nil."
  (let ((entry (assq algorithm nelix-substitute-crypto-verifiers)))
    (and entry (cdr entry))))

(defun nelix-substitute--write-binary-file (file bytes)
  "Write BYTES to FILE preserving binary content when possible."
  (nelix-compat-make-directory (file-name-directory file) t)
  (if (fboundp 'with-temp-file)
      (let ((coding-system-for-write 'binary))
        (with-temp-file file
          (set-buffer-multibyte nil)
          (insert bytes)))
    (nelix-compat-write-file file bytes))
  file)

(defun nelix-substitute--hex-to-bytes (hex)
  "Return unibyte string represented by HEX."
  (let ((index 0)
        (len (length hex))
        (bytes ""))
    (unless (zerop (% len 2))
      (signal 'nelix-error
              (list (format "nelix-substitute: odd hex string length: %S"
                            hex))))
    (setq bytes (make-string (/ len 2) 0))
    (while (< index len)
      (aset bytes
            (/ index 2)
            (string-to-number (substring hex index (+ index 2)) 16))
      (setq index (+ index 2)))
    bytes))

(defun nelix-substitute--sha256-digest-verify
    (message signature key-entry algorithm)
  "Verify SIGNATURE as SHA-256 digest of MESSAGE without OpenSSL.
KEY-ENTRY is accepted for the common verifier interface; trust is still
enforced by the signature key and `nelix-substitute-trusted-signers'."
  (ignore key-entry)
  (condition-case err
      (let* ((expected (downcase (nelix-fetch--normalize-hash signature)))
             (actual-value (nelix-fetch-sha256-string message))
             (actual (downcase (nelix-fetch--normalize-hash actual-value))))
        (if (equal expected actual)
            (list :verified t
                  :backend 'nelix-native
                  :algorithm algorithm
                  :digest actual-value)
          (list :verified nil
                :backend 'nelix-native
                :algorithm algorithm
                :digest actual-value
                :blocked :cryptographic-signature-invalid)))
    (error
     (list :verified nil
           :backend 'nelix-native
           :algorithm algorithm
           :blocked :cryptographic-signature-error
           :message (error-message-string err)))))

(defun nelix-substitute--base64-key-material (encoded)
  "Return base64 key material from ENCODED Nix key string."
  (let ((trimmed (and (stringp encoded)
                      (nelix-compat-string-trim encoded))))
    (cond
     ((not trimmed) nil)
     ((string-match "\\`[^:]+:\\(.+\\)\\'" trimmed)
      (match-string 1 trimmed))
     (t trimmed))))

(defun nelix-substitute--executable-find (program)
  "Return PROGRAM path using the host runtime when possible."
  (or (and (fboundp 'executable-find)
           (executable-find program))
      (nelix-compat-executable-find program)))

(defun nelix-substitute--call-process (program args)
  "Run PROGRAM with ARGS and return `(:exit :stdout :stderr)'."
  (if (fboundp 'call-process)
      (let ((stdout (generate-new-buffer " *nelix-substitute-stdout*"))
            (stderr-file (nelix-compat-make-temp-file
                          "nelix-substitute-stderr-")))
        (unwind-protect
            (let* ((exit (apply #'call-process
                                program
                                nil
                                (list stdout stderr-file)
                                nil
                                args))
                   (stdout-text (with-current-buffer stdout
                                  (buffer-string)))
                   (stderr-text
                    (if (and stderr-file
                             (file-exists-p stderr-file))
                        (with-temp-buffer
                          (insert-file-contents stderr-file)
                          (buffer-string))
                      "")))
              (list :exit exit
                    :stdout stdout-text
                    :stderr stderr-text))
          (kill-buffer stdout)
          (nelix-compat-delete-file-quietly stderr-file)))
    (nelix-compat-call-process program args)))

(defun nelix-substitute--openssl-rsa-sha256-verify (message signature key-entry)
  "Verify SIGNATURE over MESSAGE with OpenSSL RSA-SHA256 KEY-ENTRY."
  (if (not (nelix-substitute--executable-find "openssl"))
      (list :verified nil
            :blocked :verifier-unavailable
            :message "openssl command not found")
    (let ((message-file (nelix-compat-make-temp-file "nelix-signature-message-"))
          (signature-file (nelix-compat-make-temp-file "nelix-signature-"))
          (public-key-file nil)
          (temp-public-key-file nil)
          decoded
          res)
      (unwind-protect
          (condition-case err
              (progn
                (setq decoded (base64-decode-string signature))
                (nelix-substitute--write-binary-file message-file message)
                (nelix-substitute--write-binary-file signature-file decoded)
                (setq public-key-file
                      (or (plist-get key-entry :public-key-file)
                          (when (plist-get key-entry :public-key)
                            (setq temp-public-key-file
                                  (nelix-compat-make-temp-file
                                   "nelix-public-key-"))
                            (nelix-compat-write-file
                             temp-public-key-file
                             (plist-get key-entry :public-key))
                            temp-public-key-file)))
                (unless public-key-file
                  (signal 'nelix-error
                          (list "nelix-substitute: public key entry has no :public-key-file or :public-key")))
                (setq res
                      (nelix-substitute--call-process
                       "openssl"
                       (list "dgst" "-sha256"
                             "-verify" (expand-file-name public-key-file)
                             "-signature" (expand-file-name signature-file)
                             (expand-file-name message-file))))
                (if (eq 0 (plist-get res :exit))
                    (list :verified t
                          :backend 'openssl
                          :algorithm 'openssl-rsa-sha256)
                  (list :verified nil
                        :backend 'openssl
                        :algorithm 'openssl-rsa-sha256
                        :blocked :cryptographic-signature-invalid
                        :stderr (nelix-compat-string-trim
                                 (or (plist-get res :stderr) "")))))
            (error
             (list :verified nil
                   :backend 'openssl
                   :algorithm 'openssl-rsa-sha256
                   :blocked :cryptographic-signature-error
                   :message (error-message-string err))))
        (nelix-compat-delete-file-quietly message-file)
        (nelix-compat-delete-file-quietly signature-file)
        (when temp-public-key-file
          (nelix-compat-delete-file-quietly temp-public-key-file))))))

(defun nelix-substitute--nix-ed25519-public-key-der (key-entry)
  "Return DER SubjectPublicKeyInfo bytes for Nix Ed25519 KEY-ENTRY."
  (let* ((encoded (or (plist-get key-entry :public-key)
                      (plist-get key-entry :public-key-raw)))
         (material (nelix-substitute--base64-key-material encoded))
         (raw (and material (base64-decode-string material)))
         ;; SEQUENCE { SEQUENCE { OID 1.3.101.112 }, BIT STRING raw32 }
         (prefix (nelix-substitute--hex-to-bytes
                  "302a300506032b6570032100")))
    (unless raw
      (signal 'nelix-error
              (list "nelix-substitute: Nix Ed25519 key entry has no :public-key")))
    (unless (= (length raw) 32)
      (signal 'nelix-error
              (list (format "nelix-substitute: Nix Ed25519 public key must decode to 32 bytes, got %s"
                            (length raw)))))
    (concat prefix raw)))

(defun nelix-substitute--nix-ed25519-verify (message signature key-entry)
  "Verify SIGNATURE over MESSAGE with Nix binary cache Ed25519 KEY-ENTRY."
  (if (not (nelix-substitute--executable-find "openssl"))
      (list :verified nil
            :backend 'openssl
            :algorithm 'nix-ed25519
            :blocked :verifier-unavailable
            :message "openssl command not found")
    (let ((message-file (nelix-compat-make-temp-file "nelix-nix-ed25519-message-"))
          (signature-file (nelix-compat-make-temp-file "nelix-nix-ed25519-signature-"))
          (public-key-file (nelix-compat-make-temp-file "nelix-nix-ed25519-public-key-"))
          decoded
          res)
      (unwind-protect
          (condition-case err
              (progn
                (setq decoded (base64-decode-string signature))
                (unless (= (length decoded) 64)
                  (signal 'nelix-error
                          (list (format "nelix-substitute: Nix Ed25519 signature must decode to 64 bytes, got %s"
                                        (length decoded)))))
                (nelix-substitute--write-binary-file message-file message)
                (nelix-substitute--write-binary-file signature-file decoded)
                (nelix-substitute--write-binary-file
                 public-key-file
                 (nelix-substitute--nix-ed25519-public-key-der key-entry))
                (setq res
                      (nelix-substitute--call-process
                       "openssl"
                       (list "pkeyutl"
                             "-verify"
                             "-rawin"
                             "-pubin"
                             "-inkey" (expand-file-name public-key-file)
                             "-keyform" "DER"
                             "-sigfile" (expand-file-name signature-file)
                             "-in" (expand-file-name message-file))))
                (if (eq 0 (plist-get res :exit))
                    (list :verified t
                          :backend 'openssl
                          :algorithm 'nix-ed25519)
                  (list :verified nil
                        :backend 'openssl
                        :algorithm 'nix-ed25519
                        :blocked :cryptographic-signature-invalid
                        :stderr (nelix-compat-string-trim
                                 (or (plist-get res :stderr) "")))))
            (error
             (list :verified nil
                   :backend 'openssl
                   :algorithm 'nix-ed25519
                   :blocked :cryptographic-signature-error
                   :message (error-message-string err))))
        (nelix-compat-delete-file-quietly message-file)
        (nelix-compat-delete-file-quietly signature-file)
        (nelix-compat-delete-file-quietly public-key-file)))))

(defun nelix-substitute--cryptographic-signature-report
    (substitute signature &optional public-keys)
  "Return cryptographic verification report for SUBSTITUTE SIGNATURE."
  (let* ((algorithm (nelix-substitute--effective-signature-algorithm
                     substitute
                     signature))
         (canonical-algorithm
          (if (eq algorithm 'rsa-sha256) 'openssl-rsa-sha256 algorithm))
         (key (nelix-substitute--signature-key signature))
         (value (nelix-substitute--signature-value signature))
         (required (or algorithm
                       nelix-substitute-require-cryptographic-signatures))
         (registered-verifier
          (and canonical-algorithm
               (nelix-substitute--crypto-verifier canonical-algorithm)))
         (builtin-verifier
          (and canonical-algorithm
               (memq canonical-algorithm
                     '(openssl-rsa-sha256 nix-ed25519)))))
    (cond
     ((not required)
      (list :required nil
            :verified nil
            :blocked nil))
     ((null algorithm)
      (list :required t
            :verified nil
            :blocked :missing-signature-algorithm))
     ((and (not registered-verifier)
           (not builtin-verifier))
      (list :required t
            :algorithm algorithm
            :verified nil
            :blocked :unsupported-signature-algorithm))
     ((null value)
      (list :required t
            :algorithm algorithm
            :verified nil
            :blocked :missing-signature-value))
     (t
      (let ((key-entry
             (nelix-substitute--public-key-entry
              key
              canonical-algorithm
              public-keys)))
        (if (not key-entry)
            (list :required t
                  :algorithm algorithm
                  :key key
                  :verified nil
                  :blocked :missing-public-key)
          (append
           (list :required t
                 :key key)
           (cond
            (registered-verifier
             (funcall registered-verifier
                      (if (eq canonical-algorithm 'nix-ed25519)
                          (or (plist-get substitute :signature-message)
                              (nelix-substitute-canonical-message substitute))
                        (nelix-substitute-canonical-message substitute))
                      value
                      key-entry
                      canonical-algorithm))
            ((eq canonical-algorithm 'nix-ed25519)
             (nelix-substitute--nix-ed25519-verify
              (or (plist-get substitute :signature-message)
                  (nelix-substitute-canonical-message substitute))
              value
              key-entry))
            (t
             (nelix-substitute--openssl-rsa-sha256-verify
              (nelix-substitute-canonical-message substitute)
              value
              key-entry))))))))))

(defun nelix-substitute--join-url (base path)
  "Return PATH joined to BASE as a URL string."
  (concat (replace-regexp-in-string "/\\'" "" base)
          "/"
          (replace-regexp-in-string "\\`/" "" path)))

(defun nelix-substitute--payload-url (substitute)
  "Return the downloadable payload URL/path for SUBSTITUTE."
  (let ((direct (or (plist-get substitute :nar-url)
                    (plist-get substitute :url)
                    (plist-get substitute :archive-file)
                    (plist-get substitute :file)
                    (plist-get substitute :nar-path)))
        (cache (plist-get substitute :cache)))
    (cond
     ((null direct) nil)
     ((and (stringp direct)
           (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" direct))
      direct)
     ((and (stringp direct)
           (or (file-name-absolute-p direct)
               (nelix-compat-file-exists-p direct)))
      direct)
     ((and (stringp cache) (stringp direct))
      (nelix-substitute--join-url cache direct))
     (t direct))))

(defun nelix-substitute--payload-format (substitute)
  "Return payload format for SUBSTITUTE."
  (or (plist-get substitute :nar-format)
      (plist-get substitute :archive-format)
      (if (eq (plist-get substitute :source) 'nix-cache) 'nar 'tar)))

(defun nelix-substitute--narinfo-number (field value)
  "Parse narinfo numeric FIELD from VALUE."
  (if (and (stringp value)
           (string-match-p "\\`[0-9]+\\'" value))
      (string-to-number value)
    (signal 'nelix-error
            (list (format "nelix-substitute-parse-narinfo: invalid %s: %S"
                          field value)))))

(defun nelix-substitute--store-path-name (store-path)
  "Return output name portion from STORE-PATH."
  (let* ((base (file-name-nondirectory
                (directory-file-name store-path)))
         (dash (string-match "-" base)))
    (if dash
        (substring base (1+ dash))
      base)))

(defun nelix-substitute--narinfo-reference-path (reference &optional store-dir)
  "Return full store path for narinfo REFERENCE."
  (let ((root (or store-dir "/nix/store")))
    (if (string-prefix-p "/" reference)
        reference
      (expand-file-name reference root))))

;;;###autoload
(defun nelix-substitute-parse-narinfo (text)
  "Parse Nix .narinfo TEXT into a plist.

The parser accepts the fields produced by Nix binary caches:
StorePath, URL, Compression, FileHash, FileSize, NarHash, NarSize,
References, Deriver, repeated Sig fields, and CA."
  (let ((lines (split-string text "\n"))
        plist
        signatures)
    (dolist (line lines)
      (unless (string-empty-p line)
        (unless (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" line)
          (signal 'nelix-error
                  (list (format "nelix-substitute-parse-narinfo: malformed line %S"
                                line))))
        (let ((field (match-string 1 line))
              (value (match-string 2 line)))
          (pcase field
            ("StorePath" (setq plist (plist-put plist :store-path value)))
            ("URL" (setq plist (plist-put plist :nar-url value)))
            ("Compression" (setq plist (plist-put plist :compression value)))
            ("FileHash" (setq plist (plist-put plist :file-hash value)))
            ("FileSize" (setq plist (plist-put plist :file-size
                                                (nelix-substitute--narinfo-number
                                                 field value))))
            ("NarHash" (setq plist (plist-put plist :nar-hash value)))
            ("NarSize" (setq plist (plist-put plist :nar-size
                                               (nelix-substitute--narinfo-number
                                                field value))))
            ("References" (setq plist (plist-put plist :references
                                                  (split-string value " " t))))
            ("Deriver" (setq plist (plist-put plist :deriver value)))
            ("Sig" (push value signatures))
            ("CA" (setq plist (plist-put plist :content-address value)))))))
    (dolist (key '(:store-path :nar-url :nar-hash :nar-size))
      (unless (plist-get plist key)
        (signal 'nelix-error
                (list (format "nelix-substitute-parse-narinfo: missing %S"
                              key)))))
    (when (zerop (plist-get plist :nar-size))
      (signal 'nelix-error
              (list "nelix-substitute-parse-narinfo: NarSize missing or zero")))
    (setq plist (plist-put plist :compression
                           (or (plist-get plist :compression) "bzip2")))
    (when signatures
      (setq plist (plist-put plist :signatures (nreverse signatures))))
    plist))

;;;###autoload
(defun nelix-substitute-narinfo-fingerprint (narinfo &optional store-dir)
  "Return Nix signature fingerprint string for NARINFO.

NARINFO may be a parsed plist or raw .narinfo text.  The format matches
Nix valid path fingerprints:
\"1;<store-path>;<nar-hash>;<nar-size>;<comma-separated references>\"."
  (let* ((info (if (stringp narinfo)
                   (nelix-substitute-parse-narinfo narinfo)
                 narinfo))
         (references
          (sort
           (mapcar (lambda (ref)
                     (nelix-substitute--narinfo-reference-path ref store-dir))
                   (or (plist-get info :references) nil))
           #'string<)))
    (format "1;%s;%s;%s;%s"
            (plist-get info :store-path)
            (plist-get info :nar-hash)
            (plist-get info :nar-size)
            (mapconcat #'identity references ","))))

(defun nelix-substitute--payload-source (substitute)
  "Return a fetch source plist for SUBSTITUTE."
  (let ((url (nelix-substitute--payload-url substitute)))
    (unless url
      (signal 'nelix-error
              (list "nelix-substitute-materialize: substitute has no :nar-url, :url, :file, or :archive-file")))
    (list :type 'url
          :url url
          :sha256 (plist-get substitute :sha256)
          :archive-format (nelix-substitute--payload-format substitute))))

(defun nelix-substitute--store-entry (substitute)
  "Return native store entry metadata for SUBSTITUTE."
  (let ((entry (list :name (plist-get substitute :name)
                     :version (plist-get substitute :version)
                     :system (plist-get substitute :system)
                     :hash (plist-get substitute :sha256)
                     :backend 'nelix-native
                     :source 'substitute
                     :substitute substitute
                     :install (or (plist-get substitute :install)
                                  (list :type 'substitute))
                     :runtime-paths (plist-get substitute :runtime-paths)
                     :files (plist-get substitute :files))))
    (dolist (key '(:cache :store-path :nar-hash :references :nar-size))
      (when (plist-get substitute key)
        (setq entry (plist-put entry key (plist-get substitute key)))))
    entry))

(defun nelix-substitute--restore-nar (payload store-path)
  "Restore NAR PAYLOAD into STORE-PATH using nix-store."
  (unless (nelix-compat-executable-find "nix-store")
    (signal 'nelix-error
            (list "nelix-substitute-materialize: nix-store is required to restore NAR payloads")))
  (unless (nelix-compat-executable-find "sh")
    (signal 'nelix-error
            (list "nelix-substitute-materialize: sh is required to stream NAR payloads")))
  (let ((res (nelix-compat-call-process
              "sh"
              (list "-c"
                    "nix-store --restore \"$1\" < \"$2\""
                    "nelix-nar-restore"
                    (expand-file-name store-path)
                    (expand-file-name payload)))))
    (unless (eq 0 (plist-get res :exit))
      (signal 'nelix-error
              (list (format "nelix-substitute-materialize: nix-store --restore failed: %s"
                            (nelix-compat-string-trim
                             (or (plist-get res :stderr) ""))))))))

(defun nelix-substitute--unpack-payload (payload store-path substitute)
  "Unpack PAYLOAD into STORE-PATH according to SUBSTITUTE."
  (let ((format (nelix-substitute--payload-format substitute)))
    (nelix-compat-make-directory (file-name-directory store-path) t)
    (pcase format
      ('nar
       (nelix-substitute--restore-nar payload store-path))
      ((or 'tar 'zip)
       (nelix-builder--extract-archive
        payload
        store-path
        (list :archive-format format)
        (or (plist-get substitute :install)
            (list :type 'substitute))))
      (_
       (signal 'nelix-error
               (list (format "nelix-substitute-materialize: unsupported payload format %S"
                             format)))))))

(defun nelix-substitute--profile-entry (substitute store-path)
  "Return a native profile entry for SUBSTITUTE at STORE-PATH."
  (let* ((install (plist-get substitute :install))
         (entry (list :name (plist-get substitute :name)
                      :version (plist-get substitute :version)
                      :store-path store-path
                      :backend 'nelix-native
                      :runtime-paths
                      (or (plist-get substitute :runtime-paths)
                          (nelix-builder-runtime-paths install)))))
    (when (or (plist-get substitute :emacs-load-paths)
              (plist-get install :load-paths)
              (plist-get install :emacs-load-paths))
      (setq entry
            (plist-put
             entry
             :emacs-load-paths
             (mapcar (lambda (path) (expand-file-name path store-path))
                     (or (plist-get substitute :emacs-load-paths)
                         (nelix-builder-emacs-load-paths install))))))
    (when (or (plist-get substitute :features)
              (plist-get install :features))
      (setq entry
            (plist-put entry :features
                       (or (plist-get substitute :features)
                           (plist-get install :features)))))
    entry))

;;;###autoload
(defun nelix-substitute (&rest plist)
  "Return normalized native substitute metadata PLIST.

Required keys are `:name', `:version', `:system', `:source', and
`:sha256'.  The `:sha256' value identifies the downloadable
substitute payload or local fixture file represented by the
descriptor."
  (dolist (key '(:name :version :system :source :sha256))
    (unless (memq key (nelix-substitute--plist-keys plist))
      (signal 'nelix-error
              (list (format "nelix-substitute: missing %S" key)))))
  (let* ((name (nelix-substitute--required-string
                "nelix-substitute" plist :name))
         (version (nelix-substitute--required-string
                   "nelix-substitute" plist :version))
         (sha256 (nelix-substitute--required-string
                  "nelix-substitute" plist :sha256))
         (system (plist-get plist :system))
         (source (plist-get plist :source))
         (substitute (copy-sequence plist)))
    (unless (symbolp system)
      (signal 'nelix-error
              (list (format "nelix-substitute: :system must be symbol, got %S"
                            system))))
    (unless (symbolp source)
      (signal 'nelix-error
              (list (format "nelix-substitute: :source must be symbol, got %S"
                            source))))
    (when (eq source 'nix-cache)
      (dolist (key '(:cache :store-path :nar-hash))
        (unless (memq key (nelix-substitute--plist-keys plist))
          (signal 'nelix-error
                  (list (format "nelix-substitute: nix-cache source missing %S"
                                key))))))
    (setq substitute (plist-put substitute :name name))
    (setq substitute (plist-put substitute :version version))
    (setq substitute (plist-put substitute :sha256 sha256))
    (setq nelix-substitute-last substitute)))

;;;###autoload
(defun nelix-substitute-from-nix (plist)
  "Return a normalized Nix-cache substitute descriptor from PLIST.

PLIST is precomputed metadata exported by a maintainer.  This
bridge does not query cache.nixos.org or evaluate nixpkgs; it only
maps explicit Nix substitute metadata into Nelix's data format."
  (let* ((nar-hash (or (plist-get plist :nar-hash)
                       (plist-get plist :sha256)))
         (descriptor
          (append
           (list :source 'nix-cache
                 :sha256 nar-hash)
           plist)))
    (apply #'nelix-substitute descriptor)))

;;;###autoload
(defun nelix-substitute-from-narinfo (narinfo metadata)
  "Return a normalized Nix-cache substitute descriptor from NARINFO.

NARINFO may be raw .narinfo text or a parsed narinfo plist.  METADATA
must provide at least `:system' and `:cache'.  `:name' and `:version'
default to the store output name and \"narinfo\" respectively when not
provided by METADATA."
  (let* ((info (if (stringp narinfo)
                   (nelix-substitute-parse-narinfo narinfo)
                 narinfo))
         (signatures (plist-get info :signatures))
         (store-path (plist-get info :store-path))
         (descriptor
          (append
           (list :name (or (plist-get metadata :name)
                           (nelix-substitute--store-path-name store-path))
                 :version (or (plist-get metadata :version) "narinfo")
                 :system (plist-get metadata :system)
                 :source 'nix-cache
                 :cache (plist-get metadata :cache)
                 :store-path store-path
                 :nar-url (plist-get info :nar-url)
                 :nar-hash (plist-get info :nar-hash)
                 :sha256 (plist-get info :nar-hash)
                 :nar-size (plist-get info :nar-size)
                 :compression (plist-get info :compression)
                 :file-hash (plist-get info :file-hash)
                 :file-size (plist-get info :file-size)
                 :references
                 (mapcar #'nelix-substitute--narinfo-reference-path
                         (or (plist-get info :references) nil))
                 :deriver (plist-get info :deriver)
                 :content-address (plist-get info :content-address)
                 :signature-format 'nix-narinfo
                 :signature-algorithm 'nix-ed25519
                 :signature-message
                 (nelix-substitute-narinfo-fingerprint info)
                 :sig (car signatures)
                 :signatures signatures)
           metadata)))
    (apply #'nelix-substitute descriptor)))

(defun nelix-substitute--file (substitute)
  "Return metadata file path for SUBSTITUTE."
  (expand-file-name
   (format "%s-%s.el"
           (plist-get substitute :name)
           (plist-get substitute :version))
   (expand-file-name (symbol-name (plist-get substitute :system))
                     (nelix-substitute-root))))

;;;###autoload
(defun nelix-substitute-write (substitute)
  "Write SUBSTITUTE metadata and return its file path."
  (let* ((normalized (apply #'nelix-substitute substitute))
         (file (nelix-substitute--file normalized)))
    (nelix-compat-make-directory (file-name-directory file) t)
    (nelix-compat-write-file
     file
     (concat ";;; substitute.el --- generated Nelix substitute metadata -*- lexical-binding: t; -*-\n\n"
             "(require 'nelix-substitute)\n\n"
             (nelix-store--format-plist-call 'nelix-substitute normalized)))
    file))

;;;###autoload
(defun nelix-substitute-read (file)
  "Read substitute metadata from FILE."
  (let ((nelix-substitute-last nil))
    (unless (nelix-compat-file-exists-p file)
      (signal 'nelix-error
              (list (format "nelix-substitute-read: missing file %s" file))))
    (load (expand-file-name file) nil nil t)
    nelix-substitute-last))

;;;###autoload
(defun nelix-substitute-list (&optional system)
  "Return substitute metadata entries, optionally limited to SYSTEM."
  (let* ((root (nelix-substitute-root))
         (systems (if system
                      (list (symbol-name system))
                    (and (fboundp 'file-directory-p)
                         (file-directory-p root)
                         (directory-files root nil "\\`[^.]"))))
         rows)
    (dolist (sys systems (nreverse rows))
      (let ((dir (expand-file-name sys root)))
        (when (and (fboundp 'file-directory-p)
                   (file-directory-p dir))
          (dolist (file (directory-files dir t "\\.el\\'"))
            (push (nelix-substitute-read file) rows)))))))

;;;###autoload
(defun nelix-substitute-verify (substitute)
  "Verify SUBSTITUTE metadata and optional local payload hash."
  (let* ((normalized (apply #'nelix-substitute substitute))
         (file (or (plist-get normalized :file)
                   (plist-get normalized :archive-file)))
         (file-report (when file
                        (nelix-fetch-verify-file
                         file
                         (plist-get normalized :sha256)))))
    (list :ok t
          :substitute normalized
          :file file
          :file-report file-report)))

;;;###autoload
(defun nelix-substitute-signature-report
    (substitute &optional trusted-signers public-keys)
  "Return signature policy report for SUBSTITUTE.

`:verified' is non-nil when the descriptor has a signature whose key is
listed in TRUSTED-SIGNERS or `nelix-substitute-trusted-signers', and any
declared cryptographic verifier also succeeds."
  (let* ((normalized (apply #'nelix-substitute substitute))
         (signature (or (plist-get normalized :sig)
                        (plist-get normalized :signature)))
         (key (nelix-substitute--signature-key signature))
         (trusted (or trusted-signers nelix-substitute-trusted-signers))
         (policy-verified (and key (member key trusted)))
         (crypto (nelix-substitute--cryptographic-signature-report
                  normalized
                  signature
                  public-keys))
         (crypto-verified (or (not (plist-get crypto :required))
                              (plist-get crypto :verified)))
         (verified (and policy-verified crypto-verified)))
    (list :present (and signature t)
          :signature signature
          :key key
          :trusted-signers trusted
          :crypto crypto
          :verified (and verified t)
          :blocked (cond
                    ((null signature) :missing-signature)
                    ((null key) :missing-signature-key)
                    ((not policy-verified) :untrusted-signature)
                    ((not crypto-verified) (plist-get crypto :blocked))
                    (t nil)))))

;;;###autoload
(defun nelix-substitute-verify-trust
    (substitute &optional trusted-signers public-keys)
  "Verify SUBSTITUTE metadata, payload hash, and signature policy."
  (let* ((base (nelix-substitute-verify substitute))
         (sig (nelix-substitute-signature-report
               (plist-get base :substitute)
               trusted-signers
               public-keys)))
    (setq base (plist-put base :signature sig))
    (setq base (plist-put base :trusted (plist-get sig :verified)))
    (plist-put base :ok (and (plist-get base :ok)
                             (plist-get sig :verified)))))

(defun nelix-substitute--maybe-verify-materialize-trust (substitute)
  "Verify SUBSTITUTE trust when materialization policy requires it."
  (when (or nelix-substitute-require-signature-on-materialize
            (plist-get substitute :require-signature))
    (let ((report (nelix-substitute-verify-trust substitute)))
      (unless (plist-get report :ok)
        (signal 'nelix-error
                (list (format "nelix-substitute-materialize: untrusted substitute signature: %S"
                              (plist-get (plist-get report :signature)
                                         :blocked))
                      :signature (plist-get report :signature)))))))

;;;###autoload
(defun nelix-substitute-materialize (substitute)
  "Download/verify/unpack SUBSTITUTE into the native store.

Nix-cache descriptors default to true NAR payloads and are restored via
`nix-store --restore'.  Descriptors can set `:nar-format' or
`:archive-format' to `tar' or `zip' for maintainer-provided portable
substitute archives and local tests."
  (let* ((normalized (apply #'nelix-substitute substitute))
         (entry (nelix-substitute--store-entry normalized))
         (store-path (nelix-store-entry-path entry))
         (payload (nelix-compat-make-temp-file "nelix-substitute-"))
         fetch-report)
    (nelix-substitute--maybe-verify-materialize-trust normalized)
    (unwind-protect
        (progn
          (setq fetch-report
                (nelix-fetch-source
                 (nelix-substitute--payload-source normalized)
                 payload))
          (nelix-compat-make-directory store-path t)
          (nelix-substitute--unpack-payload payload store-path normalized)
          (nelix-store-write-entry entry)
          (list :status 'ok
                :backend 'nelix-native
                :operation 'materialize-substitute
                :name (plist-get normalized :name)
                :version (plist-get normalized :version)
                :system (plist-get normalized :system)
                :store-path store-path
                :substitute normalized
                :fetch fetch-report
                :entry entry))
      (nelix-compat-delete-file-quietly payload))))

;;;###autoload
(defun nelix-substitute-install (substitute &optional profile-name system)
  "Materialize SUBSTITUTE and add it to PROFILE-NAME."
  (let* ((report (nelix-substitute-materialize substitute))
         (normalized (plist-get report :substitute))
         (system* (or system (plist-get normalized :system)))
         (profile-name* (or profile-name nelix-builder-default-profile))
         (profile
          (nelix-profile-create-generation
           profile-name*
           system*
           (list (nelix-substitute--profile-entry
                  normalized
                  (plist-get report :store-path))))))
    (setq report (plist-put report :operation 'install-substitute))
    (plist-put report :profile profile)))

(provide 'nelix-substitute)
;;; nelix-substitute.el ends here
