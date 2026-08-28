;;; cm-ai-bridge.el --- Typed packages + write path for the Emacs<->agent bridge  -*- lexical-binding: t; -*-
;;; Commentary:
;; The non-interactive core of the AI writing-assistant bridge: a typed elisp
;; "packages" reply protocol, the shared file-exchange helpers, the remote read
;; functions (returning packages), and a review-gated buffer write path.
;; The interactive C-c a commands and the *ai-suggestions* buffer live in init.el
;; and load this file first.
;; See docs/plans/2026-08-28-emacs-agents-bridge-design.md (Section C / C-write).
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'server)
(require 'diff-mode)

(declare-function org-back-to-heading "org")
(declare-function org-up-heading-safe "org")
(declare-function org-get-heading "org")

(defvar cm/ai-exchange-dir (expand-file-name "~/.emacs-ai/")
  "Directory for AI <-> Emacs file exchange.")

(defun cm/ai--ensure-dir ()
  "Create exchange directory if needed."
  (make-directory cm/ai-exchange-dir t))

(defun cm/ai--org-heading-path ()
  "Return breadcrumb list of org headings from root to point."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (let (path)
        (condition-case nil
            (while t
              (org-back-to-heading t)
              (push (substring-no-properties (org-get-heading t t t t)) path)
              (unless (org-up-heading-safe)
                (signal 'error nil)))
          (error nil))
        path))))

(defun cm/ai--server-name ()
  "Return the current Emacs server name, or nil."
  (and (boundp 'server-name) server-name))

(defconst cm/ai-package-version 1
  "Envelope version for `cm/ai-pkg' responses.")

(defun cm/ai-pkg (type payload &rest meta)
  "Build a self-describing response package.
TYPE is a symbol (elisp/text/markdown/json/error/ref); PAYLOAD is the value;
META is a plist of extra fields (e.g. :tick)."
  (list :v cm/ai-package-version :type type :payload payload :meta meta))

(defun cm/ai--pkg-ref (content &rest meta)
  "Write CONTENT to the exchange content.txt and return a `ref' package.
META is extra envelope metadata (e.g. :buffer / :tick)."
  (cm/ai--ensure-dir)
  (let ((path (expand-file-name "content.txt" cm/ai-exchange-dir)))
    (with-temp-file path (insert content))
    (apply #'cm/ai-pkg 'ref
           (list :path path :bytes (string-bytes content) :of 'text)
           meta)))

(defmacro cm/ai-with-package (&rest body)
  "Evaluate BODY (which should yield a package) and return it.
Any signal is converted to an `error' package instead of propagating."
  (declare (indent 0) (debug t))
  `(condition-case err
       (progn ,@body)
     (error (cm/ai-pkg 'error (list :code (car err)
                                    :message (error-message-string err))))))

(defun cm/ai--resolve-buffer (target)
  "Resolve TARGET to a live buffer, or nil.
TARGET is a buffer name, a file path (its visiting buffer), or nil for the
focused window's buffer."
  (cond
   ((null target) (window-buffer (selected-window)))
   ((get-buffer target))
   ((and (stringp target) (find-buffer-visiting target)))
   (t nil)))

;;;; Remote-query functions — called by Claude Code via emacsclient -e.
;; These let the AI inspect Emacs state without the user pressing anything.
;; Each returns a self-describing package (see `cm/ai-pkg'); pass `:as 'json'
;; to re-render the payload as a `json' package instead of the default type.

(defun cm/ai--render (pkg as)
  "If AS is `json', re-render PKG's payload as a `json' package; else PKG."
  (if (eq as 'json)
      (apply #'cm/ai-pkg 'json (json-encode (plist-get pkg :payload))
             (plist-get pkg :meta))
    pkg))

(defmacro cm/ai--on-target (target &rest body)
  "Resolve TARGET to a buffer, run BODY there, or return an unknown-target error."
  (declare (indent 1) (debug t))
  `(let ((buf (cm/ai--resolve-buffer ,target)))
     (if (not buf)
         (cm/ai-pkg 'error (list :code 'unknown-target
                                 :message (format "No live buffer for %S" ,target)))
       (with-current-buffer buf ,@body))))

(defun cm/ai--meta ()
  "Standard :meta plist for the current buffer (carries the base tick)."
  (list :buffer (buffer-name)
        :tick (buffer-chars-modified-tick)
        :server (cm/ai--server-name)))

(cl-defun cm/ai-current-context (&optional target &key as)
  "Return an elisp package describing TARGET's editing context."
  (cm/ai-with-package
    (cm/ai--on-target target
      (let* ((region-p (use-region-p))
             (payload (list :file (or (buffer-file-name) "")
                            :buffer (buffer-name)
                            :mode (symbol-name major-mode)
                            :line (line-number-at-pos)
                            :column (current-column)
                            :org-path (cm/ai--org-heading-path)
                            :modified (buffer-modified-p)
                            :region (when region-p
                                      (list :start-line (line-number-at-pos (region-beginning))
                                            :end-line (line-number-at-pos (region-end))
                                            :chars (- (region-end) (region-beginning)))))))
        (cm/ai--render (apply #'cm/ai-pkg 'elisp payload (cm/ai--meta)) as)))))

(cl-defun cm/ai-visible-buffers (&key as)
  "Return an elisp package of all visible buffers across frames."
  (cm/ai-with-package
    (let (result)
      (walk-windows
       (lambda (win)
         (let ((b (window-buffer win)))
           (push (list :file (or (buffer-file-name b) "")
                       :buffer (buffer-name b)
                       :mode (symbol-name (buffer-local-value 'major-mode b))
                       :selected (eq win (selected-window)))
                 result)))
       nil t)
      (cm/ai--render (cm/ai-pkg 'elisp (nreverse result)) as))))

(cl-defun cm/ai-get-content (&optional target &key as)
  "Snapshot TARGET's content (or active region) to content.txt.
Return a `ref' package."
  (ignore as)
  (cm/ai-with-package
    (cm/ai--on-target target
      (let* ((region-p (use-region-p))
             (content (if region-p
                          (buffer-substring-no-properties (region-beginning) (region-end))
                        (buffer-substring-no-properties (point-min) (point-max)))))
        (apply #'cm/ai--pkg-ref content
               (append (cm/ai--meta)
                       (list :scope (if region-p 'region 'buffer)
                             :mode (symbol-name major-mode)
                             :file (or (buffer-file-name) ""))))))))

(cl-defun cm/ai-paragraph-at-point (&optional target &key as)
  "Return a text package with the paragraph at point in TARGET."
  (cm/ai-with-package
    (cm/ai--on-target target
      (save-excursion
        (let ((beg (progn (backward-paragraph) (skip-chars-forward "\n") (point)))
              (end (progn (forward-paragraph) (skip-chars-backward "\n") (point))))
          (cm/ai--render (apply #'cm/ai-pkg 'text
                                (buffer-substring-no-properties beg end)
                                (cm/ai--meta))
                         as))))))

(cl-defun cm/ai-line-at-point (&optional target &key as)
  "Return a text package with the current line in TARGET."
  (cm/ai-with-package
    (cm/ai--on-target target
      (cm/ai--render (apply #'cm/ai-pkg 'text
                            (buffer-substring-no-properties
                             (line-beginning-position) (line-end-position))
                            (cm/ai--meta))
                     as))))

(cl-defun cm/ai-region-or-paragraph (&optional target &key as)
  "Return an elisp package: region text if active, else the paragraph at point."
  (cm/ai-with-package
    (cm/ai--on-target target
      (let* ((region-p (use-region-p))
             (text (if region-p
                       (buffer-substring-no-properties (region-beginning) (region-end))
                     (save-excursion
                       (let ((beg (progn (backward-paragraph) (skip-chars-forward "\n") (point)))
                             (end (progn (forward-paragraph) (skip-chars-backward "\n") (point))))
                         (buffer-substring-no-properties beg end))))))
        (cm/ai--render (apply #'cm/ai-pkg 'elisp
                              (list :scope (if region-p 'region 'paragraph)
                                    :text text :chars (length text))
                              (cm/ai--meta))
                       as)))))

(cl-defun cm/ai-org-subtree-at-point (&optional target &key as)
  "Return a text package with the org subtree at point, or a not-org-mode error."
  (cm/ai-with-package
    (cm/ai--on-target target
      (if (not (derived-mode-p 'org-mode))
          (cm/ai-pkg 'error (list :code 'not-org-mode
                                  :message "Target buffer is not in org-mode"))
        (save-excursion
          (org-back-to-heading t)
          (let ((beg (point)))
            (org-end-of-subtree t t)
            (cm/ai--render (apply #'cm/ai-pkg 'text
                                  (buffer-substring-no-properties beg (point))
                                  (cm/ai--meta))
                           as)))))))

(cl-defun cm/ai-nearby-lines (&optional target n &key as)
  "Return a text package: N lines (default 5) around point in TARGET.
The current line is marked with an arrow."
  (cm/ai-with-package
    (cm/ai--on-target target
      (let* ((n (or n 5))
             (cur (line-number-at-pos))
             (beg (save-excursion (forward-line (- n)) (point)))
             (end (save-excursion (forward-line (1+ n)) (point)))
             (lines (split-string (buffer-substring-no-properties beg end) "\n"))
             (start-line (- cur n))
             (out '()))
        (dotimes (i (length lines))
          (let* ((lnum (+ start-line i))
                 (prefix (if (= lnum cur) "→" " ")))
            (push (format "%s %4d: %s" prefix lnum (nth i lines)) out)))
        (cm/ai--render (apply #'cm/ai-pkg 'text
                              (mapconcat #'identity (nreverse out) "\n")
                              (cm/ai--meta))
                       as)))))

(declare-function org-end-of-subtree "org")

;;;; Write path — DWIM auto/review edit application.

(defcustom cm/ai-apply-auto-max-hunks 1
  "Auto-apply an AI edit only if it touches at most this many diff hunks."
  :type 'integer :group 'tools)

(defcustom cm/ai-apply-auto-max-lines 8
  "Auto-apply an AI edit only if it changes at most this many lines."
  :type 'integer :group 'tools)

(defun cm/ai--unified-diff (old new)
  "Return the unified diff string from OLD text to NEW text."
  (let ((fa (make-temp-file "ai-diff-a")) (fb (make-temp-file "ai-diff-b")))
    (unwind-protect
        (progn
          (with-temp-file fa (insert old))
          (with-temp-file fb (insert new))
          (with-temp-buffer
            (call-process "diff" nil t nil "-u" fa fb)
            (buffer-string)))
      (ignore-errors (delete-file fa))
      (ignore-errors (delete-file fb)))))

(defun cm/ai--diff-stats (old new)
  "Return (:hunks H :lines L) between OLD and NEW text."
  (let ((hunks 0) (lines 0))
    (dolist (ln (split-string (cm/ai--unified-diff old new) "\n"))
      (cond
       ((string-prefix-p "@@" ln) (setq hunks (1+ hunks)))
       ((and (> (length ln) 0)
             (memq (aref ln 0) '(?+ ?-))
             (not (string-prefix-p "+++" ln))
             (not (string-prefix-p "---" ln)))
        (setq lines (1+ lines)))))
    (list :hunks hunks :lines lines)))

(defun cm/ai--apply-decision (stats review read-only)
  "Return `auto' or `review' for STATS, honoring REVIEW override + READ-ONLY."
  (cond
   ((eq review 'force) 'review)
   ((eq review 'skip) 'auto)
   (read-only 'review)
   ((and (<= (plist-get stats :hunks) cm/ai-apply-auto-max-hunks)
         (<= (plist-get stats :lines) cm/ai-apply-auto-max-lines))
    'auto)
   (t 'review)))

(defun cm/ai--replace-contents (buf text)
  "Minimally replace BUF's contents with TEXT (preserves point/markers/undo).
Uses `replace-region-contents' (preferred over the now-31.1-obsolete
`replace-buffer-contents') — same non-destructive-replacement contract,
no byte-compile deprecation warning."
  (with-current-buffer buf
    (replace-region-contents (point-min) (point-max) text)))

(defun cm/ai-apply-edit (target base-tick edit-spec &optional review)
  "Apply EDIT-SPEC to TARGET buffer under optimistic concurrency (BASE-TICK).
EDIT-SPEC is (:kind full :text NEW-TEXT).  Returns a package: an `applied'
elisp package (auto path), a `pending' elisp package (review path), or an
`error' package (unknown-target / stale-buffer / unsupported-kind)."
  (cm/ai-with-package
    (let ((buf (cm/ai--resolve-buffer target)))
      (cond
       ((not buf)
        (cm/ai-pkg 'error (list :code 'unknown-target
                                :message (format "No live buffer for %S" target))))
       ((not (eq (plist-get edit-spec :kind) 'full))
        (cm/ai-pkg 'error (list :code 'unsupported-kind
                                :message (format "Unsupported edit kind: %S"
                                                 (plist-get edit-spec :kind)))))
       (t
        (with-current-buffer buf
          (if (/= (buffer-chars-modified-tick) base-tick)
              (cm/ai-pkg 'error (list :code 'stale-buffer
                                      :message "Buffer changed since read; re-read and retry"
                                      :expected base-tick
                                      :actual (buffer-chars-modified-tick)))
            (let* ((proposed (plist-get edit-spec :text))
                   (current (buffer-substring-no-properties (point-min) (point-max)))
                   (stats (cm/ai--diff-stats current proposed))
                   (decision (cm/ai--apply-decision stats review buffer-read-only)))
              (if (eq decision 'auto)
                  (progn
                    (cm/ai--replace-contents buf proposed)
                    (cm/ai-pkg 'elisp (list :status 'applied
                                            :hunks (plist-get stats :hunks)
                                            :lines (plist-get stats :lines))))
                (let ((rbuf (cm/ai--make-review-buffer buf proposed base-tick current)))
                  (cm/ai-pkg 'elisp (list :status 'pending
                                          :review-buffer (buffer-name rbuf)
                                          :hunks (plist-get stats :hunks)
                                          :lines (plist-get stats :lines)))))))))))))

;;;; Review gate — diff-mode buffer + human apply/reject.

(defvar-local cm/ai-edit--target nil "Target buffer for a pending AI edit.")
(defvar-local cm/ai-edit--proposed nil "Proposed full text for a pending AI edit.")
(defvar-local cm/ai-edit--base-tick nil "Buffer tick captured when the edit was proposed.")

(defvar cm/ai-edit-review-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m diff-mode-map)
    (define-key m (kbd "C-c C-c") #'cm/ai-edit-apply)
    (define-key m (kbd "C-c C-k") #'cm/ai-edit-reject)
    m)
  "Keymap for the AI edit review buffer.")

(defun cm/ai--make-review-buffer (buf proposed base-tick current)
  "Create and display a review buffer diffing CURRENT vs PROPOSED for BUF.
Returns the review buffer."
  (let* ((name (format "*ai-edit:%s*" (buffer-name buf)))
         (rbuf (get-buffer-create name)))
    (with-current-buffer rbuf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (cm/ai--unified-diff current proposed)))
      (goto-char (point-min))
      (diff-mode)
      (use-local-map cm/ai-edit-review-mode-map)
      (setq buffer-read-only t
            cm/ai-edit--target buf
            cm/ai-edit--proposed proposed
            cm/ai-edit--base-tick base-tick)
      (setq header-line-format
            (substitute-command-keys
             "AI edit — \\[cm/ai-edit-apply] apply · \\[cm/ai-edit-reject] reject")))
    (display-buffer rbuf)
    rbuf))

(defun cm/ai-edit-apply ()
  "Apply the pending AI edit shown in this review buffer to its target."
  (interactive)
  (let ((buf cm/ai-edit--target)
        (proposed cm/ai-edit--proposed)
        (base-tick cm/ai-edit--base-tick))
    (unless (buffer-live-p buf) (user-error "Target buffer is gone"))
    (with-current-buffer buf
      (when (/= (buffer-chars-modified-tick) base-tick)
        (user-error "Target changed since the edit was proposed; not applying")))
    (cm/ai--replace-contents buf proposed)
    (let ((n (buffer-name buf)))
      (kill-buffer (current-buffer))
      (message "AI edit applied to %s" n))))

(defun cm/ai-edit-reject ()
  "Discard the pending AI edit shown in this review buffer."
  (interactive)
  (let ((n (and (buffer-live-p cm/ai-edit--target) (buffer-name cm/ai-edit--target))))
    (kill-buffer (current-buffer))
    (message "AI edit rejected%s" (if n (format " for %s" n) ""))))

(provide 'cm-ai-bridge)
;;; cm-ai-bridge.el ends here
