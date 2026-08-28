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

(defconst cm/ai-package-version 1
  "Envelope version for `cm/ai-pkg' responses.")

(defun cm/ai-pkg (type payload &rest meta)
  "Build a self-describing response package.
TYPE is a symbol (elisp/text/markdown/json/error/ref); PAYLOAD is the value;
META is a plist of extra fields (e.g. :tick)."
  (list :v cm/ai-package-version :type type :payload payload :meta meta))

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
