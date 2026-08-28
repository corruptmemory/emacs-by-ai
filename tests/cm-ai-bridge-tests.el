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
          (with-current-buffer buf
            ;; nil target = current/focused; in batch, selected-window's buffer
            (should (bufferp (cm/ai--resolve-buffer nil)))))
      (kill-buffer buf))))

(provide 'cm-ai-bridge-tests)
;;; cm-ai-bridge-tests.el ends here
