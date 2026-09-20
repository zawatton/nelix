;;; consult-projectile.el --- Nelix recipe (OlMon/consult-projectile, GitLab) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "consult-projectile" :version "0.7" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://gitlab.com/OlMon/consult-projectile/-/archive/400439c56d17bca7888f7d143d8a11f84900a406/consult-projectile-400439c56d17bca7888f7d143d8a11f84900a406.tar.gz" :sha256 "sha256-1c48850cd2c2bdffeeafc4a6701c78c88b72ffd2aab2e5216f261c6580a0e567") :dependencies ("consult" "projectile") :install (:type build :build-system emacs-package :pname "consult-projectile" :load-paths (".") :features (consult-projectile))) (x86_64-windows :source (:type url :url "https://gitlab.com/OlMon/consult-projectile/-/archive/400439c56d17bca7888f7d143d8a11f84900a406/consult-projectile-400439c56d17bca7888f7d143d8a11f84900a406.tar.gz" :sha256 "sha256-1c48850cd2c2bdffeeafc4a6701c78c88b72ffd2aab2e5216f261c6580a0e567") :dependencies ("consult" "projectile") :install (:type build :build-system emacs-package :pname "consult-projectile" :load-paths (".") :features (consult-projectile)))))

;;; consult-projectile.el ends here
