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

(ert-deftest cm/ai-current-context-package ()
  (with-temp-buffer
    (insert "line one\nline two\n") (goto-char (point-min))
    (rename-buffer "cm-ai-ctx" t)
    (let* ((p (cm/ai-current-context (buffer-name)))
           (pl (plist-get p :payload)))
      (should (eq (plist-get p :type) 'elisp))
      (should (equal (plist-get pl :buffer) "cm-ai-ctx"))
      (should (equal (plist-get pl :line) 1))
      ;; base-tick is exposed in meta for the write path
      (should (integerp (plist-get (plist-get p :meta) :tick))))))

(ert-deftest cm/ai-line-at-point-text-package ()
  (with-temp-buffer
    (insert "alpha\nbeta\n") (goto-char (point-min)) (rename-buffer "cm-ai-line" t)
    (let ((p (cm/ai-line-at-point (buffer-name))))
      (should (eq (plist-get p :type) 'text))
      (should (equal (plist-get p :payload) "alpha")))))

(ert-deftest cm/ai-org-subtree-not-org-is-error ()
  (with-temp-buffer
    (fundamental-mode) (rename-buffer "cm-ai-noorg" t)
    (let ((p (cm/ai-org-subtree-at-point (buffer-name))))
      (should (eq (plist-get p :type) 'error))
      (should (eq (plist-get (plist-get p :payload) :code) 'not-org-mode)))))

(ert-deftest cm/ai-get-content-is-ref ()
  (let ((cm/ai-exchange-dir (file-name-as-directory (make-temp-file "cmaix" t))))
    (with-temp-buffer
      (insert "body text") (rename-buffer "cm-ai-gc" t)
      (let* ((p (cm/ai-get-content (buffer-name)))
             (pl (plist-get p :payload)))
        (should (eq (plist-get p :type) 'ref))
        (should (file-exists-p (plist-get pl :path)))
        (should (equal (plist-get (plist-get p :meta) :buffer) "cm-ai-gc"))))))

(ert-deftest cm/ai-unknown-target-is-error ()
  (let ((p (cm/ai-current-context "no-such-buffer-xyz")))
    (should (eq (plist-get p :type) 'error))
    (should (eq (plist-get (plist-get p :payload) :code) 'unknown-target))))

(ert-deftest cm/ai-json-rendering-on-request ()
  (with-temp-buffer
    (insert "x") (rename-buffer "cm-ai-json" t)
    (let ((p (cm/ai-current-context (buffer-name) :as 'json)))
      (should (eq (plist-get p :type) 'json))
      (should (stringp (plist-get p :payload)))
      (should (string-match-p "cm-ai-json" (plist-get p :payload)))
      (should (integerp (plist-get (plist-get p :meta) :tick))))))

(ert-deftest cm/ai-diff-stats-counts ()
  (let ((s (cm/ai--diff-stats "a\nb\nc\n" "a\nB\nc\n")))
    (should (= (plist-get s :hunks) 1))
    (should (>= (plist-get s :lines) 2))))  ; -b +B

(ert-deftest cm/ai-apply-decision-thresholds ()
  (let ((cm/ai-apply-auto-max-hunks 1) (cm/ai-apply-auto-max-lines 8))
    (should (eq (cm/ai--apply-decision '(:hunks 1 :lines 2) 'auto nil) 'auto))
    (should (eq (cm/ai--apply-decision '(:hunks 3 :lines 2) 'auto nil) 'review))
    (should (eq (cm/ai--apply-decision '(:hunks 1 :lines 40) 'auto nil) 'review))
    (should (eq (cm/ai--apply-decision '(:hunks 1 :lines 2) 'force nil) 'review))
    (should (eq (cm/ai--apply-decision '(:hunks 9 :lines 9) 'skip nil) 'auto))
    (should (eq (cm/ai--apply-decision '(:hunks 1 :lines 1) 'auto t) 'review))))  ; read-only

(ert-deftest cm/ai-apply-edit-auto-applies ()
  (with-temp-buffer
    (insert "one\ntwo\nthree\n") (rename-buffer "cm-ai-apply" t)
    (let* ((tick (buffer-chars-modified-tick))
           (p (cm/ai-apply-edit (buffer-name) tick
                                '(:kind full :text "one\nTWO\nthree\n") 'auto)))
      (should (eq (plist-get p :type) 'elisp))
      (should (eq (plist-get (plist-get p :payload) :status) 'applied))
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     "one\nTWO\nthree\n")))))

(ert-deftest cm/ai-apply-edit-stale-tick-errors ()
  (with-temp-buffer
    (insert "x\n") (rename-buffer "cm-ai-stale" t)
    (let ((p (cm/ai-apply-edit (buffer-name) 999999
                               '(:kind full :text "y\n") 'auto)))
      (should (eq (plist-get p :type) 'error))
      (should (eq (plist-get (plist-get p :payload) :code) 'stale-buffer)))))

(ert-deftest cm/ai-apply-edit-unknown-target-errors ()
  (let ((p (cm/ai-apply-edit "no-such-buf" 1 '(:kind full :text "z") 'auto)))
    (should (eq (plist-get p :type) 'error))
    (should (eq (plist-get (plist-get p :payload) :code) 'unknown-target))))

(ert-deftest cm/ai-apply-edit-review-returns-pending ()
  (with-temp-buffer
    (insert "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n") (rename-buffer "cm-ai-rev" t)
    (let* ((tick (buffer-chars-modified-tick))
           ;; force review regardless of size
           (p (cm/ai-apply-edit (buffer-name) tick
                                '(:kind full :text "A\nB\nc\nd\ne\nf\ng\nh\ni\nj\n") 'force))
           (pl (plist-get p :payload)))
      (should (eq (plist-get p :type) 'elisp))
      (should (eq (plist-get pl :status) 'pending))
      (let ((rbuf (get-buffer (plist-get pl :review-buffer))))
        (should (buffer-live-p rbuf))
        ;; buffer still unchanged until the human applies
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n"))
        ;; apply it and confirm the target changes
        (with-current-buffer rbuf (cm/ai-edit-apply))
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "A\nB\nc\nd\ne\nf\ng\nh\ni\nj\n"))))))

(ert-deftest cm/ai-edit-apply-refuses-stale ()
  (with-temp-buffer
    (insert "orig\n") (rename-buffer "cm-ai-rev2" t)
    (let* ((tick (buffer-chars-modified-tick))
           (p (cm/ai-apply-edit (buffer-name) tick '(:kind full :text "new\n") 'force))
           (rbuf (get-buffer (plist-get (plist-get p :payload) :review-buffer))))
      ;; mutate the target after the review was created -> apply must refuse
      (insert "sneaky\n")
      (with-current-buffer rbuf
        (should-error (cm/ai-edit-apply) :type 'user-error))
      ;; target keeps its (mutated) content, edit not applied
      (should (string-match-p "sneaky" (buffer-string))))))

(provide 'cm-ai-bridge-tests)
;;; cm-ai-bridge-tests.el ends here
