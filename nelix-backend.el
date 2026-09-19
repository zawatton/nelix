;;; nelix-backend.el --- Nelix backend protocol -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Backend protocol and capability registry for Doc 22.  This is deliberately
;; conservative: Nix remains available, while `nelix-native' can install
;; hash-verified registry recipes into the native store.

;;; Code:

(require 'cl-lib)
(require 'nelix-core)
(require 'nelix-compat)
(require 'nelix-store)
(require 'nelix-registry)
(require 'nelix-builder)

;; Raised when a `system' row names an OS-provided prerequisite that is
;; neither supplied by an acquisition provider nor already present.  Declared
;; via the compat helper rather than `define-error' so the condition chain
;; also works on the NeLisp standalone reader.
(nelix-compat-define-error-symbol
 'nelix-external-dependency
 "nelix external dependency is not satisfied"
 'nelix-error)

(defgroup nelix-backend nil
  "Nelix backend dispatch."
  :group 'nelix-core
  :prefix "nelix-backend-")

(defcustom nelix-backend-policy
  '((gnu/linux . (nelix-native nix apt dnf git elpa))
    (darwin . (nelix-native nix homebrew git elpa))
    (windows-nt . (nelix-native scoop winget git elpa)))
  "Ordered backend policy by `system-type'."
  :type '(alist :key-type symbol :value-type (repeat symbol))
  :group 'nelix-backend)

(defcustom nelix-system-backend-policy
  '(nix)
  "Preferred acquisition backends for `system' package rows.

The default keeps OS-level prerequisites Nix-backed when possible.  This
lets Nelix use Nix substituters for packages such as `mu' without
requiring a separate OS package-manager integration yet."
  :type '(repeat symbol)
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
       ;; Doc 34 shipped the external build lane: `nelix-builder' carries
       ;; the make / cmake / cargo / trivial phase presets, so the native
       ;; backend does build from source.  This flag read `nil' long after
       ;; that landed and was misreported as "native cannot build".
       :build t
       :binary-substitutes t)
     table)
    (puthash
     'system
     '(:backend system
       :systems t
       :fetchers (nixpkgs)
       :store nil
       :generations nil
       :rollback nil
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
    (puthash 'dnf '(:backend dnf :systems (x86_64-linux aarch64-linux)
                    :store nil :generations nil :rollback nil :build nil
                    :requires-program "dnf")
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
    (signal 'nelix-error
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

(defun nelix-backend--system-provider-backend (&optional system)
  "Return the first available backend for system-package acquisition."
  (let ((system* (or system (nelix-current-system)))
        found)
    (dolist (backend nelix-system-backend-policy found)
      (when (and (null found)
                 (not (eq backend 'system))
                 (nelix-backend-available-p backend system*))
        (setq found backend)))))

(defun nelix-backend--system-program-names (targets)
  "Return TARGETS as the list of OS program names they name."
  (delq nil
        (mapcar (lambda (target)
                  (cond
                   ((stringp target) target)
                   ((symbolp target) (symbol-name target))
                   ((consp target)
                    (let ((name (or (plist-get target :system)
                                    (plist-get target :name))))
                      (cond ((stringp name) name)
                            ((symbolp name) (symbol-name name))
                            (t nil))))
                   (t nil)))
                (if (listp targets) targets (list targets)))))

(defun nelix-backend--system-missing-programs (targets)
  "Return the subset of TARGETS' program names absent from PATH."
  (let (missing)
    (dolist (name (nelix-backend--system-program-names targets)
                  (nreverse missing))
      (unless (nelix-compat-executable-find name)
        (push name missing)))))

(defun nelix-backend--external-dependency-message (missing system)
  "Build the operator-facing message for MISSING programs on SYSTEM."
  (format (concat "nelix: %s must be provided by the operating system (%s). "
                  "No acquisition provider in `nelix-system-backend-policy' %S "
                  "is available. Install %s with the OS package manager, or add "
                  "an available provider to that list.")
          (mapconcat (lambda (n) (format "`%s'" n)) missing ", ")
          system
          nelix-system-backend-policy
          (if (cdr missing) "them" "it")))

(defun nelix-backend--system-verify (targets system)
  "Verify TARGETS are present on SYSTEM, or signal an external dependency.

This is the Nix-free lane for `system' rows: when no acquisition
provider is configured or available, Nelix does not install the
prerequisite itself.  It checks whether the OS already provides it and
reports an explicit, actionable dependency when it does not -- which is
what Doc 34 asks for instead of silently falling back to another
package universe."
  (let ((missing (nelix-backend--system-missing-programs targets)))
    (when missing
      (signal 'nelix-external-dependency
              (list (nelix-backend--external-dependency-message missing system)
                    :programs missing
                    :system system
                    :policy nelix-system-backend-policy)))
    (list :backend 'system
          :provider nil
          :satisfied-by 'os
          :programs (nelix-backend--system-program-names targets)
          :targets targets
          :system system)))

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
  (let ((system* (or system (nelix-current-system))))
    (if (eq backend 'system)
        ;; Usable with or without a provider: without one the backend still
        ;; verifies OS presence and reports an explicit dependency, which is
        ;; the Nix-free lane.  Reporting it unavailable here would make
        ;; `nelix-backend-select' skip `system' rows entirely.
        t
      (let ((caps (nelix-backend-capabilities backend)))
        (and caps
             (nelix-backend--supports-system-p caps system*)
             (let ((program (plist-get caps :requires-program)))
               (or (null program)
                   (nelix-compat-executable-find program))))))))

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
    ('system
     (let ((provider (nelix-backend--system-provider-backend system)))
       (if (null provider)
           (nelix-backend--system-verify targets system)
         (list :backend 'system
               :provider provider
               :targets targets
               :profile profile-name
               :system system
               :result (nelix-backend-install provider targets profile-name system)))))
    ('nelix-native
     (mapcar (lambda (target)
               (nelix-native-install target profile-name system))
             (if (listp targets) targets (list targets))))
    (_
     (signal 'nelix-error
             (list (format "nelix-backend-install: unsupported backend %S"
                           backend))))))

;;;###autoload
(defun nelix-backend-list (backend)
  "List installed entries for BACKEND."
  (pcase backend
    ('nix (nelix-list))
    ('system
     (let ((provider (nelix-backend--system-provider-backend)))
       (list :backend 'system
             :provider provider
             :provider-list (and provider
                                 (nelix-backend-list provider)))))
    ('nelix-native
     (list :store (nelix-store-list)
           :profiles-root (nelix-profile-root)))
    (_
     (signal 'nelix-error
             (list (format "nelix-backend-list: unsupported backend %S"
                           backend))))))

;;;###autoload
(defun nelix-backend-upgrade-plan (backend &optional targets)
  "Return a read-only upgrade plan for BACKEND and TARGETS."
  (pcase backend
    ('nix (if targets
              (mapcar #'nelix-upgrade-plan targets)
            (nelix-upgrade-plan)))
    ('system
     (let ((provider (nelix-backend--system-provider-backend)))
       (if (null provider)
           ;; An OS-provided prerequisite is not Nelix's to upgrade.  Report
           ;; that plainly rather than signalling, so one `system' row cannot
           ;; abort an upgrade plan covering every other backend.
           (list :backend 'system
                 :provider nil
                 :external-dependency t
                 :targets targets
                 :provider-plan nil)
         (list :backend 'system
               :provider provider
               :provider-plan (nelix-backend-upgrade-plan provider targets)))))
    ('nelix-native
     (nelix-backend--native-upgrade-plan targets))
    (_
     (signal 'nelix-error
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
