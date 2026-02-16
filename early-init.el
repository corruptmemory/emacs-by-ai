;;; early-init.el --- Early initialization -*- lexical-binding: t; no-byte-compile: t; -*-

;;; Commentary:
;; Runs before init.el and before the package system and UI are initialized.

;;; Code:

;; Temporarily increase the garbage collection threshold.  These
;; changes help shave off about half a second of startup time.  The
;; `most-positive-fixnum' is DANGEROUS AS A PERMANENT VALUE.  See the
;; `emacs-startup-hook' a few lines below for what I actually use.
(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.5)

(defvar my/file-name-handler-alist file-name-handler-alist
  "Original `file-name-handler-alist' value, restored after startup.")

;; Speed up startup by deferring expensive file name handlers.
(setq file-name-handler-alist nil)

(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 1000 1000 8)
                  gc-cons-percentage 0.1
                  file-name-handler-alist my/file-name-handler-alist)))

;; Do not initialise the package manager.
(setq package-enable-at-startup nil)

;; Suppress native compilation warnings.
(setq native-comp-async-report-warnings-errors 'silent)

;; Prefer newer source files and improve subprocess throughput.
(setq load-prefer-newer t
      read-process-output-max (* 1024 1024)
      process-adaptive-read-buffering nil
      inhibit-compacting-font-caches t)

;; Optimize display for predominantly left-to-right editing.
(setq bidi-inhibit-bpa t)
(setq-default bidi-display-reordering 'left-to-right
              bidi-paragraph-direction 'left-to-right)

;; Disable UI elements early via frame parameters (before frames are created).
(push '(menu-bar-lines . 0) default-frame-alist)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars) default-frame-alist)

(menu-bar-mode -1)
(scroll-bar-mode -1)
(tool-bar-mode -1)

;; Frame behaviour.
(setq frame-resize-pixelwise t
      frame-inhibit-implied-resize t
      frame-title-format '("%b")
      ring-bell-function 'ignore
      use-dialog-box nil
      use-file-dialog nil
      use-short-answers t
      inhibit-splash-screen t
      inhibit-startup-screen t
      inhibit-startup-message t
      inhibit-x-resources t
      inhibit-startup-echo-area-message user-login-name
      inhibit-startup-buffer-menu t)

;; Fringes, parens, and cursor.
(set-fringe-mode 5)
(show-paren-mode 1)
(setq-default cursor-type 'bar)

;;; early-init.el ends here
