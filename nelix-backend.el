;;; nelix-backend.el --- Nelix backend protocol -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Backend protocol and capability registry for Doc 22.  This is deliberately
;; conservative: Nix remains available, while `nelix-native' can install
;; hash-verified registry recipes into the native store.

;;; Code:

(require 'cl-lib)
(require 'anvil-pkg)
(require 'anvil-pkg-compat)
(require 'nelix-store)
(require 'nelix-registry)
(require 'nelix-builder)

(defgroup nelix-backend nil
  "Nelix backend dispatch."
  :group 'anvil-pkg
  :prefix "nelix-backend-")

(defcustom nelix-backend-policy
  '((gnu/linux . (nelix-native nix apt git elpa))
    (darwin . (nelix-native nix homebrew git elpa))
    (windows-nt . (nelix-native scoop winget git elpa)))
  "Ordered backend policy by `system-type'."
  :type '(alist :key-type symbol :value-type (repeat symbol))
  :group 'nelix-backend)

(defvar nelix-backend--capabilities
  (let ((table (make-hash-table :test 'eq)))
    (puthash
     'nix
     '(:backend nix
       :systems (x86_64-linux aarch64-linux x86_64-darwin aarch64-darwin)
       :fetchers (nixpkgs flake)
       :store t
       :generations t
       :rollback t
       :build t
       :binary-substitutes t
       :requires-program "nix")
     table)
    (puthash
     'nelix-native
     '(:backend nelix-native
       :systems (x86_64-linux aarch64-linux x86_64-darwin aarch64-darwin
                 x86_64-windows)
       :fetchers (url git github-release elpa)
       :store t
       :generations t
       :rollback t
       :build nil
       :binary-substitutes t)
     table)
    (puthash
     'git
     '(:backend git
       :systems (x86_64-linux aarch64-linux x86_64-darwin aarch64-darwin
                 x86_64-windows)
       :fetchers (git)
       :store nil
       :generations nil
       :rollback nil
       :build nil
       :binary-substitutes nil
       :requires-program "git")
     table)
    (puthash 'elpa '(:backend elpa :systems t :fetchers (elpa)
                     :store nil :generations nil :rollback nil :build nil)
             table)
    (puthash 'apt '(:backend apt :systems (x86_64-linux aarch64-linux)
                    :store nil :generations nil :rollback nil :build nil
                    :requires-program "apt")
             table)
    (puthash 'homebrew '(:backend homebrew
                         :systems (x86_64-darwin aarch64-darwin)
                         :store nil :generations nil :rollback nil :build nil
                         :requires-program "brew")
             table)
    (puthash 'scoop '(:backend scoop :systems (x86_64-windows)
                      :store nil :generations nil :rollback nil :build nil
                      :requires-program "scoop")
             table)
    (puthash 'winget '(:backend winget :systems (x86_64-windows)
                       :store nil :generations nil :rollback nil :build nil
                       :requires-program "winget")
             table)
    table)
  "Backend capability registry.")

;;;###autoload
(defun nelix-backend-register (name capabilities)
  "Register backend NAME with CAPABILITIES."
  (unless (symbolp name)
    (signal 'anvil-pkg-error
            (list (format "nelix-backend-register: NAME must be symbol, got %S"
                          name))))
  (puthash name
           (plist-put (copy-sequence capabilities) :backend name)
           nelix-backend--capabilities))

;;;###autoload
(defun nelix-backend-capabilities (&optional backend)
  "Return capability plist for BACKEND, or all backend capabilities."
  (if backend
      (gethash backend nelix-backend--capabilities)
    (let (rows)
      (maphash (lambda (_name caps) (push caps rows))
               nelix-backend--capabilities)
      (sort rows (lambda (a b)
                   (string< (symbol-name (plist-get a :backend))
                            (symbol-name (plist-get b :backend))))))))

