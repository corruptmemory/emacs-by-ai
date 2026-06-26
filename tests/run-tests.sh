#!/usr/bin/env bash
# Run every ERT suite under tests/ in batch.
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
  --eval "(dolist (f (directory-files \"$REPO/tests\" t \"-tests\\\\.el\\\\'\"))
            (load f nil t))" \
  -f ert-run-tests-batch-and-exit
