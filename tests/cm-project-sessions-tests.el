;;; cm-project-sessions-tests.el --- Tests for cm-project-sessions  -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'cm-project-sessions)

;; --- naming ----------------------------------------------------------------

(ert-deftest cm/session-name-for-project--stable-and-fs-safe ()
  "A session name is deterministic and contains only filesystem-safe chars."
  (should (equal (cm/session-name-for-project "/tmp/aa/bb") "-tmp-aa-bb"))
  ;; trailing slash is normalized to the same name
  (should (equal (cm/session-name-for-project "/tmp/aa/bb/") "-tmp-aa-bb"))
  ;; unsafe characters are replaced
  (should (string-match-p "\\`[A-Za-z0-9._-]+\\'"
                          (cm/session-name-for-project "/x/y z/@!"))))

(ert-deftest cm/session--root-of--returns-project-root ()
  "Returns the project root when DIR is inside a project, nil otherwise."
  (let ((root "/tmp/proj/"))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) (list 'fake root)))
              ((symbol-function 'project-root) (lambda (_) root)))
      (should (equal (cm/session--root-of "/tmp/proj/src") root)))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
      (should (null (cm/session--root-of "/tmp/elsewhere"))))))

(provide 'cm-project-sessions-tests)
;;; cm-project-sessions-tests.el ends here
