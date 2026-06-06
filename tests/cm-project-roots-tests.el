;;; cm-project-roots-tests.el --- Tests for cm-project-roots  -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cm-project-roots)

(ert-deftest cm/project-roots-harness-loads ()
  "The library loads and the marker constant is defined."
  (should (equal cm/project-roots-file ".project-roots")))

(ert-deftest cm/project-roots--parse-handles-comments-blanks-paths ()
  (should (equal
           (cm/project-roots--parse
            "# full comment\n\n/abs/dir\nrel/dir\n~/home-dir  # trailing\n" "/base")
           (list "/abs/dir" "/base/rel/dir" (expand-file-name "~/home-dir")))))

(defun cm/test--make-tree ()
  "Create a temp project tree; return its root dir (absolute, slash-terminated)."
  (let* ((root (file-name-as-directory (make-temp-file "cmpr" t))))
    (make-directory (expand-file-name "extra" root))
    (with-temp-file (expand-file-name ".project-roots" root)
      (insert "extra\nnonexistent-dir\n"))
    root))

(ert-deftest cm/project-roots--from-file-skips-missing ()
  (let* ((root (cm/test--make-tree))
         (got (cm/project-roots--from-file (expand-file-name ".project-roots" root))))
    (should (member (file-name-as-directory root) got))
    (should (member (file-name-as-directory (expand-file-name "extra" root)) got))
    (should-not (member (file-name-as-directory (expand-file-name "nonexistent-dir" root)) got))))

(ert-deftest cm/project-roots-falls-back-without-file ()
  (let ((default-directory temporary-file-directory))
    (should (= 1 (length (cm/project-roots))))))

(ert-deftest cm/project-add-root--append-dedups ()
  (let* ((file (make-temp-file "cmpr-roots"))
         (dir  (file-name-as-directory (make-temp-file "cmpr-d" t)))
         (abbr (abbreviate-file-name dir)))
    (cm/project-add-root--append file dir)
    (cm/project-add-root--append file dir) ; second add must be a no-op
    (let ((lines (with-temp-buffer (insert-file-contents file)
                   (split-string (buffer-string) "\n" t))))
      (should (equal (cl-count abbr lines :test #'equal) 1)))))

(ert-deftest cm/eglot--prefer-lsp-when-capable ()
  (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t))
            ((symbol-function 'eglot-server-capable) (lambda (&rest _) t)))
    (let ((current-prefix-arg nil))
      (should (eq 'lsp (cm/eglot--prefer :x (lambda () 'lsp) (lambda () 'fb)))))))

(ert-deftest cm/eglot--prefer-fallback-when-unmanaged ()
  (cl-letf (((symbol-function 'eglot-managed-p) (lambda () nil)))
    (should (eq 'fb (cm/eglot--prefer :x (lambda () 'lsp) (lambda () 'fb))))))

(ert-deftest cm/eglot--prefer-prefix-forces-fallback ()
  (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t))
            ((symbol-function 'eglot-server-capable) (lambda (&rest _) t)))
    (let ((current-prefix-arg '(4)))
      (should (eq 'fb (cm/eglot--prefer :x (lambda () 'lsp) (lambda () 'fb)))))))

(ert-deftest cm/eglot--prefer-user-error-falls-back ()
  (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t))
            ((symbol-function 'eglot-server-capable) (lambda (&rest _) t)))
    (should (eq 'fb (cm/eglot--prefer :x (lambda () (user-error "none")) (lambda () 'fb))))))

(ert-deftest cm/project-find-file--candidates-spans-roots ()
  (skip-unless (executable-find "rg"))
  (let* ((a (file-name-as-directory (make-temp-file "cmpr-a" t)))
         (b (file-name-as-directory (make-temp-file "cmpr-b" t))))
    (with-temp-file (expand-file-name "alpha.txt" a) (insert "x"))
    (with-temp-file (expand-file-name "beta.txt" b) (insert "y"))
    (let ((files (cm/project-find-file--candidates (list a b))))
      (should (cl-some (lambda (f) (string-suffix-p "alpha.txt" f)) files))
      (should (cl-some (lambda (f) (string-suffix-p "beta.txt" f)) files)))))

(provide 'cm-project-roots-tests)
;;; cm-project-roots-tests.el ends here
