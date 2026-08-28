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

(provide 'cm-ai-bridge)
;;; cm-ai-bridge.el ends here
