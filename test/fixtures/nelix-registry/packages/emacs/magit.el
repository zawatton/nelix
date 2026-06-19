;;; magit.el --- Nelix registry fixture -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "magit"
 :version "4.3.0"
 :class 'emacs-lisp
 :description "Git porcelain inside Emacs"
 :systems
 '((x86_64-linux
    :source (:type elpa
             :archive gnu
             :package "magit"
             :version "4.3.0"
             :sha256 "sha256-fixture-magit")
    :dependencies ("transient" "with-editor")
    :install (:type emacs-lisp :features (magit)))
   (x86_64-windows
    :source (:type elpa
             :archive gnu
             :package "magit"
             :version "4.3.0"
             :sha256 "sha256-fixture-magit")
    :dependencies ("transient" "with-editor")
    :install (:type emacs-lisp :features (magit)))))

;;; magit.el ends here
