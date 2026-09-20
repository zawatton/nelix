;;; libtool.el --- Nelix recipe -*- lexical-binding: t; -*-

;; Built from source so that libltdl -- which emacs-ffi links against --
;; comes from the Nelix store rather than from an OS package.  Debian
;; splits it: libltdl7 ships libltdl.so.7 (runtime only), while ltdl.h and
;; the libltdl.so link symlink live in libltdl-dev, which needs root.
;;
;; Provenance: fetched from ftpmirror.gnu.org and again from ftp.gnu.org
;; with identical bytes, and the upstream .sig verified against
;; gnu-keyring.gpg -- good signature from Ileana Dumitrescu, the libtool
;; maintainer.  The hash below is of that tarball.
;;
;; --enable-ltdl-install is what actually installs ltdl.h and the library;
;; without it libtool installs only its scripts.  The other switches keep
;; the build small: no static archives, no documentation.

(require 'nelix-registry)

(nelix-package
 :name "libtool"
 :version "2.5.4"
 :class 'library
 :systems
 '((x86_64-linux
    :source (:type url
             :url "https://ftp.gnu.org/gnu/libtool/libtool-2.5.4.tar.xz"
             :sha256 "sha256-f81f5860666b0bc7d84baddefa60d1cb9fa6fceb2398cc3baca6afaa60266675")
    :install (:type build
              :build-system gnu
              :pname "libtool"
              :build-phases
              ((unpack . (nelix-build-unpack-source-archive))
               (configure . "./configure --prefix=\"$out\" --enable-ltdl-install --disable-static --disable-dependency-tracking")
               (build . "make")
               (install . "make install"))))))

;;; libtool.el ends here
