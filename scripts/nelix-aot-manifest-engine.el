;;; nelix-aot-manifest-engine.el --- Compact Nelix AOT manifest engine -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This module is the portable source for the command-specific Nelix
;; native/AOT manifest engine described in Doc 25.  It intentionally consumes
;; `nelix-fast-aot-input' line protocol instead of plist-heavy manifest data.

;;; Code:

(require 'cl-lib)

(defconst nelix-aot-manifest-engine-version "NELIX-AOT-MANIFEST-V1"
  "Line protocol version consumed by the AOT manifest engine.")

(defun nelix-aot--error (message)
  "Signal a Nelix AOT engine error with MESSAGE."
  (error "nelix-aot: %s" message))

(defun nelix-aot--parse-lines (text)
  "Return non-empty LF-separated lines from TEXT."
  (let ((i 0)
        (start 0)
        (n (length (or text "")))
        lines)
    (setq text (or text ""))
    (while (< i n)
      (when (eq (aref text i) ?\n)
        (when (> i start)
          (push (substring text start i) lines))
        (setq start (1+ i)))
      (setq i (1+ i)))
    (when (> n start)
      (push (substring text start n) lines))
    (nreverse lines)))

(defun nelix-aot--for-each-line (text fn)
  "Call FN for each non-empty LF-separated line in TEXT."
  (let ((i 0)
        (start 0)
        (n (length (or text ""))))
    (setq text (or text ""))
    (while (< i n)
      (when (eq (aref text i) ?\n)
        (when (> i start)
          (funcall fn (substring text start i)))
        (setq start (1+ i)))
      (setq i (1+ i)))
    (when (> n start)
      (funcall fn (substring text start n)))))

(defun nelix-aot--line-prefix-p (prefix line)
  "Return non-nil when LINE starts with PREFIX."
  (let ((n (length prefix)))
    (and (<= n (length line))
         (equal (substring line 0 n) prefix))))

(defun nelix-aot--after-prefix (prefix line)
  "Return LINE after PREFIX."
  (substring line (length prefix)))

(defun nelix-aot--tab-index (line start)
  "Return the next tab index in LINE at or after START, or nil."
  (let ((i start)
        (n (length line))
        found)
    (while (and (< i n) (null found))
      (if (eq (aref line i) ?\t)
          (setq found i)
        (setq i (1+ i))))
    found))

(defun nelix-aot--parse-positive-int-range (text start end)
  "Return positive integer parsed from TEXT[START, END), or nil."
  (let ((i start)
        (number 0)
        (ok (< start end)))
    (while (and ok (< i end))
      (let ((ch (aref text i)))
        (if (and (>= ch ?0) (<= ch ?9))
            (setq number (+ (* number 10) (- ch ?0)))
          (setq ok nil)))
      (setq i (1+ i)))
    (and ok (> number 0) number)))

(defun nelix-aot--parse-positive-int-line-tail (line start)
  "Return positive integer parsed from LINE starting at START, or nil."
  (nelix-aot--parse-positive-int-range line start (length line)))

(defun nelix-aot--ids-from-line-tail (line start)
  "Return positive integer IDs parsed from tab-separated LINE tail."
  (let ((n (length line))
        ids
        end
        id)
    (while (<= start n)
      (setq end (or (nelix-aot--tab-index line start) n))
      (setq id (nelix-aot--parse-positive-int-range line start end))
      (when id
        (push id ids))
      (setq start (1+ end)))
    (nreverse ids)))

(defun nelix-aot--strings-from-line-tail (line start)
  "Return non-empty tab-separated strings parsed from LINE tail."
  (let ((n (length line))
        strings
        end
        value)
    (while (<= start n)
      (setq end (or (nelix-aot--tab-index line start) n))
      (setq value (substring line start end))
      (when (> (length value) 0)
        (push value strings))
      (setq start (1+ end)))
    (nreverse strings)))

(defun nelix-aot--strip-duplicate-suffix (name)
  "Return NAME without a Nix duplicate suffix like \"-1\"."
  (let ((i (and (stringp name) (1- (length name))))
        (saw-digit nil))
    (while (and i (>= i 0)
                (let ((ch (aref name i)))
                  (and (>= ch ?0) (<= ch ?9))))
      (setq saw-digit t)
      (setq i (1- i)))
    (if (and saw-digit i (>= i 0) (eq (aref name i) ?-))
        (substring name 0 i)
      name)))

(defun nelix-aot--push-unique (value list)
  "Return LIST with VALUE appended if absent."
  (if (member value list)
      list
    (append list (list value))))

(defun nelix-aot--cons-unique (value list)
  "Return LIST with VALUE consed if absent."
  (if (member value list)
      list
    (cons value list)))

(defun nelix-aot--normalize-name-list (names)
  "Return NAMES plus duplicate-suffix-normalized aliases."
  (let (out)
    (dolist (name names out)
      (when (and (stringp name) (> (length name) 0))
        (setq out (nelix-aot--push-unique name out))
        (setq out (nelix-aot--push-unique
                   (nelix-aot--strip-duplicate-suffix name)
                   out))))))

(defun nelix-aot--parse-positive-int (value)
  "Return VALUE parsed as a positive integer, or nil."
  (when (and (stringp value) (> (length value) 0))
    (let ((i 0)
          (n (length value))
          (number 0)
          (ok t))
      (while (and ok (< i n))
        (let ((ch (aref value i)))
          (if (and (>= ch ?0) (<= ch ?9))
              (setq number (+ (* number 10) (- ch ?0)))
            (setq ok nil)))
        (setq i (1+ i)))
      (and ok (> number 0) number))))

(defun nelix-aot--parse-input (text)
  "Parse Nelix AOT line protocol TEXT into a compact plist."
  (let (manifest
        profile
        system
        backend
        targets
        target-ids
        pins
        pin-ids
        installed
        installed-ids
        installed-id-names
        name-ids
        last-installed
        saw-version
        ended)
    (nelix-aot--for-each-line
     text
     (lambda (line)
       (if (null saw-version)
           (if (equal line nelix-aot-manifest-engine-version)
               (setq saw-version t)
             (nelix-aot--error "unsupported or missing protocol version"))
         (cond
          ((nelix-aot--line-prefix-p "manifest\t" line)
           (setq manifest (nelix-aot--after-prefix "manifest\t" line)))
          ((nelix-aot--line-prefix-p "source-file\t" line)
           nil)
          ((nelix-aot--line-prefix-p "profile\t" line)
           (setq profile (nelix-aot--after-prefix "profile\t" line)))
          ((nelix-aot--line-prefix-p "system\t" line)
           (setq system (nelix-aot--after-prefix "system\t" line)))
          ((nelix-aot--line-prefix-p "backend\t" line)
           (setq backend (nelix-aot--after-prefix "backend\t" line)))
          ((nelix-aot--line-prefix-p "target-id\t" line)
           (let* ((start (length "target-id\t"))
                  (tab (nelix-aot--tab-index line start))
                  (display-id (and tab
                                   (nelix-aot--parse-positive-int-range
                                    line start tab)))
                  (candidate-ids
                   (and tab (nelix-aot--ids-from-line-tail line (1+ tab)))))
             (when (and display-id candidate-ids)
               (push (cons display-id candidate-ids) target-ids))))
          ((nelix-aot--line-prefix-p "pin-id\t" line)
           (let ((id (nelix-aot--parse-positive-int-line-tail
                      line (length "pin-id\t"))))
             (when id
               (push id pin-ids))))
          ((nelix-aot--line-prefix-p "installed-id\t" line)
           (let ((id (nelix-aot--parse-positive-int-line-tail
                      line (length "installed-id\t"))))
             (when id
               (push id installed-ids)
               (when last-installed
                 (push (cons id last-installed) installed-id-names))
               (setq last-installed nil))))
          ((nelix-aot--line-prefix-p "name-id\t" line)
           (let* ((start (length "name-id\t"))
                  (tab (nelix-aot--tab-index line start))
                  (id (and tab
                           (nelix-aot--parse-positive-int-range
                            line start tab)))
                  (name (and tab (substring line (1+ tab)))))
             (when (and id (stringp name) (> (length name) 0))
               (push (cons id name) name-ids))))
          ((nelix-aot--line-prefix-p "installed\t" line)
           (setq last-installed (nelix-aot--after-prefix "installed\t" line))
           (push last-installed installed))
          ((nelix-aot--line-prefix-p "pin\t" line)
           (push (nelix-aot--after-prefix "pin\t" line) pins))
          ((nelix-aot--line-prefix-p "target\t" line)
           (let* ((start (length "target\t"))
                  (tab (nelix-aot--tab-index line start))
                  (display (and tab (substring line start tab)))
                  (candidates
                   (and tab (nelix-aot--strings-from-line-tail
                             line (1+ tab)))))
             (unless (and display candidates)
               (nelix-aot--error "target record requires display and candidates"))
             (push (cons display candidates) targets)))
          ((equal line "end")
           (setq ended t))
          (t
           (let ((tab (nelix-aot--tab-index line 0)))
             (nelix-aot--error
              (format "unknown record %S"
                      (if tab (substring line 0 tab) line)))))))))
    (unless saw-version
      (nelix-aot--error "unsupported or missing protocol version"))
    (unless ended
      (nelix-aot--error "missing end record"))
    (list :manifest manifest
          :profile profile
          :system system
          :backend backend
          :targets (nreverse targets)
          :target-ids (nreverse target-ids)
          :pins (nreverse pins)
          :pin-ids (nreverse pin-ids)
          :installed (nreverse installed)
          :installed-ids (nreverse installed-ids)
          :installed-id-names (nreverse installed-id-names)
          :name-ids (nreverse name-ids))))

(defun nelix-aot--name-member-p (name names)
  "Return non-nil when NAME or its normalized form is present in NAMES."
  (or (member name names)
      (member (nelix-aot--strip-duplicate-suffix name) names)))

(defun nelix-aot--name-set (names)
  "Return a hash set containing NAMES and duplicate-suffix aliases."
  (let ((set (make-hash-table :test 'equal)))
    (dolist (name names set)
      (when (and (stringp name) (> (length name) 0))
        (puthash name t set)
        (puthash (nelix-aot--strip-duplicate-suffix name) t set)))))

(defun nelix-aot--name-map (names)
  "Return a hash map from exact NAMES to installed names."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (name names map)
      (when (and (stringp name) (> (length name) 0))
        (puthash name name map)))))

(defun nelix-aot--normalized-name-map (names)
  "Return a hash map from duplicate-suffix aliases to installed NAMES."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (name names map)
      (when (and (stringp name) (> (length name) 0))
        (let ((normalized (nelix-aot--strip-duplicate-suffix name)))
          (unless (equal normalized name)
            (puthash normalized name map)))))))

(defun nelix-aot--set-add-name (set name)
  "Add NAME and its duplicate-suffix alias to SET."
  (when (and (stringp name) (> (length name) 0))
    (puthash name t set)
    (puthash (nelix-aot--strip-duplicate-suffix name) t set))
  set)

(defun nelix-aot--set-has-name-p (set name)
  "Return non-nil when SET contains NAME or its normalized alias."
  (or (gethash name set)
      (gethash (nelix-aot--strip-duplicate-suffix name) set)))

(defun nelix-aot--find-installed (candidates installed-map
                                             &optional normalized-map)
  "Return the installed name matching CANDIDATES.

Exact profile-name matches in INSTALLED-MAP win before duplicate-suffix
fallback matches in NORMALIZED-MAP."
  (let ((found nil))
    (dolist (candidate candidates found)
      (when (and (null found) (gethash candidate installed-map))
        (setq found (gethash candidate installed-map))))
    (when (and (null found) normalized-map)
      (dolist (candidate candidates found)
        (when (and (null found) (gethash candidate normalized-map))
          (setq found (gethash candidate normalized-map)))))
    found))

(defun nelix-aot--id-map (entries)
  "Return a hash map built from integer ID ENTRIES."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (entry entries map)
      (puthash (car entry) (cdr entry) map))))

(defun nelix-aot--id-set (ids)
  "Return a hash set built from integer IDS."
  (let ((set (make-hash-table :test 'equal)))
    (dolist (id ids set)
      (puthash id t set))))

(defun nelix-aot--id-set-add-list (set ids)
  "Add IDS to SET."
  (dolist (id ids set)
    (puthash id t set)))

(defun nelix-aot--first-installed-id (candidate-ids installed-set)
  "Return the first candidate ID present in INSTALLED-SET."
  (let (found)
    (dolist (id candidate-ids found)
      (when (and (null found) (gethash id installed-set))
        (setq found id)))))

(defun nelix-aot--id-name (id id-name-map)
  "Return the canonical package name for ID."
  (or (gethash id id-name-map)
      (number-to-string id)))

(defun nelix-aot--installed-id-name (id id-name-map installed-id-name-map)
  "Return the installed display name for ID."
  (or (gethash id installed-id-name-map)
      (nelix-aot--id-name id id-name-map)))

(defun nelix-aot--id-list-names (ids id-name-map)
  "Return package names for IDS."
  (let (names)
    (dolist (id ids (nreverse names))
      (push (nelix-aot--id-name id id-name-map) names))))

(defun nelix-aot--id-desired-name-set (target-ids id-name-map)
  "Return a string set for TARGET-IDS candidate names."
  (let ((set (make-hash-table :test 'equal)))
    (dolist (target target-ids set)
      (dolist (id (cdr target))
        (nelix-aot--set-add-name set (nelix-aot--id-name id id-name-map))))))

(defun nelix-aot--installed-id-name-set (installed-id-names)
  "Return a string set for installed names that had an installed-id record."
  (let ((set (make-hash-table :test 'equal)))
    (dolist (entry installed-id-names set)
      (nelix-aot--set-add-name set (cdr entry)))))

(defun nelix-aot--audit-id-report (input)
  "Return audit lists using numeric ID records when available."
  (let ((target-ids (plist-get input :target-ids))
        (name-ids (plist-get input :name-ids)))
    (when (and target-ids name-ids)
      (let* ((id-name-map (nelix-aot--id-map name-ids))
             (installed-id-name-map
              (nelix-aot--id-map (plist-get input :installed-id-names)))
             (installed-set (nelix-aot--id-set
                             (plist-get input :installed-ids)))
             (desired-id-set (make-hash-table :test 'equal))
             (desired-name-set
              (nelix-aot--id-desired-name-set target-ids id-name-map))
             (mapped-installed-name-set
              (nelix-aot--installed-id-name-set
               (plist-get input :installed-id-names)))
             present
             missing
             extra)
        (dolist (target target-ids)
          (nelix-aot--id-set-add-list desired-id-set (cdr target))
          (let ((actual-id (nelix-aot--first-installed-id
                            (cdr target)
                            installed-set)))
            (if actual-id
                (setq present
                      (nelix-aot--cons-unique
                       (nelix-aot--installed-id-name
                        actual-id id-name-map installed-id-name-map)
                       present))
              (setq missing
                    (nelix-aot--cons-unique
                     (nelix-aot--id-name (car target) id-name-map)
                     missing)))))
        (dolist (id (plist-get input :installed-ids))
          (unless (gethash id desired-id-set)
            (setq extra
                  (nelix-aot--cons-unique
                   (nelix-aot--installed-id-name
                    id id-name-map installed-id-name-map)
                   extra))))
        (dolist (name (plist-get input :installed))
          (unless (or (nelix-aot--set-has-name-p mapped-installed-name-set name)
                      (nelix-aot--set-has-name-p desired-name-set name))
            (setq extra (nelix-aot--cons-unique name extra))))
        (list :present (nreverse present)
              :missing (nreverse missing)
              :extra (nreverse extra))))))

(defun nelix-aot--audit-string-report (input)
  "Return audit lists using string records."
  (let* ((installed (plist-get input :installed))
         (installed-map (nelix-aot--name-map installed))
         (normalized-installed-map
          (nelix-aot--normalized-name-map installed))
         (desired (make-hash-table :test 'equal))
         present
         missing
         extra)
    (dolist (target (plist-get input :targets))
      (let ((actual (nelix-aot--find-installed
                     (cdr target)
                     installed-map
                     normalized-installed-map)))
        (if actual
            (setq present (nelix-aot--cons-unique actual present))
          (setq missing (nelix-aot--cons-unique (car target) missing))))
      (dolist (candidate (cdr target))
        (nelix-aot--set-add-name desired candidate)))
    (dolist (name installed)
      (unless (nelix-aot--set-has-name-p desired name)
        (push name extra)))
    (list :present (nreverse present)
          :missing (nreverse missing)
          :extra (nreverse extra))))

(defun nelix-aot--audit-report (input)
  "Return audit lists, preferring numeric ID records."
  (or (nelix-aot--audit-id-report input)
      (nelix-aot--audit-string-report input)))

(defun nelix-aot--upgrade-id-report (input)
  "Return upgrade-plan lists using numeric ID records when available."
  (let ((target-ids (plist-get input :target-ids))
        (name-ids (plist-get input :name-ids)))
    (when (and target-ids name-ids)
      (let* ((id-name-map (nelix-aot--id-map name-ids))
             (installed-id-name-map
              (nelix-aot--id-map (plist-get input :installed-id-names)))
             (installed-set (nelix-aot--id-set
                             (plist-get input :installed-ids)))
             (pin-set (nelix-aot--id-set (plist-get input :pin-ids)))
             upgrade
             pinned
             missing)
        (dolist (target target-ids)
          (let ((actual-id (nelix-aot--first-installed-id
                            (cdr target)
                            installed-set)))
        (cond
         ((null actual-id)
          (setq missing
                (nelix-aot--cons-unique
                 (nelix-aot--id-name (car target) id-name-map)
                 missing)))
         ((gethash actual-id pin-set)
          (setq pinned
                (nelix-aot--cons-unique
                 (nelix-aot--installed-id-name
                  actual-id id-name-map installed-id-name-map)
                 pinned)))
         (t
          (setq upgrade
                (nelix-aot--cons-unique
                 (nelix-aot--installed-id-name
                  actual-id id-name-map installed-id-name-map)
                 upgrade))))))
        (list :upgrade (nreverse upgrade)
              :pinned (nreverse pinned)
              :pinned-names (nelix-aot--id-list-names
                             (plist-get input :pin-ids)
                             id-name-map)
              :missing (nreverse missing))))))

(defun nelix-aot--upgrade-string-report (input)
  "Return upgrade-plan lists using string records."
  (let* ((installed (plist-get input :installed))
         (installed-map (nelix-aot--name-map installed))
         (normalized-installed-map
          (nelix-aot--normalized-name-map installed))
         (pins (plist-get input :pins))
         (pin-set (nelix-aot--name-set pins))
         upgrade
         pinned
         missing)
    (dolist (target (plist-get input :targets))
      (let ((actual (nelix-aot--find-installed
                     (cdr target)
                     installed-map
                     normalized-installed-map)))
        (cond
         ((null actual)
          (setq missing (nelix-aot--cons-unique (car target) missing)))
         ((nelix-aot--set-has-name-p pin-set actual)
          (setq pinned (nelix-aot--cons-unique actual pinned)))
         (t
          (setq upgrade (nelix-aot--cons-unique actual upgrade))))))
    (list :upgrade (nreverse upgrade)
          :pinned (nreverse pinned)
          :pinned-names pins
          :missing (nreverse missing))))

(defun nelix-aot--upgrade-report (input)
  "Return upgrade-plan lists, preferring numeric ID records."
  (or (nelix-aot--upgrade-id-report input)
      (nelix-aot--upgrade-string-report input)))

(defun nelix-aot--json-escape-string (string)
  "Return STRING escaped as a JSON string body."
  (let ((i 0)
        (len (length string))
        (needs-escape nil))
    (while (and (< i len) (null needs-escape))
      (let ((ch (aref string i)))
        (when (or (eq ch ?\\)
                  (eq ch ?\")
                  (eq ch ?\n)
                  (eq ch ?\r)
                  (eq ch ?\t))
          (setq needs-escape t)))
      (setq i (1+ i)))
    (if needs-escape
        (nelix-aot--json-escape-string-slow string)
      string)))

(defun nelix-aot--json-escape-string-slow (string)
  "Return STRING escaped as a JSON string body using the slow path."
  (let ((i 0)
        (len (length string))
        (out ""))
    (while (< i len)
      (let ((ch (aref string i)))
        (setq out
              (concat out
                      (cond
                       ((eq ch ?\\) "\\\\")
                       ((eq ch ?\") "\\\"")
                       ((eq ch ?\n) "\\n")
                       ((eq ch ?\r) "\\r")
                       ((eq ch ?\t) "\\t")
                       (t (char-to-string ch))))))
      (setq i (1+ i)))
    out))

(defun nelix-aot--json-string (value)
  "Return VALUE encoded as a JSON string."
  (concat "\"" (nelix-aot--json-escape-string (or value "")) "\""))

(defun nelix-aot--json-bool (value)
  "Return VALUE encoded as a JSON boolean."
  (if value "true" "false"))

(defun nelix-aot--json-nullable-string (value)
  "Return VALUE encoded as a JSON string or null."
  (if value
      (nelix-aot--json-string value)
    "null"))

(defun nelix-aot--json-string-list (values)
  "Return VALUES encoded as a JSON string array."
  (let ((out "[")
        (first t))
    (while values
      (unless first
        (setq out (concat out ",")))
      (setq out (concat out (nelix-aot--json-string (car values))))
      (setq first nil)
      (setq values (cdr values)))
    (concat out "]")))

(defun nelix-aot--json-skipped-object (pairs)
  "Return PAIRS encoded as a JSON object with string values."
  (let ((out "{")
        (first t))
    (while pairs
      (unless first
        (setq out (concat out ",")))
      (setq out
            (concat out
                    (nelix-aot--json-string
                     (substring (symbol-name (car pairs)) 1))
                    ":"
                    (nelix-aot--json-string
                     (symbol-name (cadr pairs)))))
      (setq first nil)
      (setq pairs (cddr pairs)))
    (concat out "}")))

(defun nelix-aot--json-backend-fields (input fallback cache-file)
  "Return backend JSON fields for INPUT, FALLBACK, and CACHE-FILE."
  (let ((backend (or (plist-get input :backend) "nix")))
    (concat
     ",\"backend\":" (nelix-aot--json-string backend)
     ",\"backend-selection\":{"
     "\"backend\":" (nelix-aot--json-string backend) ","
     "\"system\":" (nelix-aot--json-nullable-string
                    (plist-get input :system))
     (if fallback
         (concat ",\"fallback\":" (nelix-aot--json-string fallback))
       "")
     "}"
     (if cache-file
         (concat ",\"aot-cache\":" (nelix-aot--json-string cache-file))
       ""))))

(defun nelix-aot--line-bool (value)
  "Return VALUE as a compact line-protocol boolean string."
  (if value "true" "false"))

(defun nelix-aot--line-value (value)
  "Return VALUE for compact line output."
  (or value ""))

(defun nelix-aot--line-field (key value)
  "Return one compact tab-separated line for KEY and VALUE."
  (concat key "\t" (nelix-aot--line-value value) "\n"))

(defun nelix-aot--name-lines (key values)
  "Return compact tab-separated lines for KEY and each name in VALUES."
  (let ((out ""))
    (dolist (value values)
      (setq out (concat out (nelix-aot--line-field key value))))
    out))

(defun nelix-aot-audit (input-text)
  "Return compact audit data for INPUT-TEXT."
  (let* ((input (nelix-aot--parse-input input-text))
         (report (nelix-aot--audit-report input))
         (present (plist-get report :present))
         (missing (plist-get report :missing))
         (extra (plist-get report :extra)))
    (list :ok (and (null missing) (null extra))
          :manifest (plist-get input :manifest)
          :profile (plist-get input :profile)
          :system (plist-get input :system)
          :present present
          :missing missing
          :extra extra
          :skipped '(:state-pins :nelisp-aot
                     :lock-drift :nelisp-aot
                     :linux-command-audit :nelisp-aot))))

(defun nelix-aot-audit-json (input-text &optional fallback cache-file)
  "Return compact audit JSON for INPUT-TEXT.
FALLBACK and CACHE-FILE are diagnostic values written without building the
generic CLI plist report."
  (let* ((input (nelix-aot--parse-input input-text))
         (report (nelix-aot--audit-report input))
         (present (plist-get report :present))
         (missing (plist-get report :missing))
         (extra (plist-get report :extra)))
    (concat
     "{\"ok\":" (nelix-aot--json-bool (and (null missing) (null extra)))
     ",\"manifest\":" (nelix-aot--json-nullable-string
                       (plist-get input :manifest))
     ",\"profile\":" (nelix-aot--json-nullable-string
                      (plist-get input :profile))
     ",\"system\":" (nelix-aot--json-nullable-string
                     (plist-get input :system))
     ",\"present\":" (nelix-aot--json-string-list present)
     ",\"missing\":" (nelix-aot--json-string-list missing)
     ",\"extra\":" (nelix-aot--json-string-list extra)
     ",\"skipped\":"
     (nelix-aot--json-skipped-object
      '(:state-pins :nelisp-aot
        :lock-drift :nelisp-aot
        :linux-command-audit :nelisp-aot))
     (nelix-aot--json-backend-fields input fallback cache-file)
     "}")))

(defun nelix-aot-audit-lines (input-text &optional fallback cache-file)
  "Return compact audit line output for INPUT-TEXT.
FALLBACK and CACHE-FILE are diagnostic values written without building the
generic CLI plist report or JSON object."
  (let* ((input (nelix-aot--parse-input input-text))
         (report (nelix-aot--audit-report input))
         (present (plist-get report :present))
         (missing (plist-get report :missing))
         (extra (plist-get report :extra)))
    (concat
     (nelix-aot--line-field "ok" (nelix-aot--line-bool
                                  (and (null missing) (null extra))))
     (nelix-aot--line-field "manifest" (plist-get input :manifest))
     (nelix-aot--line-field "profile" (plist-get input :profile))
     (nelix-aot--line-field "system" (plist-get input :system))
     (nelix-aot--name-lines "present" present)
     (nelix-aot--name-lines "missing" missing)
     (nelix-aot--name-lines "extra" extra)
     (nelix-aot--line-field "backend" (or (plist-get input :backend) "nix"))
     (if fallback
         (nelix-aot--line-field "fallback" fallback)
       "")
     (if cache-file
         (nelix-aot--line-field "aot-cache" cache-file)
       ""))))

(defun nelix-aot-upgrade-plan (input-text)
  "Return compact upgrade-plan data for INPUT-TEXT."
  (let* ((input (nelix-aot--parse-input input-text))
         (report (nelix-aot--upgrade-report input))
         (upgrade (plist-get report :upgrade))
         (pinned (plist-get report :pinned))
         (pinned-names (plist-get report :pinned-names))
         (missing (plist-get report :missing)))
    (list :operation 'upgrade
          :name :manifest
          :count (length upgrade)
          :upgrade upgrade
          :pinned pinned
          :pinned-names pinned-names
          :blocked nil
          :empty (null upgrade)
          :manifest (plist-get input :manifest)
          :profile (plist-get input :profile)
          :system (plist-get input :system)
          :missing missing
          :extra nil
          :lock-drift nil
          :skipped '(:extra-scan :nelisp-aot
                     :lock-drift :nelisp-aot
                     :state-pins :nelisp-aot))))

(defun nelix-aot-upgrade-plan-json (input-text &optional fallback cache-file)
  "Return compact upgrade-plan JSON for INPUT-TEXT.
FALLBACK and CACHE-FILE are diagnostic values written without building the
generic CLI plist report."
  (let* ((input (nelix-aot--parse-input input-text))
         (report (nelix-aot--upgrade-report input))
         (upgrade (plist-get report :upgrade))
         (pinned (plist-get report :pinned))
         (pinned-names (plist-get report :pinned-names))
         (missing (plist-get report :missing)))
    (concat
     "{\"operation\":\"upgrade\""
     ",\"name\":\":manifest\""
     ",\"count\":" (number-to-string (length upgrade))
     ",\"upgrade\":" (nelix-aot--json-string-list upgrade)
     ",\"pinned\":" (nelix-aot--json-string-list pinned)
     ",\"pinned-names\":" (nelix-aot--json-string-list pinned-names)
     ",\"blocked\":null"
     ",\"empty\":" (nelix-aot--json-bool (null upgrade))
     ",\"manifest\":" (nelix-aot--json-nullable-string
                       (plist-get input :manifest))
     ",\"profile\":" (nelix-aot--json-nullable-string
                      (plist-get input :profile))
     ",\"system\":" (nelix-aot--json-nullable-string
                     (plist-get input :system))
     ",\"missing\":" (nelix-aot--json-string-list missing)
     ",\"extra\":null"
     ",\"lock-drift\":null"
     ",\"skipped\":"
     (nelix-aot--json-skipped-object
      '(:extra-scan :nelisp-aot
        :lock-drift :nelisp-aot
        :state-pins :nelisp-aot))
     (nelix-aot--json-backend-fields input fallback cache-file)
     "}")))

(defun nelix-aot-upgrade-plan-lines (input-text &optional fallback cache-file)
  "Return compact upgrade-plan line output for INPUT-TEXT.
FALLBACK and CACHE-FILE are diagnostic values written without building the
generic CLI plist report or JSON object."
  (let* ((input (nelix-aot--parse-input input-text))
         (report (nelix-aot--upgrade-report input))
         (upgrade (plist-get report :upgrade))
         (pinned (plist-get report :pinned))
         (pinned-names (plist-get report :pinned-names))
         (missing (plist-get report :missing)))
    (concat
     (nelix-aot--line-field "operation" "upgrade")
     (nelix-aot--line-field "name" ":manifest")
     (nelix-aot--line-field "count" (number-to-string (length upgrade)))
     (nelix-aot--line-field "empty" (nelix-aot--line-bool (null upgrade)))
     (nelix-aot--line-field "manifest" (plist-get input :manifest))
     (nelix-aot--line-field "profile" (plist-get input :profile))
     (nelix-aot--line-field "system" (plist-get input :system))
     (nelix-aot--name-lines "upgrade" upgrade)
     (nelix-aot--name-lines "pinned" pinned)
     (nelix-aot--name-lines "pinned-name" pinned-names)
     (nelix-aot--name-lines "missing" missing)
     (nelix-aot--line-field "backend" (or (plist-get input :backend) "nix"))
     (if fallback
         (nelix-aot--line-field "fallback" fallback)
       "")
     (if cache-file
         (nelix-aot--line-field "aot-cache" cache-file)
       ""))))

(defun nelix-aot-list (profile-names-text)
  "Return newline-separated profile names from PROFILE-NAMES-TEXT."
  (nelix-aot--parse-lines profile-names-text))

(defun nelix-aot-list-lines (profile-names-text)
  "Return compact line output for PROFILE-NAMES-TEXT."
  (let ((names (nelix-aot--parse-lines profile-names-text))
        (out ""))
    (dolist (name names out)
      (setq out (concat out name "\n")))))

(defun nelix-aot-list-json (profile-names-text)
  "Return compact JSON output for PROFILE-NAMES-TEXT."
  (nelix-aot--json-string-list
   (nelix-aot--parse-lines profile-names-text)))

(provide 'nelix-aot-manifest-engine)

;;; nelix-aot-manifest-engine.el ends here
