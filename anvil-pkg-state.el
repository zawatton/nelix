;;; anvil-pkg-state.el --- Cross-session KV store for anvil-pkg caches  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Wakaba Tono

;; Author: zawatton
;; Maintainer: zawatton
;; URL: https://github.com/zawatton/anvil-pkg
;; Keywords: tools
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Phase 4-D L26 — namespaced KV with optional TTL, persisted to disk so
;; anvil-pkg caches survive Emacs restarts.
;;
;; Backend: JSON file under `anvil-pkg-state-file' (default
;; ~/.local/state/anvil-pkg/state.json).  The file is loaded lazily on the
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
;; for the ability to round-trip arbitrary anvil-pkg shapes — keywords
;; (`:hit-pkg-el'), nested plists, and quoted symbols — without
;; lossy JSON conversion (`feedback_emacs_json_false_encoding' notes
;; that bare keywords like `:hit' are not JSON values).
;;
;; Hard-isolation point: every IO goes through `anvil-pkg--call-state-fn'
;; (defined in anvil-pkg.el and bound at module load time to
;; `anvil-pkg-state--default-call').  Tests `cl-letf' that fluid to mock the
;; whole storage layer without touching the disk.
;;
;; API:
;;   (anvil-pkg-state-get NS KEY)      → value or nil (expired entries
;;                                       transparently dropped)
;;   (anvil-pkg-state-put NS KEY VAL &optional TTL-SECONDS)
;;                                     → VAL
;;   (anvil-pkg-state-delete NS KEY)   → t
;;   (anvil-pkg-state-clear NS)        → t  (drops one namespace)
;;   (anvil-pkg-state-clear-all)       → t  (drops every namespace)
;;   (anvil-pkg-state-keys NS)         → list of strings
;;
;; OQ15 (design 07-phase4d.org): NeLisp does not yet expose sqlite-*; the
;; JSON backend is uniform across runtimes and adequate for anvil-pkg's
;; tiny caches (< 1k entries total).  A SQLite backend is a Phase 5+
;; concern.

;;; Code:

(require 'anvil-pkg-compat)

(defgroup anvil-pkg-state nil
  "Cross-session KV store for anvil-pkg caches."
  :group 'anvil-pkg
  :prefix "anvil-pkg-state-")

(defcustom anvil-pkg-state-file
  (expand-file-name
   "anvil-pkg/state.json"
   (or (anvil-pkg-compat-getenv "XDG_STATE_HOME")
       (expand-file-name ".local/state" "~")))
  "Path to the anvil-pkg JSON state file."
  :type 'file
  :group 'anvil-pkg-state)

(defvar anvil-pkg-state--cache 'unloaded
  "In-process snapshot of the on-disk JSON state.

Alist of NAMESPACE → alist of KEY → plist (:value V :expires-at T-OR-NIL).
The sentinel symbol `unloaded' means the cache has not been
populated from disk yet (or the file path changed); a plain nil
means an intentionally empty store (after `clear-all').  This
distinction is required so writes don't accidentally re-read stale
content via ensure-loaded.")

(defvar anvil-pkg-state--loaded-from nil
  "Path the cache in `anvil-pkg-state--cache' was last loaded from, or nil.")

;;;; --- low-level cache <-> disk -----------------------------------------------

(defun anvil-pkg-state--ensure-loaded ()
  "Populate `anvil-pkg-state--cache' from disk if not yet loaded.

Re-reads when `anvil-pkg-state-file' has changed since last load (the
common test pattern of binding the file path to a tmp value).  An
empty cache for the current path is left alone so writes do not get
silently overwritten by stale on-disk content."
  (when (or (eq anvil-pkg-state--cache 'unloaded)
            (not (equal anvil-pkg-state--loaded-from anvil-pkg-state-file)))
    (setq anvil-pkg-state--cache
          (anvil-pkg-state--read-disk anvil-pkg-state-file)
          anvil-pkg-state--loaded-from anvil-pkg-state-file)))

(defun anvil-pkg-state--read-disk (path)
  "Read PATH and return its parsed alist, or empty alist if missing.

Parse failures degrade silently to an empty store + a warning so a
corrupt file never crashes anvil-pkg."
  (cond
   ((not (anvil-pkg-compat-file-exists-p path)) nil)
   (t
    (condition-case err
        (let* ((raw (anvil-pkg-compat-read-file path))
               (parsed (and raw (> (length raw) 0)
                            (anvil-pkg-compat-json-parse raw))))
          (anvil-pkg-state--normalize parsed))
      (error
       (lwarn 'anvil-pkg :warning
              "anvil-pkg-state: failed to parse %s (%S); starting empty"
              path err)
       nil)))))

(defun anvil-pkg-state--normalize (parsed)
  "Coerce PARSED JSON output into the canonical alist-of-alists shape.

Values stored as prin1 strings on disk are read back into native
Lisp objects; corrupted entries (`read' fails) are dropped with a
warning so a single bad row never poisons the whole namespace."
  (let (out)
    (dolist (ns-pair (anvil-pkg-state--as-alist parsed))
      (let* ((ns (anvil-pkg-state--key->string (car ns-pair)))
             (entries (anvil-pkg-state--as-alist (cdr ns-pair)))
             (cleaned
              (delq nil
                    (mapcar
                     (lambda (kv)
                       (let* ((k (anvil-pkg-state--key->string (car kv)))
                              (v (cdr kv))
                              (alist (anvil-pkg-state--as-alist v))
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
                                  (lwarn 'anvil-pkg :warning
                                         "anvil-pkg-state: dropping unreadable value for %s/%s: %S"
                                         ns k err)
                                  'anvil-pkg-state--unreadable))))
                         (when (and k (not (eq value 'anvil-pkg-state--unreadable)))
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

(defun anvil-pkg-state--as-alist (obj)
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

(defun anvil-pkg-state--key->string (k)
  "Coerce a JSON-derived key K (string / symbol / keyword) to string."
  (cond
   ((stringp k) k)
   ((keywordp k) (substring (symbol-name k) 1))
   ((symbolp k) (symbol-name k))
   (t nil)))

(defun anvil-pkg-state--write-disk ()
  "Serialise `anvil-pkg-state--cache' back to `anvil-pkg-state-file'."
  (anvil-pkg-state--ensure-loaded)
  (anvil-pkg-compat-make-directory
   (file-name-directory anvil-pkg-state-file) t)
  (let ((json
         (anvil-pkg-state--encode anvil-pkg-state--cache)))
    (anvil-pkg-compat-write-file anvil-pkg-state-file json)))

(defun anvil-pkg-state--encode (cache)
  "Convert CACHE alist-of-alists to a JSON string via hash-tables.

Each value plist is serialised as
`{\"value\": \"<prin1>\", \"expires-at\": NUMBER-OR-NULL}' so we can
round-trip keywords / nested plists / symbols without lossy JSON
mapping.  Uses hash-tables (per `feedback_emacs_json_empty_object_encoding'
— empty alists serialize to `null') so `json-serialize' emits real
JSON objects even for empty namespaces."
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
                     (or (plist-get v :expires-at) :null)
                     entry)
            (puthash k entry inner)))
        (puthash ns-key inner outer)))
    (json-serialize outer :null-object :null :false-object :json-false)))

;;;; --- pure cache mutators ---------------------------------------------------

(defun anvil-pkg-state--cache-get (ns key)
  "Return the entry plist for NS / KEY, dropping it if expired.

Returns nil when missing, when expired (and as a side effect removes
the expired entry from the cache), or when the namespace does not
exist."
  (let* ((ns-pair (assoc ns anvil-pkg-state--cache))
         (entries (cdr ns-pair))
         (entry (cdr (assoc key entries))))
    (cond
     ((null entry) nil)
     ((anvil-pkg-state--expired-p entry)
      (anvil-pkg-state--cache-delete ns key)
      nil)
     (t entry))))

(defun anvil-pkg-state--cache-put (ns key value ttl-seconds)
  "Insert / replace (NS, KEY) → VALUE in the cache; honour TTL-SECONDS.

When TTL-SECONDS is nil the entry never expires."
  (let* ((ns-pair (assoc ns anvil-pkg-state--cache))
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
      (push (cons ns entries) anvil-pkg-state--cache)))))

(defun anvil-pkg-state--cache-delete (ns key)
  "Remove (NS, KEY) from the cache.  No-op when absent."
  (let* ((ns-pair (assoc ns anvil-pkg-state--cache)))
    (when ns-pair
      (setcdr ns-pair (assoc-delete-all key (cdr ns-pair))))))

(defun anvil-pkg-state--cache-clear (ns)
  "Drop every entry under NS."
  (setq anvil-pkg-state--cache
        (assoc-delete-all ns anvil-pkg-state--cache)))

(defun anvil-pkg-state--expired-p (entry)
  "Non-nil when the ENTRY plist has an expires-at strictly in the past."
  (let ((exp (plist-get entry :expires-at)))
    (and (numberp exp)
         (< exp (float-time)))))

;;;; --- backend dispatch ------------------------------------------------------

(defvar anvil-pkg-state--default-call-fn
  (lambda (op &rest args)
    "Default storage backend; OP ∈ (:get :put :delete :clear :clear-all :keys)."
    (anvil-pkg-state--ensure-loaded)
    (pcase op
      (:get
       (let ((entry (anvil-pkg-state--cache-get (nth 0 args) (nth 1 args))))
         (and entry (plist-get entry :value))))
      (:put
       (anvil-pkg-state--cache-put
        (nth 0 args) (nth 1 args) (nth 2 args) (nth 3 args))
       (anvil-pkg-state--write-disk)
       (nth 2 args))
      (:delete
       (anvil-pkg-state--cache-delete (nth 0 args) (nth 1 args))
       (anvil-pkg-state--write-disk)
       t)
      (:clear
       (anvil-pkg-state--cache-clear (nth 0 args))
       (anvil-pkg-state--write-disk)
       t)
      (:clear-all
       (setq anvil-pkg-state--cache nil)
       (anvil-pkg-state--write-disk)
       t)
      (:keys
       (let ((entries (cdr (assoc (nth 0 args) anvil-pkg-state--cache))))
         ;; Drop expired entries lazily so callers never see them.
         (delq nil
               (mapcar (lambda (kv)
                         (unless (anvil-pkg-state--expired-p (cdr kv))
                           (car kv)))
                       entries))))
      (_ (error "Unknown anvil-pkg-state op: %S" op))))
  "Default storage backend lambda.

Bound at module init.  Tests `cl-letf' the dispatch fluid
`anvil-pkg--call-state-fn' below to inject a mock; this default
never touches the network and only writes to `anvil-pkg-state-file'.")

(defvar anvil-pkg--call-state-fn
  (lambda (op &rest args)
    (apply anvil-pkg-state--default-call-fn op args))
  "Indirection for state backend calls.

Default thunk forwards to `anvil-pkg-state--default-call-fn'.  Tests
rebind via `cl-letf' to mock the persistent layer without touching
`anvil-pkg-state-file'.")

;;;; --- public API ------------------------------------------------------------

(defun anvil-pkg-state-get (namespace key)
  "Return the value stored under NAMESPACE + KEY, or nil."
  (funcall anvil-pkg--call-state-fn :get namespace key))

(defun anvil-pkg-state-put (namespace key value &optional ttl-seconds)
  "Store VALUE under NAMESPACE + KEY; optional TTL-SECONDS expiry.

Returns VALUE."
  (funcall anvil-pkg--call-state-fn :put namespace key value ttl-seconds))

(defun anvil-pkg-state-delete (namespace key)
  "Remove KEY from NAMESPACE.  Returns t."
  (funcall anvil-pkg--call-state-fn :delete namespace key))

(defun anvil-pkg-state-clear (namespace)
  "Drop every entry in NAMESPACE.  Returns t."
  (funcall anvil-pkg--call-state-fn :clear namespace))

(defun anvil-pkg-state-clear-all ()
  "Drop every namespace.  Returns t."
  (funcall anvil-pkg--call-state-fn :clear-all))

(defun anvil-pkg-state-keys (namespace)
  "Return the list of non-expired keys in NAMESPACE."
  (funcall anvil-pkg--call-state-fn :keys namespace))

(provide 'anvil-pkg-state)
;;; anvil-pkg-state.el ends here
