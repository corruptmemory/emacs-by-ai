;;; cm-project-tags-tests.el --- Tests for cm-project-tags  -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'cm-project-tags)

(ert-deftest cm/project-tags-file--finds-root-tags ()
  "Returns the root TAGS path when one exists."
  (let* ((root (file-name-as-directory (make-temp-file "cmpt" t)))
         (tags (expand-file-name "TAGS" root)))
    (with-temp-file tags (insert "\n"))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) (list 'fake root)))
              ((symbol-function 'project-root) (lambda (_) root)))
      (should (equal (cm/project-tags-file root) tags)))))

(ert-deftest cm/project-tags-file--nil-when-absent ()
  "Returns nil when the project root has no TAGS."
  (let* ((root (file-name-as-directory (make-temp-file "cmpt" t))))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) (list 'fake root)))
              ((symbol-function 'project-root) (lambda (_) root)))
      (should (null (cm/project-tags-file root))))))

(ert-deftest cm/project-tags-file--nil-when-no-project ()
  "Returns nil when not inside a project."
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
    (should (null (cm/project-tags-file temporary-file-directory)))))

;; --- cascade backend + guard ------------------------------------------------

(defun cm/test-tags--project (index-files)
  "Make a temp project; etags-index INDEX-FILES (relative); return (ROOT . TAGS).
Writes `in.el' (in-tags-fn), `only.el' (only-grep-fn), `use.el', and a
`.dumbjump' marker.  Only INDEX-FILES are written into TAGS."
  (let* ((root (file-name-as-directory (make-temp-file "cmpt-proj" t)))
         (tags (expand-file-name "TAGS" root)))
    (make-directory (expand-file-name "src" root))
    (with-temp-file (expand-file-name "src/in.el" root)
      (insert "(defun in-tags-fn () 'a)\n"))
    (with-temp-file (expand-file-name "src/only.el" root)
      (insert "(defun only-grep-fn () 'b)\n"))
    (with-temp-file (expand-file-name "src/use.el" root)
      (insert "(in-tags-fn) (only-grep-fn)\n"))
    (with-temp-file (expand-file-name ".dumbjump" root) (insert ""))
    (let ((default-directory root))
      (apply #'call-process "etags" nil nil nil "-o" tags index-files))
    (cons root tags)))

(ert-deftest cm/project-tags-xref-backend--inactive-returns-nil ()
  (with-temp-buffer
    (should (null (cm/project-tags-xref-backend)))))

(ert-deftest cm/project-tags-xref-backend--active-returns-symbol ()
  (with-temp-buffer
    (setq-local cm/project-tags--active t)
    (should (eq 'cm/tags-cascade (cm/project-tags-xref-backend)))))

(ert-deftest cm/project-tags-xref-backend--yields-to-eglot ()
  (with-temp-buffer
    (setq-local cm/project-tags--active t)
    (setq-local eglot--managed-mode t)
    (should (null (cm/project-tags-xref-backend)))))

(ert-deftest cm/project-tags-cascade--etags-hit-is-direct ()
  (skip-unless (executable-find "etags"))
  (let* ((p (cm/test-tags--project '("src/in.el")))
         (root (car p)) (tags (cdr p)))
    (with-current-buffer (find-file-noselect (expand-file-name "src/use.el" root))
      (emacs-lisp-mode)
      (setq-local tags-table-list (list tags) tags-file-name tags)
      (let ((defs (xref-backend-definitions 'cm/tags-cascade "in-tags-fn")))
        (should (= 1 (length defs)))))))

(ert-deftest cm/project-tags-cascade--miss-falls-through-to-dumb-jump ()
  (skip-unless (and (executable-find "etags")
                    (executable-find "rg")
                    (require 'dumb-jump nil t)))
  ;; TAGS indexes only in.el, so `only-grep-fn' is absent and must come from
  ;; dumb-jump's grep of the .dumbjump project.
  (let* ((p (cm/test-tags--project '("src/in.el")))
         (root (car p)) (tags (cdr p)))
    (with-current-buffer (find-file-noselect (expand-file-name "src/use.el" root))
      (emacs-lisp-mode)
      (setq-local tags-table-list (list tags) tags-file-name tags)
      (let ((defs (xref-backend-definitions 'cm/tags-cascade "only-grep-fn")))
        (should (>= (length defs) 1))))))

(ert-deftest cm/project-tags-cascade--completion-from-etags ()
  (skip-unless (executable-find "etags"))
  (let* ((p (cm/test-tags--project '("src/in.el")))
         (root (car p)) (tags (cdr p)))
    (with-current-buffer (find-file-noselect (expand-file-name "src/use.el" root))
      (emacs-lisp-mode)
      (setq-local tags-table-list (list tags) tags-file-name tags)
      (let ((tbl (xref-backend-identifier-completion-table 'cm/tags-cascade)))
        (should (member "in-tags-fn" (all-completions "in-" tbl)))))))

;; --- activation -------------------------------------------------------------

(ert-deftest cm/project-tags-maybe-activate--installs-cascade ()
  (skip-unless (executable-find "etags"))
  (let* ((p (cm/test-tags--project '("src/in.el")))
         (root (car p)) (tags (cdr p))
         (src (expand-file-name "src/in.el" root)))
    (with-current-buffer (find-file-noselect src)
      (emacs-lisp-mode)
      (cl-letf (((symbol-function 'project-current) (lambda (&rest _) (list 'fake root)))
                ((symbol-function 'project-root) (lambda (_) root)))
        (cm/project-tags-maybe-activate))
      (should cm/project-tags--active)
      (should (equal tags-table-list (list tags)))
      (should (equal tags-file-name tags))
      (should (memq #'cm/project-tags-xref-backend xref-backend-functions)))))

(ert-deftest cm/project-tags-maybe-activate--noop-without-tags ()
  (with-temp-buffer
    (prog-mode)
    (cl-letf (((symbol-function 'cm/project-tags-file) (lambda (&rest _) nil)))
      (cm/project-tags-maybe-activate))
    (should (null cm/project-tags--active))
    (should-not (memq #'cm/project-tags-xref-backend xref-backend-functions))))

(ert-deftest cm/project-tags-maybe-activate--noop-in-non-prog-buffer ()
  (with-temp-buffer
    (fundamental-mode)
    (cl-letf (((symbol-function 'cm/project-tags-file)
               (lambda (&rest _) (error "should not be called in non-prog buffer"))))
      (cm/project-tags-maybe-activate))
    (should (null cm/project-tags--active))))

(provide 'cm-project-tags-tests)
;;; cm-project-tags-tests.el ends here
