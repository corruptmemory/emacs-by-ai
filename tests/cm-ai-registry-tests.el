;;; cm-ai-registry-tests.el --- Tests for cm-ai-registry  -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cm-ai-registry)

(ert-deftest cm/ai-registry-descriptor-has-core-fields ()
  (let* ((server-name "emacs-4242")
         (default-directory temporary-file-directory)
         (d (cm/ai-registry-descriptor)))
    (should (equal (alist-get 'server_name d) "emacs-4242"))
    (should (equal (alist-get 'pid d) (emacs-pid)))
    (should (stringp (alist-get 'project_root d)))
    (should (string-suffix-p "/" (alist-get 'project_root d)))))

(ert-deftest cm/ai-registry-write-read-roundtrip ()
  (let* ((dir (file-name-as-directory (make-temp-file "cmair" t)))
         (desc '((project_root . "/home/jim/projects/emacs-again/")
                 (server_name . "emacs-4242") (pid . 4242)
                 (socket . "/run/user/1000/emacs/emacs-4242")
                 (frame_title . "x") (started . "2026-08-28T20:00:00+0000")))
         (file (cm/ai-registry--write desc dir))
         (got (cm/ai-registry--read file)))
    (should (equal file (expand-file-name "emacs-4242.json" dir)))
    (should (equal (plist-get got :project_root) "/home/jim/projects/emacs-again/"))
    (should (equal (plist-get got :pid) 4242))
    (should (member file (cm/ai-registry--files* dir)))))

(provide 'cm-ai-registry-tests)
;;; cm-ai-registry-tests.el ends here
