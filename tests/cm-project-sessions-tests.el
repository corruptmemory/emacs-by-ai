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

;; --- per-project scratch handler -------------------------------------------

(ert-deftest cm/scratch-handler--round-trip ()
  "Save handler serializes project scratch buffers; load handler restores them."
  (let ((a (get-buffer-create "*scratch:proj:1*"))
        (b (get-buffer-create "*scratch:proj:2*"))
        (file (get-buffer-create "real.el")))   ; must be ignored
    (unwind-protect
        (progn
          (with-current-buffer a (insert "ALPHA"))
          (with-current-buffer b (insert "BETA"))
          (let ((data (cm/scratch--save-handler (list a b file))))
            (should (= 2 (length data)))
            (should (equal "ALPHA" (alist-get 'buffer-string (cdr (assoc "*scratch:proj:1*" data)))))
            ;; now kill and restore from the serialized data
            (kill-buffer a) (kill-buffer b)
            (should-not (get-buffer "*scratch:proj:1*"))
            (cm/scratch--load-handler data)
            (should (equal "ALPHA" (with-current-buffer "*scratch:proj:1*" (buffer-string))))
            (should (equal "BETA"  (with-current-buffer "*scratch:proj:2*" (buffer-string))))))
      (dolist (n '("*scratch:proj:1*" "*scratch:proj:2*" "real.el"))
        (when (get-buffer n) (kill-buffer n))))))

;; --- global stash ----------------------------------------------------------

(ert-deftest cm/stash--round-trip ()
  "Stash save writes live stash buffers; load recreates them from the file."
  (let* ((cm/stash-file (make-temp-file "cm-stash" nil ".el"))
         (s (get-buffer-create "*stash:snippets*"))
         (sc (get-buffer-create "*scratch*"))
         (proj (get-buffer-create "*scratch:proj:1*")))  ; must NOT be in the stash
    (unwind-protect
        (progn
          (with-current-buffer s (insert "REUSABLE"))
          (with-current-buffer sc (erase-buffer) (insert "LONE"))
          (cm/stash-save)
          (kill-buffer s) (kill-buffer sc)
          (kill-buffer proj)
          (should-not (get-buffer "*stash:snippets*"))
          (cm/stash-load)
          (should (equal "REUSABLE" (with-current-buffer "*stash:snippets*" (buffer-string))))
          (should (equal "LONE" (with-current-buffer "*scratch*" (buffer-string))))
          (should-not (get-buffer "*scratch:proj:1*")))
      (dolist (n '("*stash:snippets*" "*scratch*" "*scratch:proj:1*"))
        (when (get-buffer n) (kill-buffer n)))
      (when (file-exists-p cm/stash-file) (delete-file cm/stash-file)))))

;; --- the flip --------------------------------------------------------------

(ert-deftest cm/session-switch--not-a-project ()
  "Returns `not-a-project' and does nothing when DIR is not in a project."
  (cl-letf (((symbol-function 'cm/session--root-of) (lambda (_) nil))
            ((symbol-function 'easysession-get-session-name) (lambda () "current")))
    (should (eq 'not-a-project (cm/session-switch-to-project "/tmp/x")))))

(ert-deftest cm/session-switch--noop-when-same-project ()
  "Returns `noop' when the target session equals the current one."
  (cl-letf (((symbol-function 'cm/session--root-of) (lambda (_) "/tmp/p/"))
            ((symbol-function 'cm/session-name-for-project) (lambda (_) "P"))
            ((symbol-function 'easysession-get-session-name) (lambda () "P")))
    (should (eq 'noop (cm/session-switch-to-project "/tmp/p/")))))

(ert-deftest cm/session-switch--full-flow-order ()
  "Leaving a project: prompt-save, stash-save, session-save, teardown, switch, stash-load."
  (let ((calls '())
        (easysession-directory (make-temp-file "cm-sess" t))
        (easysession-switch-to-save-session t))
    (cl-letf (((symbol-function 'cm/session--root-of) (lambda (_) "/tmp/b/"))
              ((symbol-function 'cm/session-name-for-project) (lambda (_) "B"))
              ((symbol-function 'easysession-get-session-name) (lambda () "A"))
              ((symbol-function 'save-some-buffers) (lambda (&rest _) (push 'prompt calls)))
              ((symbol-function 'cm/stash-save) (lambda () (push 'stash-save calls)))
              ((symbol-function 'easysession-save) (lambda (&rest _) (push 'session-save calls)))
              ((symbol-function 'easysession-kill-all-buffers) (lambda () (push 'kill calls)))
              ((symbol-function 'easysession-switch-to) (lambda (n) (push (cons 'switch n) calls)))
              ((symbol-function 'cm/stash-load) (lambda () (push 'stash-load calls))))
      ;; target "B" has no session file on disk -> `created'
      (should (eq 'created (cm/session-switch-to-project "/tmp/b/")))
      (should (equal (reverse calls)
                     '(prompt stash-save session-save kill (switch . "B") stash-load))))))

;; --- advice / startup ------------------------------------------------------

(ert-deftest cm/session-advice--routes-to-flip ()
  "The advice calls the flip with the chosen dir; a `created' result opens a file."
  (let ((switched nil) (found nil))
    (cl-letf (((symbol-function 'cm/session-switch-to-project)
               (lambda (dir) (setq switched dir) 'created))
              ((symbol-function 'project-find-file) (lambda (&rest _) (setq found t))))
      (cm/session--project-switch-advice #'ignore "/tmp/new/")
      (should (equal switched "/tmp/new/"))
      (should found))))   ; 'created path kicks off project-find-file

(ert-deftest cm/session-startup--restores-existing-launch-project ()
  "Startup loads the stash, then restores the launch dir's session when it exists."
  (let ((loaded nil) (stash nil)
        (easysession-directory (make-temp-file "cm-sess" t)))
    ;; pretend the launch dir is project P and its session file exists
    (with-temp-file (expand-file-name "P" easysession-directory) (insert ""))
    (cl-letf (((symbol-function 'cm/stash-load) (lambda () (setq stash t)))
              ((symbol-function 'cm/session--root-of) (lambda (_) "/tmp/p/"))
              ((symbol-function 'cm/session-name-for-project) (lambda (_) "P"))
              ((symbol-function 'easysession-switch-to) (lambda (n) (setq loaded n))))
      (cm/session-startup)
      (should stash)
      (should (equal loaded "P")))))

(ert-deftest cm/session-startup--blank-when-no-saved-session ()
  "Startup does not switch when the launch project has no saved session yet."
  (let ((loaded nil)
        (easysession-directory (make-temp-file "cm-sess" t)))
    (cl-letf (((symbol-function 'cm/stash-load) #'ignore)
              ((symbol-function 'cm/session--root-of) (lambda (_) "/tmp/p/"))
              ((symbol-function 'cm/session-name-for-project) (lambda (_) "P"))
              ((symbol-function 'easysession-switch-to) (lambda (n) (setq loaded n))))
      (cm/session-startup)
      (should (null loaded)))))

;; --- integration: real easysession round-trip (skipped if not installed) ---

(ert-deftest cm/session-integration--scratch-handler-round-trip ()
  "With easysession present, a registered handler round-trips project scratch."
  (skip-unless (require 'easysession nil t))
  (let* ((easysession-directory (make-temp-file "cm-sess" t))
         (name "IT"))
    ;; register handlers the same way cm/project-sessions-setup does
    (cm/session--install-handlers)
    (unwind-protect
        (let ((buf (get-buffer-create "*scratch:IT:1*")))
          (with-current-buffer buf (insert "INTEGRATION"))
          (let ((easysession-switch-to-save-session nil)
                (easysession-confirm-new-session nil))
            (easysession-switch-to name))   ; create + set current
          (easysession-save name)
          (kill-buffer buf)
          (should-not (get-buffer "*scratch:IT:1*"))
          (easysession-load name)
          (should (equal "INTEGRATION"
                         (with-current-buffer "*scratch:IT:1*" (buffer-string)))))
      (when (get-buffer "*scratch:IT:1*") (kill-buffer "*scratch:IT:1*"))
      (delete-directory easysession-directory t))))

(provide 'cm-project-sessions-tests)
;;; cm-project-sessions-tests.el ends here
