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

;; --- scratch tiers ---------------------------------------------------------

(ert-deftest cm/scratch--classification ()
  "Project, stash, and lone-scratch buffers classify into the right tier."
  (cl-flet ((mk (n) (get-buffer-create n)))
    (unwind-protect
        (progn
          (should (cm/scratch--project-buffer-p (mk "*scratch:foo:1*")))
          (should-not (cm/scratch--project-buffer-p (mk "*stash:snip*")))
          (should-not (cm/scratch--project-buffer-p (mk "*scratch*")))
          (should (cm/scratch--stash-buffer-p (mk "*stash:snip*")))
          (should (cm/scratch--stash-buffer-p (mk "*scratch*")))
          (should-not (cm/scratch--stash-buffer-p (mk "*scratch:foo:1*"))))
      (dolist (n '("*scratch:foo:1*" "*stash:snip*"))
        (when (get-buffer n) (kill-buffer n))))))

(ert-deftest cm/scratch-new--project-tier-instant ()
  "Without a prefix, creates the next-numbered project scratch buffer."
  (cl-letf (((symbol-function 'cm/session--root-of) (lambda (_) "/tmp/myproj/")))
    (let ((buf (cm/scratch-new nil)))
      (unwind-protect
          (progn
            (should (string-prefix-p "*scratch:myproj:" (buffer-name buf)))
            (should (eq (buffer-local-value 'major-mode buf) cm/scratch-default-mode)))
        (kill-buffer buf)))))

(ert-deftest cm/scratch-new--global-tier-prompts ()
  "With a prefix, prompts for a name and creates a *stash:NAME* buffer."
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "snippets")))
    (let ((buf (cm/scratch-new t)))
      (unwind-protect
          (should (equal (buffer-name buf) "*stash:snippets*"))
        (kill-buffer buf)))))

(provide 'cm-project-sessions-tests)
;;; cm-project-sessions-tests.el ends here
