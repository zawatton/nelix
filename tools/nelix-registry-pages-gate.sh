#!/bin/sh
# Round-trip the published registry tree through a subscriber.
#
# The point is not that the files exist -- `make pages' already copied them --
# but that a subscriber starting from nothing ends up with the recipes, and
# that a changed byte anywhere is refused.  Both halves are asserted: a gate
# that only checked the happy path would pass against a registry that accepts
# anything.
set -eu

PAGES_DIR="${1:-public}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMACS="${EMACS:-emacs}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

[ -f "$PAGES_DIR/index.el" ] || {
  echo "nelix registry pages gate: missing $PAGES_DIR/index.el" >&2
  exit 1
}

published="$(find "$PAGES_DIR/packages" -name '*.el' | wc -l)"
[ "$published" -gt 0 ] || {
  echo "nelix registry pages gate: no recipes under $PAGES_DIR/packages" >&2
  exit 1
}

# A tampered copy: same tree, one recipe altered, index left alone so its own
# hash still matches.  The recipe row's hash is what must catch it.
cp -r "$PAGES_DIR" "$TMP_DIR/tampered"
victim="$(find "$TMP_DIR/tampered/packages" -name '*.el' | head -1)"
printf '\n;; tampered by the pages gate\n' >> "$victim"

"$EMACS" -Q --batch --eval "(setq load-prefer-newer t)" -L "$REPO_ROOT" --eval "
(progn
  (require 'nelix-registry)
  (require 'nelix-fetch)
  (defun gate--subscribe (dir)
    ;; Empty cache and no packaged recipes: a content-addressed cache hit
    ;; would serve bytes fetched earlier and hide what the origin holds now,
    ;; and packaged recipes would supply the count on their own.
    (let* ((home (make-temp-file \"gate-\" t))
           (nelix-fetch-cache-directory (expand-file-name \"cache\" home))
           (nelix-registry-include-packaged-root nil)
           (nelix-registry-root (expand-file-name \"registry\" home))
           (index (expand-file-name \"index.el\" dir))
           (nelix-registry-remotes
            (list (list :name \"gate\" :url (concat \"file://\" index)
                        :sha256 (nelix-fetch-sha256-file index)))))
      (unwind-protect
          (condition-case err
              (progn (nelix-registry-update)
                     (cons 'ok (length (nelix-registry-list))))
            (error (cons 'rejected (car err))))
        (delete-directory home t))))
  (let ((clean (gate--subscribe \"$PAGES_DIR\"))
        (tampered (gate--subscribe \"$TMP_DIR/tampered\")))
    (unless (eq (car clean) 'ok)
      (error \"nelix registry pages gate: clean tree was refused: %S\" clean))
    (unless (= (cdr clean) $published)
      (error \"nelix registry pages gate: subscriber saw %d recipes, published %d\"
             (cdr clean) $published))
    (unless (eq (car tampered) 'rejected)
      (error \"nelix registry pages gate: tampered recipe was ACCEPTED: %S\" tampered))
    (princ (format \"nelix registry pages gate ok: %d recipes, tampering refused (%s)\n\"
                   (cdr clean) (cdr tampered)))))"
