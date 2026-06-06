#!/usr/bin/env bash
# Run the cm-project-roots ERT suite in batch.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
exec emacs -batch -Q \
  --eval "(progn
            (add-to-list 'load-path \"$REPO\")
            (let ((b \"$REPO/straight/build\"))
              (when (file-directory-p b)
                (dolist (d (directory-files b t \"^[^.]\"))
                  (when (file-directory-p d) (add-to-list 'load-path d))))))" \
  -l ert \
  -l "$REPO/tests/cm-project-roots-tests.el" \
  -f ert-run-tests-batch-and-exit
