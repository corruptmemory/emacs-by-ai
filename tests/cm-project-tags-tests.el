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

(provide 'cm-project-tags-tests)
;;; cm-project-tags-tests.el ends here
