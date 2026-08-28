;;; cm-ai-bridge-tests.el --- Tests for cm-ai-bridge  -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cm-ai-bridge)

(ert-deftest cm/ai-pkg-shape ()
  (let ((p (cm/ai-pkg 'text "hi" :tick 7)))
    (should (equal (plist-get p :v) 1))
    (should (eq (plist-get p :type) 'text))
    (should (equal (plist-get p :payload) "hi"))
    (should (equal (plist-get p :meta) '(:tick 7)))))

(ert-deftest cm/ai-with-package-catches-signal ()
  (let ((p (cm/ai-with-package (error "boom"))))
    (should (eq (plist-get p :type) 'error))
    (should (eq (plist-get (plist-get p :payload) :code) 'error))
    (should (string-match-p "boom" (plist-get (plist-get p :payload) :message)))))

(ert-deftest cm/ai-with-package-passes-value ()
  (let ((p (cm/ai-with-package (cm/ai-pkg 'elisp '(:ok t)))))
    (should (eq (plist-get p :type) 'elisp))
    (should (equal (plist-get p :payload) '(:ok t)))))

(ert-deftest cm/ai-resolve-buffer-by-name-path-and-nil ()
  (let* ((buf (generate-new-buffer "cm-ai-t-buf")))
    (unwind-protect
        (progn
          (should (eq (cm/ai--resolve-buffer "cm-ai-t-buf") buf))
          (should (null (cm/ai--resolve-buffer "no-such-buffer-xyz")))
          (should (eq (cm/ai--resolve-buffer nil) (window-buffer (selected-window)))))
      (kill-buffer buf)))
  ;; Test file-path resolution via find-buffer-visiting
  (let* ((tmp (make-temp-file "cm-ai-rb"))
         (fbuf (find-file-noselect tmp)))
    (unwind-protect
        (should (eq (cm/ai--resolve-buffer tmp) fbuf))
      (kill-buffer fbuf)
      (delete-file tmp))))

(ert-deftest cm/ai-pkg-ref-writes-file ()
  (let* ((cm/ai-exchange-dir (file-name-as-directory (make-temp-file "cmaix" t)))
         (p (cm/ai--pkg-ref "hello world" :buffer "x")))
    (should (eq (plist-get p :type) 'ref))
    (let ((pl (plist-get p :payload)))
      (should (eq (plist-get pl :of) 'text))
      (should (= (plist-get pl :bytes) (string-bytes "hello world")))
      (should (file-exists-p (plist-get pl :path)))
      (should (equal (with-temp-buffer (insert-file-contents (plist-get pl :path))
                       (buffer-string))
                     "hello world")))
    (should (equal (plist-get p :meta) '(:buffer "x")))))

(ert-deftest cm/ai-server-name-helper ()
  (let ((server-name "emacs-777"))
    (should (equal (cm/ai--server-name) "emacs-777"))))

(provide 'cm-ai-bridge-tests)
;;; cm-ai-bridge-tests.el ends here
