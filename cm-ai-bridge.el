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

(provide 'cm-ai-bridge)
;;; cm-ai-bridge.el ends here
