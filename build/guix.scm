;; SPDX-License-Identifier: MPL-2.0
;; Guix development environment template.
;; Usage: guix shell -D -f build/guix.scm

(use-modules (guix packages)
             (guix build-system gnu)
             (guix licenses)
             (gnu packages base)
             (gnu packages bash))

(package
  (name "evil-weevil")
  (version "0.1.0")
  (source #f)
  (build-system gnu-build-system)
  (inputs (list coreutils bash))
  (synopsis "evil-weevil")
  (description "evil-weevil — part of the hyperpolymath ecosystem.")
  (home-page "https://github.com/metadatastician/evil-weevil")
  (license (@ (guix licenses) mpl2.0)))
