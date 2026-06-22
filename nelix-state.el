;;; nelix-state.el --- Cross-session KV store for nelix-core caches  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Wakaba Tono

;; Author: zawatton
;; Maintainer: zawatton
;; URL: https://github.com/zawatton/nelix-core
;; Keywords: tools
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Phase 4-D L26 — namespaced KV with optional TTL, persisted to disk so
;; nelix-core caches survive Emacs restarts.
;;
;; Backend: JSON file under `nelix-state-file' (default
;; ~/.local/state/nelix/state.json).  The file is loaded lazily on the
;; first read / write and re-saved after every put / delete.  Layout:
;;
;;     {
;;       "<namespace>": {
;;         "<key>": {"value": "<prin1-string>", "expires-at": NUMBER-OR-NULL}
;;       }
;;     }
;;
;; Values are stored as `prin1-to-string' / `read' round-tripped Lisp text
;; rather than mapped onto JSON primitives.  This trades a tiny CPU cost
;; for the ability to round-trip arbitrary nelix-core shapes — keywords
;; (`:hit-pkg-el'), nested plists, and quoted symbols — without
;; lossy JSON conversion (`feedback_emacs_json_false_encoding' notes
;; that bare keywords like `:hit' are not JSON values).
;;
;; Hard-isolation point: every IO goes through `nelix-core--call-state-fn'
;; (defined in nelix-core.el and bound at module load time to
;; `nelix-state--default-call').  Tests `cl-letf' that fluid to mock the
;; whole storage layer without touching the disk.
;;
;; API:
;;   (nelix-state-get NS KEY)      → value or nil (expired entries
;;                                       transparently dropped)
;;   (nelix-state-put NS KEY VAL &optional TTL-SECONDS)
;;                                     → VAL
;;   (nelix-state-delete NS KEY)   → t
;;   (nelix-state-clear NS)        → t  (drops one namespace)
;;   (nelix-state-clear-all)       → t  (drops every namespace)
;;   (nelix-state-keys NS)         → list of strings
;;
;; OQ15 (design 07-phase4d.org): NeLisp does not yet expose sqlite-*; the
;; JSON backend is uniform across runtimes and adequate for nelix-core's
;; tiny caches (< 1k entries total).  A SQLite backend is a Phase 5+
;; concern.

;;; Code:

(require 'nelix-compat)

(defgroup nelix-state nil
  "Cross-session KV store for nelix-core caches."
  :group 'nelix-core
  :prefix "nelix-state-")

(defcustom nelix-state-file
  (expand-file-name
   "nelix/state.json"
   (or (nelix-compat-getenv "XDG_STATE_HOME")
       (expand-file-name ".local/state"
                         (or (nelix-compat-getenv "HOME") "~"))))
  "Path to the Nelix JSON state file."
  :type 'file
  :group 'nelix-state)

(defvar nelix-state--cache 'unloaded
  "In-process snapshot of the on-disk JSON state.

Alist of NAMESPACE → alist of KEY → plist (:value V :expires-at T-OR-NIL).
The sentinel symbol `unloaded' means the cache has not been
populated from disk yet (or the file path changed); a plain nil
means an intentionally empty store (after `clear-all').  This
distinction is required so writes don't accidentally re-read stale
content via ensure-loaded.")

(defvar nelix-state--loaded-from nil
  "Path the cache in `nelix-state--cache' was last loaded from, or nil.")

;;;; --- low-level cache <-> disk -----------------------------------------------

(defun nelix-state--ensure-loaded ()
  "Populate `nelix-state--cache' from disk if not yet loaded.

Re-reads when `nelix-state-file' has changed since last load (the
common test pattern of binding the file path to a tmp value).  An
empty cache for the current path is left alone so writes do not get
silently overwritten by stale on-disk content."
  (when (or (eq nelix-state--cache 'unloaded)
            (not (equal nelix-state--loaded-from nelix-state-file)))
    (setq nelix-state--cache
          (nelix-state--read-disk nelix-state-file)
          nelix-state--loaded-from nelix-state-file)))

(defun nelix-state--read-disk (path)
  "Read PATH and return its parsed alist, or empty alist if missing.

Parse failures degrade silently to an empty store + a warning so a
corrupt file never crashes nelix-core."
  (cond
   ((not (nelix-compat-file-exists-p path)) nil)
   (t
    (condition-case err
        (let* ((raw (nelix-compat-read-file path))
               (parsed (and raw (> (length raw) 0)
                            (nelix-compat-json-parse raw))))
          (nelix-state--normalize parsed))
      (error
       (lwarn 'nelix-core :warning
              "nelix-state: failed to parse %s (%S); starting empty"
              path err)
       nil)))))

(defun nelix-state--normalize (parsed)
  "Coerce PARSED JSON output into the canonical alist-of-alists shape.

Values stored as prin1 strings on disk are read back into native
Lisp objects; corrupted entries (`read' fails) are dropped with a
warning so a single bad row never poisons the whole namespace."
  (let (out)
    (dolist (ns-pair (nelix-state--as-alist parsed))
      (let* ((ns (nelix-state--key->string (car ns-pair)))
             (entries (nelix-state--as-alist (cdr ns-pair)))
             (cleaned
              (delq nil
                    (mapcar
                     (lambda (kv)
                       (let* ((k (nelix-state--key->string (car kv)))
                              (v (cdr kv))
                              (alist (nelix-state--as-alist v))
                              (raw-value (cdr (or (assoc "value" alist)
                                                  (assoc 'value alist))))
                              (exp (cdr (or (assoc "expires-at" alist)
                                            (assoc 'expires-at alist))))
                              (value
                               (condition-case err
                                   (cond
                                    ((null raw-value) nil)
                                    ((stringp raw-value)
                                     (car (read-from-string raw-value)))
                                    ;; Tolerate legacy entries written
                                    ;; before the prin1 wrap landed —
                                    ;; their value is the raw object.
                                    (t raw-value))
                                 (error
                                  (lwarn 'nelix-core :warning
                                         "nelix-state: dropping unreadable value for %s/%s: %S"
                                         ns k err)
                                  'nelix-state--unreadable))))
                         (when (and k (not (eq value 'nelix-state--unreadable)))
                           (cons k (list :value value
                                         :expires-at
                                         (cond
                                          ((null exp) nil)
                                          ((eq exp :null) nil)
                                          ((numberp exp) exp)
                                          ((stringp exp)
                                           (string-to-number exp))
                                          (t nil)))))))
                     entries))))
        (when ns (push (cons ns cleaned) out))))
    (nreverse out)))

(defun nelix-state--as-alist (obj)
  "Best-effort coerce OBJ (alist / hash-table / plist / nil) to an alist."
  (cond
   ((null obj) nil)
   ((hash-table-p obj)
    (let (acc)
      (maphash (lambda (k v) (push (cons k v) acc)) obj)
      acc))
   ((and (consp obj) (consp (car obj))) obj)
   ((and (consp obj) (keywordp (car obj)))
    ;; plist → alist
    (let (acc)
      (while obj
        (push (cons (car obj) (cadr obj)) acc)
        (setq obj (cddr obj)))
      (nreverse acc)))
   (t nil)))

(defun nelix-state--key->string (k)
  "Coerce a JSON-derived key K (string / symbol / keyword) to string."
  (cond
   ((stringp k) k)
   ((keywordp k) (substring (symbol-name k) 1))
   ((symbolp k) (symbol-name k))
   (t nil)))

(defun nelix-state--write-disk ()
  "Serialise `nelix-state--cache' back to `nelix-state-file'."
  (nelix-state--ensure-loaded)
  (nelix-compat-make-directory
   (file-name-directory nelix-state-file) t)
  (let ((json
         (nelix-state--encode nelix-state--cache)))
    (nelix-compat-write-file nelix-state-file json)))

(defun nelix-state--encode (cache)
  "Convert CACHE alist-of-alists to a JSON string via hash-tables.

Each value plist is serialised as
`{\"value\": \"<prin1>\", \"expires-at\": NUMBER-OR-NULL}' so we can
round-trip keywords / nested plists / symbols without lossy JSON
mapping.  Uses hash-tables (per `feedback_emacs_json_empty_object_encoding'
— empty alists serialize to `null') so
`nelix-compat-json-serialize' emits real JSON objects even for
empty namespaces."
  (let ((outer (make-hash-table :test 'equal)))
    (dolist (ns-pair cache)
      (let ((ns-key (car ns-pair))
            (inner (make-hash-table :test 'equal)))
        (dolist (kv (cdr ns-pair))
          (let* ((k (car kv))
                 (v (cdr kv))
                 (entry (make-hash-table :test 'equal)))
            (puthash "value"
                     (prin1-to-string (plist-get v :value))
                     entry)
            (puthash "expires-at"
                     (plist-get v :expires-at)
                     entry)
            (puthash k entry inner)))
        (puthash ns-key inner outer)))
    (nelix-compat-json-serialize outer)))

;;;; --- pure cache mutators ---------------------------------------------------

(defun nelix-state--cache-get (ns key)
  "Return the entry plist for NS / KEY, dropping it if expired.

Returns nil when missing, when expired (and as a side effect removes
the expired entry from the cache), or when the namespace does not
exist."
  (let* ((ns-pair (assoc ns nelix-state--cache))
         (entries (cdr ns-pair))
         (entry (cdr (assoc key entries))))
    (cond
     ((null entry) nil)
     ((nelix-state--expired-p entry)
      (nelix-state--cache-delete ns key)
      nil)
     (t entry))))

(defun nelix-state--cache-put (ns key value ttl-seconds)
  "Insert / replace (NS, KEY) → VALUE in the cache; honour TTL-SECONDS.

When TTL-SECONDS is nil the entry never expires."
  (let* ((ns-pair (assoc ns nelix-state--cache))
         (entries (cdr ns-pair))
         (entry (list :value value
                      :expires-at
                      (when (numberp ttl-seconds)
                        (+ (float-time) ttl-seconds)))))
    (setq entries (cons (cons key entry)
                        (assoc-delete-all key entries)))
    (cond
     (ns-pair
      (setcdr ns-pair entries))
     (t
      (push (cons ns entries) nelix-state--cache)))))

(defun nelix-state--cache-delete (ns key)
  "Remove (NS, KEY) from the cache.  No-op when absent."
  (let* ((ns-pair (assoc ns nelix-state--cache)))
    (when ns-pair
      (setcdr ns-pair (assoc-delete-all key (cdr ns-pair))))))

(defun nelix-state--cache-clear (ns)
  "Drop every entry under NS."
  (setq nelix-state--cache
        (assoc-delete-all ns nelix-state--cache)))

(defun nelix-state--expired-p (entry)
  "Non-nil when the ENTRY plist has an expires-at strictly in the past."
  (let ((exp (plist-get entry :expires-at)))
    (and (numberp exp)
         (< exp (float-time)))))

;;;; --- backend dispatch ------------------------------------------------------

(defvar nelix-state--default-call-fn
  (lambda (op &rest args)
    "Default storage backend; OP ∈ (:get :put :delete :clear :clear-all :keys)."
    (nelix-state--ensure-loaded)
    (pcase op
      (:get
       (let ((entry (nelix-state--cache-get (nth 0 args) (nth 1 args))))
         (and entry (plist-get entry :value))))
      (:put
       (nelix-state--cache-put
        (nth 0 args) (nth 1 args) (nth 2 args) (nth 3 args))
       (nelix-state--write-disk)
       (nth 2 args))
      (:delete
       (nelix-state--cache-delete (nth 0 args) (nth 1 args))
       (nelix-state--write-disk)
       t)
      (:clear
       (nelix-state--cache-clear (nth 0 args))
       (nelix-state--write-disk)
       t)
      (:clear-all
       (setq nelix-state--cache nil)
       (nelix-state--write-disk)
       t)
      (:keys
       (let ((entries (cdr (assoc (nth 0 args) nelix-state--cache))))
         ;; Drop expired entries lazily so callers never see them.
         (delq nil
               (mapcar (lambda (kv)
                         (unless (nelix-state--expired-p (cdr kv))
                           (car kv)))
                       entries))))
      (_ (error "Unknown nelix-state op: %S" op))))
  "Default storage backend lambda.

Bound at module init.  Tests `cl-letf' the dispatch fluid
`nelix-core--call-state-fn' below to inject a mock; this default
never touches the network and only writes to `nelix-state-file'.")

(defvar nelix-core--call-state-fn
  (lambda (op &rest args)
    (apply nelix-state--default-call-fn op args))
  "Indirection for state backend calls.

Default thunk forwards to `nelix-state--default-call-fn'.  Tests
rebind via `cl-letf' to mock the persistent layer without touching
`nelix-state-file'.")

;;;; --- public API ------------------------------------------------------------

(defun nelix-state-get (namespace key)
  "Return the value stored under NAMESPACE + KEY, or nil."
  (funcall nelix-core--call-state-fn :get namespace key))

(defun nelix-state-put (namespace key value &optional ttl-seconds)
  "Store VALUE under NAMESPACE + KEY; optional TTL-SECONDS expiry.

Returns VALUE."
  (funcall nelix-core--call-state-fn :put namespace key value ttl-seconds))

(defun nelix-state-delete (namespace key)
  "Remove KEY from NAMESPACE.  Returns t."
  (funcall nelix-core--call-state-fn :delete namespace key))

(defun nelix-state-clear (namespace)
  "Drop every entry in NAMESPACE.  Returns t."
  (funcall nelix-core--call-state-fn :clear namespace))

(defun nelix-state-clear-all ()
  "Drop every namespace.  Returns t."
  (funcall nelix-core--call-state-fn :clear-all))

(defun nelix-state-keys (namespace)
  "Return the list of non-expired keys in NAMESPACE."
  (funcall nelix-core--call-state-fn :keys namespace))

(provide 'nelix-state)
;;; nelix-state.el ends here