;;;###autoload
(defun nelix-current-system ()
  "Return Nelix system triple for the current runtime."
  (let* ((config (or (and (boundp 'system-configuration)
                          system-configuration)
                     ""))
         (arch (cond
                ((string-match-p "\\(aarch64\\|arm64\\)" config) 'aarch64)
                ((string-match-p "\\(x86_64\\|amd64\\)" config) 'x86_64)
                (t 'x86_64))))
    (cond
     ((eq system-type 'darwin)
      (if (eq arch 'aarch64) 'aarch64-darwin 'x86_64-darwin))
     ((eq system-type 'windows-nt)
      'x86_64-windows)
     (t
      (if (eq arch 'aarch64) 'aarch64-linux 'x86_64-linux)))))

;;;###autoload
(defun nelix-backend-policy-for-os (&optional os)
  "Return ordered backend list for OS or current `system-type'."
  (or (cdr (assq (or os system-type) nelix-backend-policy))
      '(nelix-native git elpa)))

(defun nelix-backend--supports-system-p (capabilities system)
  "Return non-nil when CAPABILITIES support SYSTEM."
  (let ((systems (plist-get capabilities :systems)))
    (or (eq systems t)
        (memq system systems))))

(defun nelix-backend--string-list (items)
  "Return ITEMS normalized to strings."
  (cond
   ((null items) nil)
   ((listp items)
    (mapcar (lambda (item)
              (cond
               ((stringp item) item)
               ((symbolp item) (symbol-name item))
               (t (format "%S" item))))
            items))
   ((stringp items) (list items))
   ((symbolp items) (list (symbol-name items)))
   (t (list (format "%S" items)))))

(defun nelix-backend--version-segments (version)
  "Return numeric-ish segments for VERSION.
This fallback is intentionally conservative and is only used when
Emacs's `version<' is unavailable."
  (mapcar (lambda (part)
            (if (string-match-p "\\`[0-9]+\\'" part)
                (string-to-number part)
              part))
          (split-string (or version "") "[^0-9A-Za-z]+" t)))

(defun nelix-backend--fallback-version< (a b)
  "Return non-nil when version string A is older than B."
  (let ((left (nelix-backend--version-segments a))
        (right (nelix-backend--version-segments b))
        decided)
    (while (and (not decided)
                (or left right))
      (let ((x (or (car left) 0))
            (y (or (car right) 0)))
        (cond
         ((and (numberp x) (numberp y) (< x y))
          (setq decided 'less))
         ((and (numberp x) (numberp y) (> x y))
          (setq decided 'greater))
         ((string< (format "%s" x) (format "%s" y))
          (setq decided 'less))
         ((string< (format "%s" y) (format "%s" x))
          (setq decided 'greater))))
      (setq left (cdr left)
            right (cdr right)))
    (eq decided 'less)))

(defun nelix-backend--version-newer-p (installed candidate)
  "Return non-nil when CANDIDATE is newer than INSTALLED."
  (and (stringp installed)
       (stringp candidate)
       (not (equal installed candidate))
       (if (fboundp 'version<)
           (version< installed candidate)
         (nelix-backend--fallback-version< installed candidate))))

(defun nelix-backend--native-profile-entries (&optional profile-name)
  "Return current native profile entries for PROFILE-NAME, or nil."
  (condition-case _
      (plist-get (nelix-profile-read (or profile-name
                                         nelix-builder-default-profile))
                 :entries)
    (error nil)))

(defun nelix-backend--entry-by-name (name entries)
  "Return native profile entry NAME from ENTRIES."
  (let (found)
    (dolist (entry entries found)
      (when (and (null found)
                 (equal name (plist-get entry :name)))
        (setq found entry)))))

(defun nelix-backend--native-upgrade-row (name entry pins)
  "Return one native upgrade-plan row for NAME and ENTRY."
  (let* ((recipe (nelix-registry-get name))
         (installed-version (plist-get entry :version))
         (candidate-version (plist-get recipe :version)))
    (cond
     ((member name pins)
      (list :name name
            :entry entry
            :recipe recipe
            :blocked :pinned))
     ((null entry)
      (list :name name
            :entry nil
            :recipe recipe
            :blocked :missing))
     ((null recipe)
      (list :name name
            :entry entry
            :recipe nil
            :blocked :missing-registry-recipe))
     ((nelix-backend--version-newer-p installed-version candidate-version)
      (list :name name
            :from installed-version
            :to candidate-version
            :entry entry
            :recipe recipe))
     (t
      (list :name name
            :from installed-version
            :to candidate-version
            :entry entry
            :recipe recipe
            :blocked :up-to-date)))))

(defun nelix-backend--native-upgrade-plan (&optional targets profile-name)
  "Return a read-only native upgrade plan for TARGETS."
  (let* ((entries (nelix-backend--native-profile-entries profile-name))
         (pins (nelix-list-pins))
         (names (if targets
                    (nelix-backend--string-list targets)
                  (mapcar (lambda (entry) (plist-get entry :name)) entries)))
         upgrade pinned missing blocked current rows)
    (dolist (name names)
      (let* ((entry (nelix-backend--entry-by-name name entries))
             (row (nelix-backend--native-upgrade-row name entry pins))
             (reason (plist-get row :blocked)))
        (push row rows)
        (cond
         ((null reason) (push row upgrade))
         ((eq reason :pinned) (push row pinned))
         ((eq reason :missing) (push row missing))
         ((eq reason :up-to-date) (push row current))
         (t (push row blocked)))))
    (list :operation 'upgrade
          :backend 'nelix-native
          :profile (or profile-name nelix-builder-default-profile)
          :targets targets
          :count (length upgrade)
          :upgrade (nreverse upgrade)
          :pinned (nreverse pinned)
          :missing (nreverse missing)
          :blocked (nreverse blocked)
          :current (nreverse current)
          :rows (nreverse rows)
          :empty (null upgrade))))

(defun nelix-backend--native-recipe-systems (recipe)
  "Return supported system symbols declared by native RECIPE."
  (let (systems)
    (dolist (entry (plist-get recipe :systems) (nreverse systems))
      (when (consp entry)
        (push (car entry) systems)))))

(defun nelix-backend--native-target-system-report (targets system)
  "Return native registry system support report for TARGETS on SYSTEM."
  (let ((supported nil)
        (unsupported nil)
        (missing nil))
    (dolist (name (nelix-backend--string-list targets))
      (let ((recipe (nelix-registry-get name)))
        (cond
         ((null recipe)
          (push (list :name name
                      :system system
                      :reason :missing-registry-recipe)
                missing))
         ((nelix-registry--recipe-system-supported-p recipe system)
          (push (list :name name
                      :version (plist-get recipe :version)
                      :system system)
                supported))
         (t
          (push (list :name name
                      :version (plist-get recipe :version)
                      :system system
                      :supported-systems
                      (nelix-backend--native-recipe-systems recipe)
                      :reason :unsupported-system)
                unsupported)))))
    (list :system system
          :supported (nreverse supported)
          :unsupported (nreverse unsupported)
          :missing-registry-recipes (nreverse missing))))

;;;###autoload
(defun nelix-backend-available-p (backend &optional system)
  "Return non-nil when BACKEND is usable for SYSTEM."
  (let ((caps (nelix-backend-capabilities backend))
        (system* (or system (nelix-current-system))))
    (and caps
         (nelix-backend--supports-system-p caps system*)
         (let ((program (plist-get caps :requires-program)))
           (or (null program)
               (anvil-pkg-compat-executable-find program))))))

;;;###autoload
(defun nelix-backend-select (&optional target system policy)
  "Select a backend for TARGET on SYSTEM using POLICY.

TARGET is currently informational; later resolver phases will use
registry recipes to choose target-specific backends."
  (let ((system* (or system (nelix-current-system)))
        (policy* (or policy (nelix-backend-policy-for-os)))
        selected skipped)
    (dolist (backend policy*)
      (if (and (null selected)
               (nelix-backend-available-p backend system*))
          (setq selected backend)
        (push backend skipped)))
    (list :target target
          :system system*
          :backend selected
          :policy policy*
          :skipped (nreverse skipped)
          :available (and selected t))))

;;;###autoload
(defun nelix-backend-install (backend targets &optional profile-name system)
  "Install TARGETS through BACKEND.

PROFILE-NAME and SYSTEM are used by backends with native profiles."
  (pcase backend
    ('nix (nelix-install targets))
    ('nelix-native
     (mapcar (lambda (target)
               (nelix-native-install target profile-name system))
             (if (listp targets) targets (list targets))))
    (_
     (signal 'anvil-pkg-error
             (list (format "nelix-backend-install: unsupported backend %S"
                           backend))))))

;;;###autoload
(defun nelix-backend-list (backend)
  "List installed entries for BACKEND."
  (pcase backend
    ('nix (nelix-list))
    ('nelix-native
     (list :store (nelix-store-list)
           :profiles-root (nelix-profile-root)))
    (_
     (signal 'anvil-pkg-error
             (list (format "nelix-backend-list: unsupported backend %S"
                           backend))))))

;;;###autoload
(defun nelix-backend-upgrade-plan (backend &optional targets)
  "Return a read-only upgrade plan for BACKEND and TARGETS."
  (pcase backend
    ('nix (if targets
              (mapcar #'nelix-upgrade-plan targets)
            (nelix-upgrade-plan)))
    ('nelix-native
     (nelix-backend--native-upgrade-plan targets))
    (_
     (signal 'anvil-pkg-error
             (list (format "nelix-backend-upgrade-plan: unsupported backend %S"
                           backend))))))

;;;###autoload
(defun nelix-native-audit (&optional targets)
  "Return a read-only native backend audit report that does not require Nix.

When TARGETS is non-nil, audit whether each requested native recipe supports
the current system.  Unsupported requested recipes are audit errors; recipes
for other platforms that are not requested are allowed to coexist in the
registry."
  (let* ((system (nelix-current-system))
         (caps (nelix-backend-capabilities 'nelix-native))
         (store-report (nelix-store-verify))
         (registry-count (nelix-registry-count))
         (selection (nelix-backend-select nil system '(nelix-native)))
         (target-report (and targets
                             (nelix-backend--native-target-system-report
                              targets system))))
    (list :ok (and caps
                   (plist-get selection :available)
                   (plist-get store-report :ok)
                   (null (plist-get target-report :unsupported)))
          :backend 'nelix-native
          :system system
          :capabilities caps
          :store store-report
          :profile-root (nelix-profile-root)
          :registry (list :count registry-count)
          :targets target-report
          :unsupported-systems (plist-get target-report :unsupported)
          :nix-required nil
          :selection selection)))

(provide 'nelix-backend)
;;; nelix-backend.el ends here
