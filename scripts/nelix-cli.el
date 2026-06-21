;;; nelix-cli.el --- Command-line entry point for Nelix -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This file is intentionally thin.  It translates command-line arguments into
;; the public Nelix Elisp APIs and formats the result for humans or agents.

;;; Code:

(require 'cl-lib)
(require 'nelix)
(require 'anvil-pkg-compat)

(defconst nelix-cli-version "0.1.0"
  "Version string reported by the Nelix CLI wrapper.")

(defconst nelix-cli--mutating-commands
  '("apply" "sync" "upgrade" "rollback")
  "Commands that may mutate profile or lock state.")

(defconst nelix-cli--usage
  "Usage:
  nelix [--runtime emacs|nelisp|auto] [--json] COMMAND [ARGS...]

Commands:
  validate MANIFEST
  lock MANIFEST
  lock validate MANIFEST
  lock diff MANIFEST
  lock migrate MANIFEST [--dry-run]
  lock-check MANIFEST
  transaction list [--limit N]
  transaction show ID|FILE
  transaction recover ID|FILE (--dry-run|--execute)
  plan MANIFEST [--dry-run]
  apply MANIFEST [--dry-run] [--locked] [--allow-remove]
                 [--allow-remove-count N] [--no-rollback]
  audit MANIFEST
  sync MANIFEST [--prune] [--locked] [--allow-remove]
                [--allow-remove-count N]
  prune-plan MANIFEST
  aot-cache MANIFEST
  upgrade-plan [MANIFEST|NAME]
  outdated [MANIFEST|NAME] [--backend BACKEND]
  upgrade [MANIFEST|NAME]
  registry update
  registry index ROOT OUTPUT
  registry list [--system SYSTEM]
  registry search QUERY [--system SYSTEM]
  registry show NAME
  native audit
  native install NAME [--profile PROFILE] [--system SYSTEM]
  native remove NAME [--profile PROFILE] [--system SYSTEM]
  native list
  native profile [--profile PROFILE] [--generation GENERATION]
  native activate [--profile PROFILE] [--generation GENERATION]
  native rollback [--profile PROFILE] [--generation GENERATION]
  native gc [--dry-run] [--profile PROFILE]
  list
  rollback [GENERATION]
  doctor
  schema [manifest-dsl-v1|lock-v2|transaction-v1|all]
  help
"
  "CLI usage text.")

(defun nelix-cli-strip-emacs-separator (args)
  "Remove the Emacs `--' separator from ARGS when present."
  (if (and args (equal (car args) "--"))
      (cdr args)
    args))

(defun nelix-cli--take-global-options (args)
  "Return `(OPTIONS . REST)' after reading global ARGS."
  (let ((json nil)
        (help nil)
        (version nil)
        rest)
    (while args
      (let ((arg (car args)))
        (cond
         ((equal arg "--json")
          (setq json t)
          (setq args (cdr args)))
         ((or (equal arg "--help") (equal arg "-h"))
          (setq help t)
          (setq args (cdr args)))
         ((equal arg "--version")
          (setq version t)
          (setq args (cdr args)))
         (t
          (setq rest args)
          (setq args nil)))))
    (cons (list :json json :help help :version version)
          rest)))

(defun nelix-cli-parse-args (args)
  "Parse command-line ARGS into a plist."
  (let* ((clean (nelix-cli-strip-emacs-separator args))
         (split (nelix-cli--take-global-options clean))
         (opts (car split))
         (rest (cdr split))
         (command (or (car rest)
                      (cond
                       ((plist-get opts :version) "version")
                       ((plist-get opts :help) "help")
                       (t "help"))))
         (command-args (cdr rest)))
    (list :command command
          :args command-args
          :json (plist-get opts :json)
          :help (plist-get opts :help)
          :version (plist-get opts :version))))

(defun nelix-cli--arg-or-error (command args)
  "Return the first member of ARGS or signal a COMMAND usage error."
  (or (car args)
      (signal 'anvil-pkg-error
              (list (format "nelix %s: missing required MANIFEST"
                            command)))))

(defun nelix-cli--numeric-arg (command arg)
  "Return ARG parsed as an integer for COMMAND."
  (when arg
    (unless (string-match-p "\\`[0-9]+\\'" arg)
      (signal 'anvil-pkg-error
              (list (format "nelix %s: GENERATION must be an integer, got %S"
                            command arg))))
    (string-to-number arg)))

(defun nelix-cli--profile-path ()
  "Return the current Nelix profile path."
  (cond
   ((boundp 'anvil-pkg-profile-dir) anvil-pkg-profile-dir)
   (t nil)))

(defun nelix-cli--plist-has-key-p (plist key)
  "Return non-nil when PLIST contains KEY."
  (let ((found nil))
    (while plist
      (when (eq (car plist) key)
        (setq found t))
      (setq plist (cddr plist)))
    found))

(defun nelix-cli--ensure-profile-path (command result)
  "Ensure mutating COMMAND RESULT contains a profile path."
  (if (and (member command nelix-cli--mutating-commands)
           (listp result)
           (not (nelix-cli--plist-has-key-p result :profile-root)))
      (append result (list :profile-root (nelix-cli--profile-path)))
    result))

(defun nelix-cli--add-profile-path (result)
  "Ensure RESULT contains a profile path."
  (if (and (listp result)
           (not (nelix-cli--plist-has-key-p result :profile-root)))
      (append result (list :profile-root (nelix-cli--profile-path)))
    result))

(defun nelix-cli--dispatch-apply (args)
  "Dispatch `nelix apply' with ARGS."
  (let ((manifest nil)
        (locked nil)
        (dry-run nil)
        (rollback-on-error t)
        (allow-remove nil)
        (allow-remove-count nil))
    (while args
      (let ((arg (car args)))
        (cond
         ((equal arg "--dry-run") (setq dry-run t))
         ((equal arg "--locked") (setq locked t))
         ((equal arg "--no-rollback") (setq rollback-on-error nil))
         ((equal arg "--allow-remove") (setq allow-remove t))
         ((equal arg "--allow-remove-count")
          (setq args (cdr args))
          (unless args
            (signal 'anvil-pkg-error
                    (list "nelix apply: --allow-remove-count requires a value")))
          (setq allow-remove-count
                (nelix-cli--numeric-arg "apply" (car args))))
         ((null manifest) (setq manifest arg))
         (t (signal 'anvil-pkg-error
                    (list (format "nelix apply: unexpected argument %S"
                                  arg))))))
      (setq args (cdr args)))
    (unless manifest
      (signal 'anvil-pkg-error
              (list "nelix apply: missing required MANIFEST")))
    (apply #'nelix-apply
           manifest
           (append (and dry-run (list :dry-run t))
                   (and locked (list :locked t))
                   (and allow-remove (list :allow-remove t))
                   (and allow-remove-count
                        (list :allow-remove-count allow-remove-count))
                   (unless rollback-on-error
                     (list :rollback-on-error nil))))))

(defun nelix-cli--dispatch-sync (args)
  "Dispatch `nelix sync' with ARGS."
  (let ((manifest nil)
        (prune nil)
        (locked nil)
        (allow-remove nil)
        (allow-remove-count nil))
    (while args
      (let ((arg (car args)))
        (cond
         ((equal arg "--prune") (setq prune t))
         ((equal arg "--locked") (setq locked t))
         ((equal arg "--allow-remove") (setq allow-remove t))
         ((equal arg "--allow-remove-count")
          (setq args (cdr args))
          (unless args
            (signal 'anvil-pkg-error
                    (list "nelix sync: --allow-remove-count requires a value")))
          (setq allow-remove-count
                (nelix-cli--numeric-arg "sync" (car args))))
         ((null manifest) (setq manifest arg))
         (t (signal 'anvil-pkg-error
                    (list (format "nelix sync: unexpected argument %S"
                                  arg))))))
      (setq args (cdr args)))
    (unless manifest
      (signal 'anvil-pkg-error
              (list "nelix sync: missing required MANIFEST")))
    (apply #'nelix-sync
           manifest
           (append (list :prune prune)
                   (and locked (list :locked t))
                   (and allow-remove (list :allow-remove t))
                   (and allow-remove-count
                        (list :allow-remove-count allow-remove-count))))))

(defun nelix-cli--dispatch-plan (args)
  "Dispatch `nelix plan' with ARGS.

`--dry-run' is accepted as an explicit no-op because `plan' is always
read-only and already returns the dry-run convergence report."
  (let ((manifest nil))
    (while args
      (let ((arg (car args)))
        (cond
         ((equal arg "--dry-run"))
         ((null manifest) (setq manifest arg))
         (t (signal 'anvil-pkg-error
                    (list (format "nelix plan: unexpected argument %S"
                                  arg))))))
      (setq args (cdr args)))
    (unless manifest
      (signal 'anvil-pkg-error
              (list "nelix plan: missing required MANIFEST")))
    (nelix-plan manifest)))

(defun nelix-cli--dispatch-schema (args)
  "Dispatch `nelix schema' with ARGS."
  (when (cdr args)
    (signal 'anvil-pkg-error
            (list (format "nelix schema: unexpected argument %S"
                          (cadr args)))))
  (nelix-schema (car args)))

(defun nelix-cli--dispatch-lock-check (args)
  "Dispatch `nelix lock-check' with ARGS."
  (let ((manifest (nelix-cli--arg-or-error "lock-check" args)))
    (when (cdr args)
      (signal 'anvil-pkg-error
              (list (format "nelix lock-check: unexpected argument %S"
                            (cadr args)))))
    (if (anvil-pkg-compat--standalone-nelisp-p)
        (nelix-lock-check--nelisp manifest)
      (nelix-lock-check manifest))))

(defun nelix-cli--dispatch-lock (args)
  "Dispatch `nelix lock' subcommands with ARGS."
  (let ((subcommand (car args))
        (rest (cdr args)))
    (cond
     ((equal subcommand "validate")
      (let ((manifest (nelix-cli--arg-or-error "lock validate" rest)))
        (when (cdr rest)
          (signal 'anvil-pkg-error
                  (list (format "nelix lock validate: unexpected argument %S"
                                (cadr rest)))))
        (nelix-lock-validate manifest)))
     ((equal subcommand "diff")
      (let ((manifest (nelix-cli--arg-or-error "lock diff" rest)))
        (when (cdr rest)
          (signal 'anvil-pkg-error
                  (list (format "nelix lock diff: unexpected argument %S"
                                (cadr rest)))))
        (nelix-lock-diff manifest)))
     ((equal subcommand "migrate")
      (let ((manifest nil)
            (dry-run nil))
        (while rest
          (let ((arg (car rest)))
            (cond
             ((equal arg "--dry-run")
              (setq dry-run t))
             ((null manifest)
              (setq manifest arg))
             (t
              (signal 'anvil-pkg-error
                      (list (format "nelix lock migrate: unexpected argument %S"
                                    arg))))))
          (setq rest (cdr rest)))
        (unless manifest
          (signal 'anvil-pkg-error
                  (list "nelix lock migrate: missing required MANIFEST")))
        (let ((result (nelix-lock-migrate manifest :dry-run dry-run)))
          (if dry-run
              result
            (nelix-cli--add-profile-path result)))))
     (t
      (nelix-cli--add-profile-path
       (nelix-lock-write (nelix-cli--arg-or-error "lock" args)))))))

(defun nelix-cli--dispatch-transaction (args)
  "Dispatch `nelix transaction' subcommands with ARGS."
  (let ((subcommand (car args))
        (rest (cdr args)))
    (cond
     ((equal subcommand "list")
      (let ((limit nil))
        (while rest
          (let ((arg (car rest)))
            (cond
             ((equal arg "--limit")
              (setq rest (cdr rest))
              (unless rest
                (signal 'anvil-pkg-error
                        (list "nelix transaction list: --limit requires a value")))
              (setq limit
                    (nelix-cli--numeric-arg "transaction list"
                                            (car rest))))
             (t
              (signal 'anvil-pkg-error
                      (list (format "nelix transaction list: unexpected argument %S"
                                    arg))))))
          (setq rest (cdr rest)))
        (nelix-transaction-list limit)))
     ((equal subcommand "show")
      (let ((id-or-file (car rest)))
        (unless id-or-file
          (signal 'anvil-pkg-error
                  (list "nelix transaction show: missing required ID|FILE")))
        (when (cdr rest)
          (signal 'anvil-pkg-error
                  (list (format "nelix transaction show: unexpected argument %S"
                                (cadr rest)))))
        (nelix-transaction-show id-or-file)))
     ((equal subcommand "recover")
      (let ((id-or-file (car rest))
            (dry-run nil)
            (execute nil))
        (unless id-or-file
          (signal 'anvil-pkg-error
                  (list "nelix transaction recover: missing required ID|FILE")))
        (setq rest (cdr rest))
        (while rest
          (let ((arg (car rest)))
            (cond
             ((equal arg "--dry-run")
              (setq dry-run t))
             ((equal arg "--execute")
              (setq execute t))
             (t
              (signal 'anvil-pkg-error
                      (list (format "nelix transaction recover: unexpected argument %S"
                                    arg))))))
          (setq rest (cdr rest)))
        (nelix-transaction-recover id-or-file
                                   :dry-run dry-run
                                   :execute execute)))
     ((null subcommand)
      (signal 'anvil-pkg-error
              (list "nelix transaction: missing subcommand")))
     (t
      (signal 'anvil-pkg-error
              (list (format "nelix transaction: unknown subcommand %S"
                            subcommand)))))))

(defun nelix-cli--dispatch-outdated (args)
  "Dispatch `nelix outdated' with ARGS."
  (let ((target nil)
        (backend nil))
    (while args
      (let ((arg (car args)))
        (cond
         ((equal arg "--backend")
          (setq args (cdr args))
          (unless args
            (signal 'anvil-pkg-error
                    (list "nelix outdated: --backend requires a value")))
          (setq backend (car args)))
         ((null target)
          (setq target arg))
         (t
          (signal 'anvil-pkg-error
                  (list (format "nelix outdated: unexpected argument %S"
                               arg))))))
      (setq args (cdr args)))
    (nelix-outdated target backend)))

(defun nelix-cli--raw-json (json)
  "Wrap already encoded JSON for direct CLI output."
  (list :nelix-cli-raw-json json))

(defun nelix-cli--raw-json-p (value)
  "Return non-nil when VALUE is an already encoded JSON wrapper."
  (and (consp value)
       (eq (car value) :nelix-cli-raw-json)
       (stringp (cadr value))))

(defun nelix-cli--dispatch-audit (args json)
  "Dispatch `nelix audit' with ARGS and JSON preference."
  (let ((manifest (nelix-cli--arg-or-error "audit" args)))
    (if (and json (fboundp 'nelix-fast-audit-json))
        (let ((raw (nelix-fast-audit-json manifest)))
          (if raw
              (nelix-cli--raw-json raw)
            (nelix-audit manifest)))
      (nelix-audit manifest))))

(defun nelix-cli--dispatch-upgrade-plan (args json)
  "Dispatch `nelix upgrade-plan' with ARGS and JSON preference."
  (let ((target (car args)))
    (if (and json
             target
             (file-exists-p target)
             (fboundp 'nelix-fast-upgrade-plan-json))
        (let ((raw (nelix-fast-upgrade-plan-json target)))
          (if raw
              (nelix-cli--raw-json raw)
            (nelix-upgrade-plan target)))
      (nelix-upgrade-plan target))))

(defun nelix-cli--symbol-arg (command option arg)
  "Return ARG interned as a symbol for COMMAND OPTION."
  (unless (and (stringp arg) (> (length arg) 0))
    (signal 'anvil-pkg-error
            (list (format "nelix %s: %s requires a non-empty value"
                          command option))))
  (intern arg))

(defun nelix-cli--profile-option (command option arg)
  "Return ARG as a profile name for COMMAND OPTION."
  (unless (and (stringp arg) (> (length arg) 0))
    (signal 'anvil-pkg-error
            (list (format "nelix %s: %s requires a non-empty value"
                          command option))))
  arg)

(defun nelix-cli--native-parse-common (command args allowed)
  "Parse native COMMAND ARGS using ALLOWED option symbols.

ALLOWED may contain `profile', `system', `generation', and `dry-run'."
  (let ((profile nil)
        (system nil)
        (generation nil)
        (dry-run nil)
        positional)
    (while args
      (let ((arg (car args)))
        (cond
         ((equal arg "--profile")
          (unless (memq 'profile allowed)
            (signal 'anvil-pkg-error
                    (list (format "nelix native %s: unexpected option --profile"
                                  command))))
          (setq args (cdr args))
          (unless args
            (signal 'anvil-pkg-error
                    (list (format "nelix native %s: --profile requires a value"
                                  command))))
          (setq profile
                (nelix-cli--profile-option
                 (format "native %s" command)
                 "--profile"
                 (car args))))
         ((equal arg "--system")
          (unless (memq 'system allowed)
            (signal 'anvil-pkg-error
                    (list (format "nelix native %s: unexpected option --system"
                                  command))))
          (setq args (cdr args))
          (unless args
            (signal 'anvil-pkg-error
                    (list (format "nelix native %s: --system requires a value"
                                  command))))
          (setq system
                (nelix-cli--symbol-arg
                 (format "native %s" command)
                 "--system"
                 (car args))))
         ((equal arg "--generation")
          (unless (memq 'generation allowed)
            (signal 'anvil-pkg-error
                    (list (format "nelix native %s: unexpected option --generation"
                                  command))))
          (setq args (cdr args))
          (unless args
            (signal 'anvil-pkg-error
                    (list (format "nelix native %s: --generation requires a value"
                                  command))))
          (setq generation
                (nelix-cli--numeric-arg
                 (format "native %s" command)
                 (car args))))
         ((equal arg "--dry-run")
          (unless (memq 'dry-run allowed)
            (signal 'anvil-pkg-error
                    (list (format "nelix native %s: unexpected option --dry-run"
                                  command))))
          (setq dry-run t))
         ((string-prefix-p "--" arg)
          (signal 'anvil-pkg-error
                  (list (format "nelix native %s: unexpected option %s"
                                command arg))))
         (t
          (push arg positional))))
      (setq args (cdr args)))
    (list :profile profile
          :system system
          :generation generation
          :dry-run dry-run
          :positionals (nreverse positional))))

(defun nelix-cli--dispatch-registry (args)
  "Dispatch `nelix registry' with ARGS."
  (let ((subcommand (car args))
        (rest (cdr args)))
    (cond
     ((equal subcommand "update")
      (when rest
        (signal 'anvil-pkg-error
                (list (format "nelix registry update: unexpected argument %S"
                              (car rest)))))
      (append (list :operation 'registry-update)
              (nelix-registry-update)))
     ((equal subcommand "index")
      (let ((root (car rest))
            (output (cadr rest)))
        (unless root
          (signal 'anvil-pkg-error
                  (list "nelix registry index: missing required ROOT")))
        (unless output
          (signal 'anvil-pkg-error
                  (list "nelix registry index: missing required OUTPUT")))
        (when (cddr rest)
          (signal 'anvil-pkg-error
                  (list (format "nelix registry index: unexpected argument %S"
                                (caddr rest)))))
        (nelix-registry-write-index root output)))
     ((equal subcommand "list")
      (let ((system nil))
        (while rest
          (let ((arg (car rest)))
            (cond
             ((equal arg "--system")
              (setq rest (cdr rest))
              (unless rest
                (signal 'anvil-pkg-error
                        (list "nelix registry list: --system requires a value")))
              (setq system
                    (nelix-cli--symbol-arg "registry list"
                                           "--system"
                                           (car rest))))
             (t
              (signal 'anvil-pkg-error
                      (list (format "nelix registry list: unexpected argument %S"
                                    arg))))))
          (setq rest (cdr rest)))
        (let* ((update (nelix-registry-update))
               (results (nelix-registry-list system)))
          (list :status 'ok
                :operation 'registry-list
                :system (or system :all)
                :count (length results)
                :update update
                :results results))))
     ((equal subcommand "search")
      (let ((query nil)
            (system nil))
        (while rest
          (let ((arg (car rest)))
            (cond
             ((equal arg "--system")
              (setq rest (cdr rest))
              (unless rest
                (signal 'anvil-pkg-error
                        (list "nelix registry search: --system requires a value")))
              (setq system
                    (nelix-cli--symbol-arg "registry search"
                                           "--system"
                                           (car rest))))
             ((null query)
              (setq query arg))
             (t
              (signal 'anvil-pkg-error
                      (list (format "nelix registry search: unexpected argument %S"
                                    arg))))))
          (setq rest (cdr rest)))
        (unless query
          (signal 'anvil-pkg-error
                  (list "nelix registry search: missing required QUERY")))
        (let* ((update (nelix-registry-update))
               (results (nelix-registry-search query system)))
          (list :status 'ok
                :operation 'registry-search
                :query query
                :system (or system :all)
                :count (length results)
                :update update
                :results results))))
     ((equal subcommand "show")
      (let ((name (car rest)))
        (unless name
          (signal 'anvil-pkg-error
                  (list "nelix registry show: missing required NAME")))
        (when (cdr rest)
          (signal 'anvil-pkg-error
                  (list (format "nelix registry show: unexpected argument %S"
                                (cadr rest)))))
        (let* ((update (nelix-registry-update))
               (recipe (nelix-registry-get name)))
          (unless recipe
            (signal 'anvil-pkg-error
                    (list (format "nelix registry show: package not found: %s"
                                  name))))
          (list :status 'ok
                :operation 'registry-show
                :name name
                :update update
                :recipe recipe))))
     ((null subcommand)
      (signal 'anvil-pkg-error
              (list "nelix registry: missing subcommand")))
     (t
      (signal 'anvil-pkg-error
              (list (format "nelix registry: unknown subcommand %S"
                            subcommand)))))))

(defun nelix-cli--dispatch-native (args)
  "Dispatch `nelix native' with ARGS."
  (let ((subcommand (car args))
        (rest (cdr args)))
    (cond
     ((equal subcommand "audit")
      (when rest
        (signal 'anvil-pkg-error
                (list (format "nelix native audit: unexpected argument %S"
                              (car rest)))))
      (append (list :operation 'native-audit)
              (nelix-native-audit)))
     ((equal subcommand "install")
      (let* ((opts (nelix-cli--native-parse-common
                    "install" rest '(profile system)))
             (names (plist-get opts :positionals)))
        (unless names
          (signal 'anvil-pkg-error
                  (list "nelix native install: missing required NAME")))
        (let* ((update (nelix-registry-update))
               (reports (nelix-backend-install
                         'nelix-native
                         names
                         (plist-get opts :profile)
                         (plist-get opts :system))))
          (list :status 'ok
                :operation 'native-install
                :backend 'nelix-native
                :profile (or (plist-get opts :profile)
                             nelix-builder-default-profile)
                :system (or (plist-get opts :system)
                            (nelix-current-system))
                :update update
                :count (length reports)
                :results reports
                :profile-root (nelix-profile-root)))))
     ((equal subcommand "remove")
      (let* ((opts (nelix-cli--native-parse-common
                    "remove" rest '(profile system)))
             (names (plist-get opts :positionals)))
        (unless names
          (signal 'anvil-pkg-error
                  (list "nelix native remove: missing required NAME")))
        (let* ((profile-name (or (plist-get opts :profile)
                                 nelix-builder-default-profile))
               (report (nelix-profile-prune
                        profile-name
                        names
                        (plist-get opts :system)))
               (profile (plist-get report :profile)))
          (list :status 'ok
                :operation 'native-remove
                :backend 'nelix-native
                :profile profile-name
                :system (plist-get profile :system)
                :generation (plist-get profile :generation)
                :changed (plist-get report :changed)
                :count (length (plist-get report :removed))
                :removed (plist-get report :removed)
                :kept (plist-get report :kept)
                :result profile
                :profile-root (nelix-profile-root)))))
     ((equal subcommand "list")
      (when rest
        (signal 'anvil-pkg-error
                (list (format "nelix native list: unexpected argument %S"
                              (car rest)))))
      (append (list :operation 'native-list
                    :backend 'nelix-native)
              (nelix-backend-list 'nelix-native)))
     ((equal subcommand "profile")
      (let* ((opts (nelix-cli--native-parse-common
                    "profile" rest '(profile generation)))
             (positionals (plist-get opts :positionals)))
        (when positionals
          (signal 'anvil-pkg-error
                  (list (format "nelix native profile: unexpected argument %S"
                                (car positionals)))))
        (let* ((profile-name (or (plist-get opts :profile)
                                 nelix-builder-default-profile))
               (profile (nelix-profile-read profile-name
                                            (plist-get opts :generation))))
          (list :status 'ok
                :operation 'native-profile
                :backend 'nelix-native
                :profile profile-name
                :generation (plist-get profile :generation)
                :profile-root (nelix-profile-root)
                :result profile))))
     ((equal subcommand "activate")
      (let* ((opts (nelix-cli--native-parse-common
                    "activate" rest '(profile generation)))
             (positionals (plist-get opts :positionals)))
        (when positionals
          (signal 'anvil-pkg-error
                  (list (format "nelix native activate: unexpected argument %S"
                                (car positionals)))))
        (let* ((profile-name (or (plist-get opts :profile)
                                 nelix-builder-default-profile))
               (generation (plist-get opts :generation))
               (runtime (nelix-profile-activate-runtime profile-name generation))
               (emacs-load-paths
                (nelix-profile-emacs-load-paths profile-name generation)))
          (list :status 'ok
                :operation 'native-activate
                :backend 'nelix-native
                :profile profile-name
                :generation (plist-get runtime :generation)
                :profile-root (nelix-profile-root)
                :runtime runtime
                :emacs-load-paths emacs-load-paths))))
     ((equal subcommand "rollback")
      (let* ((opts (nelix-cli--native-parse-common
                    "rollback" rest '(profile generation)))
             (positionals (plist-get opts :positionals)))
        (when positionals
          (signal 'anvil-pkg-error
                  (list (format "nelix native rollback: unexpected argument %S"
                                (car positionals)))))
        (let* ((profile-name (or (plist-get opts :profile)
                                 nelix-builder-default-profile))
               (profile (nelix-profile-rollback
                         profile-name
                         (plist-get opts :generation)))
               (generation (plist-get profile :generation))
               (runtime (nelix-profile-activate-runtime
                         profile-name
                         generation))
               (emacs-load-paths
                (nelix-profile-emacs-load-paths profile-name generation)))
          (list :status 'ok
                :operation 'native-rollback
                :backend 'nelix-native
                :profile profile-name
                :generation generation
                :profile-root (nelix-profile-root)
                :result profile
                :runtime runtime
                :emacs-load-paths emacs-load-paths))))
     ((equal subcommand "gc")
      (let* ((opts (nelix-cli--native-parse-common
                    "gc" rest '(profile dry-run)))
             (positionals (plist-get opts :positionals)))
        (when positionals
          (signal 'anvil-pkg-error
                  (list (format "nelix native gc: unexpected argument %S"
                                (car positionals)))))
        (append (list :operation 'native-gc
                      :backend 'nelix-native
                      :profile-root (nelix-profile-root))
                (nelix-store-gc :dry-run (plist-get opts :dry-run)
                                :profile (plist-get opts :profile)))))
     ((null subcommand)
      (signal 'anvil-pkg-error
              (list "nelix native: missing subcommand")))
     (t
      (signal 'anvil-pkg-error
              (list (format "nelix native: unknown subcommand %S"
                            subcommand)))))))

(defun nelix-cli-dispatch (parsed)
  "Run the command described by PARSED and return a result plist or value."
  (let* ((command (plist-get parsed :command))
         (args (plist-get parsed :args))
         (json (plist-get parsed :json))
         (result
          (cond
           ((member command '("help" nil))
            (list :status 'ok :usage nelix-cli--usage))
           ((equal command "version")
            (list :status 'ok :version nelix-cli-version))
           ((equal command "validate")
            (let ((manifest (nelix-cli--arg-or-error command args)))
              (if (and json (fboundp 'nelix-fast-validate-json))
                  (let ((raw (nelix-fast-validate-json manifest)))
                    (if raw
                        (nelix-cli--raw-json raw)
                      (nelix-validate manifest)))
                (nelix-validate manifest))))
           ((equal command "apply")
            (nelix-cli--dispatch-apply args))
           ((equal command "plan")
            (nelix-cli--dispatch-plan args))
           ((equal command "audit")
            (nelix-cli--dispatch-audit args json))
           ((equal command "sync")
            (nelix-cli--dispatch-sync args))
           ((equal command "prune-plan")
            (nelix-prune-plan (nelix-cli--arg-or-error command args)))
           ((equal command "aot-cache")
            (nelix-fast-aot-target-cache-write
             (nelix-cli--arg-or-error command args)))
           ((equal command "lock")
            (nelix-cli--dispatch-lock args))
           ((equal command "lock-check")
            (nelix-cli--dispatch-lock-check args))
           ((equal command "transaction")
            (nelix-cli--dispatch-transaction args))
           ((equal command "upgrade-plan")
            (nelix-cli--dispatch-upgrade-plan args json))
           ((equal command "outdated")
            (nelix-cli--dispatch-outdated args))
           ((equal command "upgrade")
            (let ((result* (nelix-upgrade (car args))))
              (if (and (listp result*) (plist-get result* :operation))
                  result*
                (list :status 'ok
                      :operation 'upgrade
                      :name (or (car args) :all)
                      :result result*))))
           ((equal command "registry")
            (nelix-cli--dispatch-registry args))
           ((equal command "native")
            (nelix-cli--dispatch-native args))
           ((equal command "list")
            (if (and (anvil-pkg-compat--standalone-nelisp-p)
                     (fboundp 'nelix-fast-list))
                (nelix-fast-list)
              (nelix-list)))
           ((equal command "rollback")
            (let ((generation (nelix-cli--numeric-arg command (car args))))
              (list :status 'ok
                    :operation 'rollback
                    :generation generation
                    :result (nelix-rollback generation))))
           ((equal command "doctor")
            (nelix-doctor))
           ((equal command "schema")
            (nelix-cli--dispatch-schema args))
           (t
            (signal 'anvil-pkg-error
                    (list (format "nelix: unknown command %S" command)))))))
    (nelix-cli--ensure-profile-path command result)))

(defun nelix-cli--plist-p (value)
  "Return non-nil when VALUE looks like a property list."
  (and (consp value)
       (keywordp (car value))
       (let ((n (length value)))
         (while (>= n 2)
           (setq n (- n 2)))
         (= n 0))))

(defun nelix-cli--proper-list-p (value)
  "Return non-nil when VALUE is a nil-terminated list."
  (let ((slow value)
        (fast value)
        (proper t)
        (done nil))
    (while (and (not done) proper)
      (cond
       ((null fast)
        (setq done t))
       ((not (consp fast))
        (setq proper nil))
       ((null (cdr fast))
        (setq done t))
       ((not (consp (cdr fast)))
        (setq proper nil))
       (t
        (setq fast (cddr fast))
        (setq slow (cdr slow))
        (when (eq fast slow)
          (setq proper nil)))))
    proper))

(defun nelix-cli--alist-p (value)
  "Return non-nil when VALUE is a simple alist for JSON objects."
  (and (nelix-cli--proper-list-p value)
       (consp value)
       (let ((rest value)
             (ok t))
         (while (and rest ok)
           (setq ok (and (consp (car rest))
                         (not (keywordp (caar rest)))))
           (setq rest (cdr rest)))
         ok)))

(defun nelix-cli--json-key (key)
  "Return a JSON object key for KEY."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun nelix-cli--json-normalize (value)
  "Normalize VALUE into data accepted by JSON backends."
  (cond
   ((hash-table-p value)
    (let ((table (make-hash-table :test 'equal)))
      (maphash (lambda (key val)
                 (puthash (nelix-cli--json-key key)
                          (nelix-cli--json-normalize val)
                          table))
               value)
      table))
   ((nelix-cli--plist-p value)
    (let ((table (make-hash-table :test 'equal))
          (rest value))
      (while rest
        (puthash (nelix-cli--json-key (car rest))
                 (nelix-cli--json-normalize (cadr rest))
                 table)
        (setq rest (cddr rest)))
      table))
   ((nelix-cli--alist-p value)
    (let ((table (make-hash-table :test 'equal)))
      (dolist (entry value table)
        (puthash (nelix-cli--json-key (car entry))
                 (nelix-cli--json-normalize (cdr entry))
                 table))))
   ((and (consp value)
         (not (nelix-cli--proper-list-p value)))
    (let ((table (make-hash-table :test 'equal)))
      (puthash "car" (nelix-cli--json-normalize (car value)) table)
      (puthash "cdr" (nelix-cli--json-normalize (cdr value)) table)
      table))
   ((consp value)
    (let ((items (mapcar #'nelix-cli--json-normalize value)))
      (if (fboundp 'vconcat)
          (vconcat items)
        items)))
   ((eq value :null) :null)
   ((eq value t) t)
   ((null value) :null)
   ((symbolp value) (symbol-name value))
   (t value)))

(defun nelix-cli--json-escape-string (string)
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
    (if (null needs-escape)
        string
      (nelix-cli--json-escape-string-slow string))))

(defun nelix-cli--json-escape-string-slow (string)
  "Return STRING escaped as a JSON string body using the full slow path."
  (let ((i 0)
        (len (length string))
        chunks)
    (while (< i len)
      (let ((ch (aref string i)))
        (push
         (cond
          ((eq ch ?\\) "\\\\")
          ((eq ch ?\") "\\\"")
          ((eq ch ?\n) "\\n")
          ((eq ch ?\r) "\\r")
          ((eq ch ?\t) "\\t")
          (t (char-to-string ch)))
         chunks))
      (setq i (1+ i)))
    (apply #'concat (nreverse chunks))))

(defun nelix-cli--json-encode (value)
  "Return VALUE encoded as JSON using only portable Elisp constructs."
  (cond
   ((eq value t) "true")
   ((or (null value) (eq value :null)) "null")
   ((stringp value)
    (concat "\"" (nelix-cli--json-escape-string value) "\""))
   ((numberp value) (number-to-string value))
   ((symbolp value)
    (nelix-cli--json-encode (symbol-name value)))
   ((hash-table-p value)
    (let (fields)
      (maphash
       (lambda (key val)
         (push
          (concat
           (nelix-cli--json-encode (nelix-cli--json-key key))
           ":"
           (nelix-cli--json-encode val))
          fields))
       value)
      (concat "{" (mapconcat #'identity (nreverse fields) ",") "}")))
   ((nelix-cli--plist-p value)
    (let ((rest value)
          fields)
      (while rest
        (push
         (concat
          (nelix-cli--json-encode (nelix-cli--json-key (car rest)))
          ":"
          (nelix-cli--json-encode (cadr rest)))
         fields)
        (setq rest (cddr rest)))
      (concat "{" (mapconcat #'identity (nreverse fields) ",") "}")))
   ((vectorp value)
    (nelix-cli--json-encode (append value nil)))
   ((consp value)
    (concat "["
            (mapconcat #'nelix-cli--json-encode value ",")
            "]"))
   (t
    (nelix-cli--json-encode (format "%s" value)))))

(defun nelix-cli--string-list-p (value)
  "Return non-nil when VALUE is a proper list of strings."
  (let ((rest value)
        (ok (listp value)))
    (while (and ok rest)
      (if (stringp (car rest))
          (setq rest (cdr rest))
        (setq ok nil)))
    ok))

(defun nelix-cli--print-to-string (object)
  "Return OBJECT serialised as an Elisp literal for non-JSON CLI output.

Prefers the standalone NeLisp runtime's native printer `nelisp--repr' when
bound: there `prin1-to-string' is an interpreted O(n) loop (~0.13ms/op) and
dominates `apply' output formatting for large result plists.  Falls back to
`prin1-to-string' under Emacs.  The two are identical for result data and
differ only on `quote'/`function' reader-macro abbreviations (which apply
results never contain)."
  (if (fboundp 'nelisp--repr)
      (nelisp--repr object)
    (prin1-to-string object)))

(defun nelix-cli-format-result (result json)
  "Return RESULT formatted for stdout.  Use JSON when JSON is non-nil."
  (if (nelix-cli--raw-json-p result)
      (cadr result)
    (if json
      (nelix-cli--json-encode (nelix-cli--json-normalize result))
      (cond
       ((and (listp result)
             (eq (plist-get result :status) 'ok)
             (plist-get result :usage))
        (plist-get result :usage))
       ((and (listp result)
             (eq (plist-get result :status) 'ok)
             (plist-get result :version))
        (plist-get result :version))
       ((nelix-cli--string-list-p result)
        (mapconcat #'identity result "\n"))
       (t (nelix-cli--print-to-string result))))))

(defun nelix-cli-main (&optional args)
  "Run Nelix CLI with ARGS and exit the process."
  (let* ((raw (or args command-line-args-left))
         (parsed (nelix-cli-parse-args raw))
         (json (plist-get parsed :json)))
    (condition-case err
        (let ((text (nelix-cli-format-result
                     (nelix-cli-dispatch parsed)
                     json)))
          (princ text)
          (unless (string-suffix-p "\n" text)
            (princ "\n"))
          (kill-emacs 0))
      (error
       (let ((message (error-message-string err)))
         (if json
             (princ
              (concat
               (anvil-pkg-compat-json-serialize
                (nelix-cli--json-normalize
                 (list :status 'error
                       :error message)))
               "\n"))
           (princ (format "nelix: %s\n" message)
                  #'external-debugging-output))
         (kill-emacs 2))))))

(provide 'nelix-cli)
;;; nelix-cli.el ends here
