;;; init.el --- Main configuration -*- lexical-binding: t; no-byte-compile: t; -*-

;;; Commentary:
;; Main Emacs configuration, loaded after early-init.el.

;;; Code:

;;;; Startup time display.
(add-hook 'emacs-startup-hook
          (lambda ()
            (message "Emacs loaded in %s with %d garbage collections."
                     (format "%.2f seconds"
                             (float-time
                              (time-subtract after-init-time before-init-time)))
                     gcs-done)))

;;;; Bootstrap straight.el.
(defvar bootstrap-version)
(let ((bootstrap-file
       (expand-file-name
        "straight/repos/straight.el/bootstrap.el"
        (or (bound-and-true-p straight-base-dir)
            user-emacs-directory)))
      (bootstrap-version 7))
  (unless (file-exists-p bootstrap-file)
    (with-current-buffer
        (url-retrieve-synchronously
         "https://raw.githubusercontent.com/radian-software/straight.el/develop/install.el"
         'silent 'inhibit-cookies)
      (goto-char (point-max))
      (eval-print-last-sexp)))
  (load bootstrap-file nil 'nomessage))

;;;; use-package integration.
;; Force core libraries to use Emacs built-ins, avoiding straight duplicates.
(straight-use-package '(project :type built-in))
(straight-use-package '(xref :type built-in))
(straight-use-package 'use-package)
(setq straight-use-package-by-default t)

;;;; Custom file.
(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(when (file-exists-p custom-file)
  (load custom-file nil 'nomessage))

;;;; Local machine-specific overrides (not tracked).
(defvar cm/mouse-profile 'wheel
  "Scrolling profile for this machine. Expected values: `wheel' or `trackpad'.")

(let ((local-settings-file (expand-file-name "local-settings.el" user-emacs-directory)))
  (when (file-exists-p local-settings-file)
    (load local-settings-file nil 'nomessage)))

;;;; Keep backup, auto-save, and lock files out of working directories.
(let ((saves-dir (expand-file-name "saves/" user-emacs-directory)))
  (make-directory saves-dir t)
  (setq backup-directory-alist `(("." . ,saves-dir))
        auto-save-file-name-transforms `((".*" ,saves-dir t))
        lock-file-directory saves-dir))

;;;; Trust dir-local variables and eval blocks.
(setq enable-local-variables :all
      enable-local-eval t)

;;;; Remove training wheels from useful commands.
(put 'narrow-to-region 'disabled nil)
(put 'downcase-region 'disabled nil)

;;;; Don't prompt on quit — Emacs restarts just fine.
(setq confirm-kill-emacs nil)

;;;; Shell configuration — use fish where appropriate.
(setq shell-file-name (executable-find "bash"))
(setq-default vterm-shell "/usr/bin/fish")
(setq-default explicit-shell-file-name "/usr/bin/fish")

;;;; Auto-revert buffers when files change on disk.
(global-auto-revert-mode 1)

;;;; Replace active region when typing.
(delete-selection-mode 1)

;;;; Electric indent — re-indent automatically on newline and certain characters.
;; On by default in Emacs 29+; made explicit for clarity.
(electric-indent-mode 1)

;;;; Tab display/indent defaults.
;; Keep literal tab characters visually narrow unless a mode overrides it.
(setq-default tab-width 4)
;; TAB indents normally, but triggers completion when indentation is not applicable.
(setq tab-always-indent 'complete)

;;;; Highlight current line.
(global-hl-line-mode 1)

;;;; Recent files.
(use-package recentf
  :straight nil
  :custom
  (recentf-save-file (expand-file-name "recentf" user-emacs-directory))
  (recentf-max-saved-items 20)
  (recentf-exclude '("\\.zip\\'" "\\.gz\\'" "\\.tar\\'" "\\.tar\\.gz\\'"
                     "\\.tar\\.bz2\\'" "\\.tar\\.xz\\'" "\\.tgz\\'"
                     "\\.7z\\'" "\\.rar\\'" "\\.jar\\'"))
  :init
  (add-hook 'after-init-hook #'recentf-mode))

;;;; Save point position in files across sessions.
(use-package saveplace
  :straight nil
  :custom
  (save-place-file (expand-file-name "saveplace" user-emacs-directory))
  :init
  (save-place-mode 1))

;;;; Per-instance server for external scripting (not daemon mode).
;; Each Emacs gets a unique server name based on its PID so external
;; scripts can target a specific instance via emacsclient -s <name>.
(use-package server
  :straight nil
  :config
  (defun cm/clean-stale-server-sockets ()
    "Remove server sockets for Emacs PIDs that are no longer running."
    (let ((dir (or server-socket-dir
                   (format "/run/user/%d/emacs" (user-uid))
                   (format "/tmp/emacs%d" (user-uid)))))
      (when (file-directory-p dir)
        (dolist (sock (directory-files dir t "\\`emacs-[0-9]+\\'"))
          (let ((pid (string-to-number
                      (substring (file-name-nondirectory sock)
                                 (length "emacs-")))))
            (unless (or (= pid (emacs-pid))
                        (and (> pid 0)
                             (file-exists-p (format "/proc/%d" pid))))
              (delete-file sock)
              (message "Cleaned stale server socket: %s"
                       (file-name-nondirectory sock))))))))
  (cm/clean-stale-server-sockets)
  (setq server-name (format "emacs-%d" (emacs-pid)))
  (unless (server-running-p)
    (server-start))
  (defvar cm/last-used-file (expand-file-name "~/.emacs-last-used")
    "File recording the server-name of the most recently focused Emacs.")
  (defun cm/record-last-used-emacs ()
    "Write current `server-name' to `cm/last-used-file' on focus."
    (with-temp-file cm/last-used-file
      (insert server-name)))
  (add-hook 'focus-in-hook #'cm/record-last-used-emacs))

;;;; PATH configuration.
(dolist (dir '("~/.cargo/bin"
               "~/.local/bin"
               "~/go/bin"
               "~/projects/Odin"
               "~/projects/ols"))
  (let ((expanded (expand-file-name dir)))
    (unless (member expanded exec-path)
      (push expanded exec-path))
    (unless (string-match-p (regexp-quote expanded) (getenv "PATH"))
      (setenv "PATH" (concat expanded ":" (getenv "PATH"))))))

;;;; Theme load path.
(add-to-list 'custom-theme-load-path
             (expand-file-name "themes/" user-emacs-directory))

;;;; Theme.
(load-theme 'dracula-pro-blade t)

;;;; Theme-derived fringe contrast.
(require 'color)

(defvar cm/fringe-contrast-threshold 0.08
  "HSL lightness threshold for deciding whether a background is light-ish.")

(defvar cm/fringe-darken-amount 24
  "Percent used to darken fringe background on light-ish themes.")

(defvar cm/fringe-lighten-amount 12
  "Percent used to lighten fringe background on dark-ish themes.")

(defun cm/apply-complementary-fringe-background (&rest _)
  "Set fringe background to a contrasting shade of the default background."
  (let* ((default-bg (face-background 'default nil 'default))
         (rgb (and (stringp default-bg) (color-name-to-rgb default-bg))))
    (when rgb
      (let* ((hsl (apply #'color-rgb-to-hsl rgb))
             (lightness (nth 2 hsl))
             (light-ish (>= lightness cm/fringe-contrast-threshold))
             (fringe-bg (if light-ish
                            (color-darken-name default-bg cm/fringe-darken-amount)
                          (color-lighten-name default-bg cm/fringe-lighten-amount))))
        (set-face-attribute 'fringe nil :background fringe-bg)))))

(advice-add 'load-theme :after #'cm/apply-complementary-fringe-background)
(cm/apply-complementary-fringe-background)

;;;; Fonts.
;;(set-face-attribute 'default nil :family "TX-02" :height 130)
(set-face-attribute 'default nil :font "TX-02-14")
(set-face-attribute 'variable-pitch nil :family "Fira Sans" :height 130)
(set-fontset-font t 'emoji (font-spec :family "JoyPixels") nil 'prepend)

;;;; Smooth scrolling (built-in pixel precision + horizontal wheel support).
(defun cm/apply-scrolling-profile ()
  "Apply scrolling settings from `cm/mouse-profile'."
  (pcase cm/mouse-profile
    ('trackpad
     (setq pixel-scroll-precision-use-momentum t
           pixel-scroll-precision-interpolate-page nil
           pixel-scroll-precision-interpolate-mice t
           mouse-wheel-progressive-speed nil
           mouse-wheel-tilt-scroll t
           mouse-wheel-flip-direction t
           mouse-wheel-scroll-amount '(1 ((shift) . hscroll))
           mouse-wheel-scroll-amount-horizontal 2))
    (_
     ;; Wheel profile favors immediate response over interpolation.
     (setq pixel-scroll-precision-use-momentum nil
           pixel-scroll-precision-interpolate-page nil
           pixel-scroll-precision-interpolate-mice nil
           mouse-wheel-progressive-speed nil
           mouse-wheel-tilt-scroll t
           mouse-wheel-flip-direction nil
           mouse-wheel-scroll-amount '(1 ((shift) . hscroll))
           mouse-wheel-scroll-amount-horizontal 2)))
  (pixel-scroll-precision-mode 1))

(cm/apply-scrolling-profile)

;;;; which-key.
(use-package which-key
  :config
  (which-key-mode))

;;;; windmove — directional window navigation.
(global-set-key (kbd "M-s-<left>") #'windmove-left)
(global-set-key (kbd "M-s-<right>") #'windmove-right)
(global-set-key (kbd "M-s-<up>") #'windmove-up)
(global-set-key (kbd "M-s-<down>") #'windmove-down)

;;;; Toggle window split orientation.
(defun cm/toggle-window-split ()
  "Toggle a two-window frame between horizontal and vertical split.
Preserves buffer contents, scroll positions, and selection."
  (interactive)
  (unless (= (count-windows) 2)
    (user-error "Can only toggle with exactly 2 windows"))
  (let* ((win1 (selected-window))
         (win2 (next-window win1 nil (selected-frame)))
         (state1 (window-state-get win1))
         (state2 (window-state-get win2))
         (e1 (window-edges win1))
         (e2 (window-edges win2))
         (vertical-p (= (car e1) (car e2))))
    (delete-other-windows win1)
    (let ((new-win (if vertical-p
                       (split-window-horizontally)
                     (split-window-vertically))))
      (window-state-put state1 (selected-window))
      (window-state-put state2 new-win)
      (select-window win1))))

(global-set-key (kbd "C-c |") #'cm/toggle-window-split)

;;;; Quick toggles — C-c T prefix.
(defvar cm/toggles-map (make-sparse-keymap)
  "Keymap for quick mode toggles under `C-c T'.")
(global-set-key (kbd "C-c T") cm/toggles-map)
(define-key cm/toggles-map (kbd "w") #'visual-line-mode)
(define-key cm/toggles-map (kbd "t") #'toggle-truncate-lines)
(define-key cm/toggles-map (kbd "s") #'whitespace-mode)
(define-key cm/toggles-map (kbd "f") #'flyspell-mode)
(defun cm/toggle-scrolling-profile ()
  "Toggle `cm/mouse-profile' between `trackpad' and `wheel' and re-apply."
  (interactive)
  (setq cm/mouse-profile (if (eq cm/mouse-profile 'trackpad) 'wheel 'trackpad))
  (cm/apply-scrolling-profile)
  (message "Scrolling profile: %s" cm/mouse-profile))
(define-key cm/toggles-map (kbd "m") #'cm/toggle-scrolling-profile)

;;;; Word motion/deletion tuned for editor-like chunk behavior.
(defun cm/relevant-match-syntax (in)
  "Return syntax spec string for IN used by chunk movement/deletion."
  (if (or (eq in ?\s) (eq in ?>))
      " >"
    (char-to-string in)))

(defun cm/move-right ()
  "Move right by syntax chunk."
  (interactive "^")
  (unless (eobp)
    (let ((syntax (cm/relevant-match-syntax (char-syntax (char-after)))))
      (skip-syntax-forward syntax))))

(defun cm/move-left ()
  "Move left by syntax chunk."
  (interactive "^")
  (unless (bobp)
    (let ((syntax (cm/relevant-match-syntax (char-syntax (char-before)))))
      (skip-syntax-backward syntax))))

(defun cm/backward-delete-word ()
  "Delete backward by syntax chunk."
  (interactive)
  (unless (bobp)
    (let ((end (point))
          (syntax (cm/relevant-match-syntax (char-syntax (char-before)))))
      (skip-syntax-backward syntax)
      (delete-region (point) end))))

(defun cm/delete-word ()
  "Delete forward by syntax chunk."
  (interactive)
  (unless (eobp)
    (let ((start (point))
          (syntax (cm/relevant-match-syntax (char-syntax (char-after)))))
      (skip-syntax-forward syntax)
      (delete-region start (point)))))

(defun cm/move-line (n)
  "Move current line by N lines, preserving column when possible."
  (let ((line (line-number-at-pos))
        (last-line (line-number-at-pos (point-max)))
        (col (current-column)))
    (cond
     ((and (< n 0) (= line 1))
      (user-error "Already at top of buffer"))
     ((and (> n 0) (>= line last-line))
      (user-error "Already at bottom of buffer"))
     (t
      (beginning-of-line)
      (let* ((start (point))
             (_ (forward-line 1))
             (text (delete-and-extract-region start (point))))
        (forward-line n)
        (let ((insert-pos (point)))
          (insert text)
          (goto-char insert-pos)
          (move-to-column col t)))))))

(defun cm/move-line-up ()
  "Move current line up by one line."
  (interactive)
  (cm/move-line -1))

(defun cm/move-line-down ()
  "Move current line down by one line."
  (interactive)
  (cm/move-line 1))

(global-set-key (kbd "C-<right>") #'cm/move-right)
(global-set-key (kbd "C-<left>") #'cm/move-left)
(global-set-key (kbd "C-<backspace>") #'cm/backward-delete-word)
(global-set-key (kbd "C-<delete>") #'cm/delete-word)
(global-set-key (kbd "M-<up>") #'cm/move-line-up)
(global-set-key (kbd "M-<down>") #'cm/move-line-down)
(global-set-key (kbd "C-M-'") #'forward-sexp)
(global-set-key (kbd "C-M-;") #'backward-sexp)
(global-set-key (kbd "M-d") #'duplicate-dwim)

;;;; Function-key bindings.
(global-set-key (kbd "<f2>") #'browse-url)
(global-set-key (kbd "<f3>") #'kmacro-start-macro)
(global-set-key (kbd "S-<f3>") #'kmacro-end-macro)
(global-set-key (kbd "<f4>") #'kmacro-end-and-call-macro)
(global-set-key (kbd "<f5>") #'project-compile)
(global-set-key (kbd "<f6>") #'flyspell-buffer)
(global-set-key (kbd "<f9>") #'next-error)
(global-set-key (kbd "<f10>") #'previous-error)

(defun cm/format-buffer ()
  "Organize imports (if available) and format via eglot."
  (interactive)
  (cm/eglot-organize-imports)
  (ignore-errors (eglot-format))
  (message "... formatted"))

(global-set-key (kbd "<f12>") #'cm/format-buffer)

;;;; Vertico — vertical minibuffer completion UI.
(use-package vertico
  :init
  (vertico-mode)
  :custom
  (vertico-cycle t))

;;;; vertico-directory — improved minibuffer directory editing.
(use-package vertico-directory
  :straight nil
  :after vertico
  :bind (:map vertico-map
              ("RET"   . vertico-directory-enter)
              ("DEL"   . vertico-directory-delete-char)
              ("M-DEL" . vertico-directory-delete-word))
  :hook (rfn-eshadow-update-overlay . vertico-directory-tidy))

;;;; vertico-repeat — repeat prior minibuffer sessions.
(use-package vertico-repeat
  :straight nil
  :after vertico
  :init
  (add-hook 'minibuffer-setup-hook #'vertico-repeat-save)
  :bind (("M-R" . vertico-repeat)
         :map vertico-map
         ("M-r" . vertico-repeat-select)))

;;;; vertico-multiform — command-specific completion UIs.
(use-package vertico-multiform
  :straight nil
  :after vertico
  :init
  (vertico-multiform-mode 1))

;;;; Orderless — flexible completion matching.
(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles partial-completion)))))

;;;; Marginalia — rich annotations in the minibuffer.
(use-package marginalia
  :init
  (marginalia-mode))

;;;; savehist — persist minibuffer/command history across sessions.
(use-package savehist
  :straight nil
  :init
  (savehist-mode 1))

;;;; prescient — sort by recent/frequent usage.
(use-package prescient
  :custom
  (prescient-history-length 1000)
  (prescient-save-file (expand-file-name "prescient-save.el" user-emacs-directory))
  :config
  (prescient-persist-mode 1))

;;;; vertico-prescient — apply prescient sorting to Vertico/M-x.
(use-package vertico-prescient
  :after (vertico prescient)
  :config
  (vertico-prescient-mode 1))

;;;; Consult seed helpers.
(defvar cm/consult-region-max-chars 180
  "Maximum region size used to seed Consult input.")

(defun cm/consult-region-seed ()
  "Return a normalized active-region seed for Consult, or nil.
Seeding is skipped for multi-line or very large regions."
  (when (use-region-p)
    (let* ((raw (buffer-substring-no-properties (region-beginning) (region-end)))
           (text (string-trim raw)))
      (when (and (> (length text) 0)
                 (<= (length text) cm/consult-region-max-chars)
                 (not (string-match-p "\n" text)))
        text))))

(defun cm/consult-line-dwim ()
  "Run `consult-line' seeded from region when appropriate."
  (interactive)
  (consult-line (cm/consult-region-seed)))

(defun cm/consult-git-grep-dwim ()
  "Run `consult-git-grep' seeded from region when appropriate."
  (interactive)
  (consult-git-grep nil (cm/consult-region-seed)))

(defun cm/consult-ripgrep-dwim ()
  "Run `consult-ripgrep' seeded from region when appropriate."
  (interactive)
  (consult-ripgrep nil (cm/consult-region-seed)))

(defun cm/consult-find-dwim ()
  "Run `consult-find' seeded from region when appropriate."
  (interactive)
  (consult-find nil (cm/consult-region-seed)))

(defun cm/thing-at-point-seed ()
  "Return symbol-at-point, falling back to word-at-point, or nil."
  (or (thing-at-point 'symbol t)
      (thing-at-point 'word t)))

(defun cm/project-root-or-default ()
  "Return current project root when available, else `default-directory'."
  (if-let* ((project (project-current nil)))
      (project-root project)
    default-directory))

(defun cm/consult-ripgrep-thing-at-point-literal ()
  "Run `consult-ripgrep' using thing-at-point as a literal pattern."
  (interactive)
  (let ((thing (cm/thing-at-point-seed)))
    (consult-ripgrep nil (and thing (regexp-quote thing)))))

(defun cm/consult-ripgrep-thing-at-point-regexp ()
  "Run `consult-ripgrep' using thing-at-point as a regexp pattern."
  (interactive)
  (consult-ripgrep nil (cm/thing-at-point-seed)))

(defun cm/consult-ripgrep-sql-thing-at-point-literal ()
  "Search SQL files in the project using thing-at-point as literal input."
  (interactive)
  (let* ((thing (cm/thing-at-point-seed))
         (initial (and thing (regexp-quote thing)))
         (root (cm/project-root-or-default))
         (consult-ripgrep-args
          (concat consult-ripgrep-args " --glob=*.sql --glob=*.psql")))
    (consult-ripgrep root initial)))

;;;; Consult — enhanced minibuffer commands.
(use-package consult
  :custom
  (xref-show-xrefs-function #'consult-xref)
  (xref-show-definitions-function #'consult-xref)
  :bind
  (("C-S-s"   . cm/consult-line-dwim)
   ("C-x b"   . consult-buffer)
   ("C-x p b" . consult-project-buffer)
   ("C-x C-r" . consult-recent-file)
   ("C-x 4 b" . consult-buffer-other-window)
   ("M-g g"   . consult-goto-line)
   ("M-g M-g" . consult-goto-line)
   ("M-g e"   . consult-compile-error)
   ("M-g i"   . consult-imenu)
   ("C-c h"   . consult-history)
   ("C-c s"   . cm/consult-ripgrep-dwim)
   ("M-s ."   . cm/consult-ripgrep-thing-at-point-literal)
   ("M-s ,"   . cm/consult-ripgrep-thing-at-point-regexp)
   ("M-s q"   . cm/consult-ripgrep-sql-thing-at-point-literal)
   ("M-s g"   . cm/consult-git-grep-dwim)
   ("M-s r"   . cm/consult-ripgrep-dwim)
   ("M-s f"   . cm/consult-find-dwim)
   ("M-y"     . consult-yank-pop)))

;;;; Embark — contextual actions in minibuffer and buffers.
(use-package embark
  :init
  (setq prefix-help-command #'embark-prefix-help-command)
  :bind
  (("C-." . embark-act)
   ("C-;" . embark-dwim)
   ("C-h B" . embark-bindings)))

;;;; embark-consult — export/preview integration for Consult candidates.
(use-package embark-consult
  :after (embark consult)
  :hook (embark-collect-mode . consult-preview-at-point-mode))

;;;; Avy — fast jump-to-char/word/line navigation.
(use-package avy
  :custom
  (avy-background t)
  :bind
  (("M-j"   . avy-goto-char-timer)
   ("M-g w" . avy-goto-word-1)
   ("M-g e" . avy-goto-line)))

;;;; Ace-window — quick window switching and dispatch actions.
(use-package ace-window
  :custom
  (aw-scope 'frame)
  (aw-dispatch-always nil)
  (aw-keys '(?a ?s ?d ?f ?j ?k ?l))
  :bind
  ([remap other-window] . ace-window)
  ("M-o" . ace-window))

;;;; Corfu — in-buffer completion popup.
(use-package corfu
  :custom
  (corfu-auto nil)
  (corfu-cycle t)
  (corfu-preselect 'prompt)
  :init
  (global-corfu-mode))

;;;; corfu-history — rank candidates by prior selections.
(use-package corfu-history
  :straight nil
  :after corfu
  :init
  (corfu-history-mode 1))

;;;; corfu-popupinfo — inline documentation popup for Corfu candidates.
(use-package corfu-popupinfo
  :straight nil
  :after corfu
  :custom
  (corfu-popupinfo-delay '(0.7 . 0.3))
  :init
  (corfu-popupinfo-mode 1))

;;;; tempel — lightweight templates integrated with completion.
(use-package tempel
  :bind
  (("M-+" . tempel-complete)
   ("M-*" . tempel-insert))
  :init
  (defun cm/tempel-setup-capf ()
    "Add Tempel completion to the front of local CAPF list."
    (setq-local completion-at-point-functions
                (cons #'tempel-complete completion-at-point-functions)))
  :hook
  ((prog-mode . cm/tempel-setup-capf)
   (text-mode . cm/tempel-setup-capf)))

(use-package tempel-collection
  :after tempel)

;;;; kind-icon — icons for completion candidates.
(use-package kind-icon
  :after corfu
  :custom
  (kind-icon-default-face 'corfu-default)
  :config
  (add-to-list 'corfu-margin-formatters #'kind-icon-margin-formatter))

;;;; Multiple-cursors.
(use-package multiple-cursors
  :custom
  (mc/always-run-for-all t)
  :bind
  (("C->"         . mc/mark-next-like-this)
   ("C-<"         . mc/mark-previous-like-this)
   ("C-c C-<"     . mc/mark-all-like-this)
   ("C-S-c C-S-c" . mc/edit-lines)
   ("C-M->"       . mc/mark-next-like-this-symbol)
   ("C-M-<"       . mc/mark-previous-like-this-symbol)
   ("C-\""        . mc/skip-to-next-like-this)
   ("C-:"         . mc/skip-to-previous-like-this)))

;;;; expand-region — semantic region expansion/shrinking.
(use-package expand-region
  :bind
  (("C-=" . er/expand-region)
   ("C--" . er/contract-region)))

;;;; string-inflection — cycle between snake/camel/pascal/kebab cases.
(use-package string-inflection
  :bind
  (:map prog-mode-map
        ("C-c C-u" . string-inflection-all-cycle)))

;;;; smartparens — auto-pairing and structured editing of delimiters.
(use-package smartparens
  :init
  (smartparens-global-mode 1)
  :config
  (require 'smartparens-config))

;;;; Spell checking — flyspell in text-like modes only.
;;; Use F6 to run flyspell-buffer on demand.
(use-package flyspell
  :straight nil
  :hook
  ((text-mode . flyspell-mode)
   (org-mode . flyspell-mode)
   (markdown-mode . flyspell-mode)))

;;;; Magit — Git interface.
(use-package magit
  :bind
  (("C-x g" . magit-status)))

;;;; Helpful — better help buffers.
(use-package helpful
  :bind
  ([remap describe-function] . helpful-callable)
  ([remap describe-variable] . helpful-variable)
  ([remap describe-key]      . helpful-key)
  ([remap describe-command]  . helpful-command))

;;;; Popper — popup buffer management.
(defun cm/popper-group-by-project-or-directory ()
  "Group popups by project when available, otherwise by directory."
  (condition-case nil
      (popper-group-by-project)
    (error (popper-group-by-directory))))

(use-package popper
  :bind
  (("C-`"   . popper-toggle)
   ("M-`"   . popper-cycle)
   ("C-M-`" . popper-toggle-type))
  :custom
  (popper-group-function #'cm/popper-group-by-project-or-directory)
  (popper-reference-buffers
   '("\\*Messages\\*"
     "\\*Warnings\\*"
     "\\*Embark Actions\\*"
     "\\*Embark Collect \\(Live\\|Completions\\)\\*"
     "\\*Occur\\*"
     "\\*SQL: \\(?:<[^>]+>\\|[^*]+\\)\\*"
     "Output\\*$"
     "\\*Async Shell Command\\*"
     help-mode
     helpful-mode
     compilation-mode))
  :init
  (popper-mode)
  (popper-echo-mode))

;;;; vterm — terminal emulator.
(use-package vterm
  :custom
  (vterm-max-scrollback 10000))

;;;; diff-hl — highlight uncommitted changes in the fringe.
(use-package diff-hl
  :custom
  (diff-hl-side 'left)
  :hook
  ((magit-pre-refresh  . diff-hl-magit-pre-refresh)
   (magit-post-refresh . diff-hl-magit-post-refresh)
   (dired-mode         . diff-hl-dired-mode))
  :init
  (global-diff-hl-mode)
  :config
  (diff-hl-flydiff-mode 1))

;;;; all-the-icons.
(use-package all-the-icons
  :if (display-graphic-p))

;;;; all-the-icons-dired.
(use-package all-the-icons-dired
  :after all-the-icons
  :hook (dired-mode . all-the-icons-dired-mode))

;;;; ws-butler — unobtrusive whitespace trimming.
(use-package ws-butler
  :hook (prog-mode . ws-butler-mode))

;;;; editorconfig — respect .editorconfig project settings.
(use-package editorconfig
  :init
  (editorconfig-mode 1))

;;;; wgrep — editable grep buffers (useful with Embark-Consult exports).
(use-package wgrep)

;;;; hl-todo — highlight important note tags.
(use-package hl-todo
  :custom
  (hl-todo-keyword-faces
   '(("TODO"    . "#ffb86c")
     ("FIXME"   . "#ff5555")
     ("BUG"     . "#ff5555")
     ("NOTE"    . "#8be9fd")
     ("NB"      . "#8be9fd")
     ("XXX"     . "#ff79c6")
     ("FEATURE" . "#50fa7b")))
  :hook
  ((prog-mode     . hl-todo-mode)
   (text-mode     . hl-todo-mode)
   (markdown-mode . hl-todo-mode)
   (org-mode      . hl-todo-mode))
  :config
  ;; Restrict prog-mode highlighting to comments only (exclude strings).
  (advice-add 'hl-todo--inside-comment-or-string-p
              :override
              (lambda () (nth 4 (syntax-ppss)))))

;;;; Doom modeline.
(use-package doom-modeline
  :init
  (doom-modeline-mode))

;;;; nav-flash — briefly highlight the cursor line after large motions.
(use-package nav-flash
  :hook
  ((imenu-after-jump . nav-flash-show)
   (better-jumper-post-jump . nav-flash-show)
   (xref-after-return . nav-flash-show)
   (xref-after-jump . nav-flash-show))
  :config
  (advice-add 'recenter :after (lambda (&rest _) (nav-flash-show))))

;;;; Tree-sitter — automatic grammar installation and mode remapping.
(defun cm/sanitize-auto-mode-alist ()
  "Remove invalid `auto-mode-alist' entries introduced by third-party code.
Valid entries must have a regexp string as their car."
  (setq auto-mode-alist
        (cl-remove-if-not
         (lambda (entry)
           (and (consp entry)
                (stringp (car entry))))
         auto-mode-alist)))

(use-package treesit-auto
  :custom
  (treesit-auto-install t)
  :config
  (treesit-auto-add-to-auto-mode-alist 'all)
  (global-treesit-auto-mode)
  (cm/sanitize-auto-mode-alist))

;;;; yasnippet — snippet expansion (used by eglot for LSP snippets).
(use-package yasnippet
  :hook (prog-mode . yas-minor-mode))

(use-package yasnippet-snippets
  :after yasnippet)

;;;; Cape — additional completion-at-point sources.
(use-package cape
  :init
  (add-to-list 'completion-at-point-functions #'cape-file)
  (add-to-list 'completion-at-point-functions #'cape-dabbrev))

;;;; Eglot — built-in LSP client.
;;;; -----------------------------------------------------------------------
;;;; Xref Integration Policy
;;;; -----------------------------------------------------------------------
;; 1) In eglot-managed buffers, prefer LSP/xref only.
;; 2) In non-LSP prog buffers, allow xref-union + dumb-jump fallback.
;; 3) In sql-mode, keep custom SQL reference commands on `M-?' / `C-c ? s'.
;;    (Those commands are explicit and separate from xref backend plumbing.)

(defun cm/xref-union-disable-in-eglot-managed-buffer ()
  "Disable `xref-union-mode' when Eglot manages the current buffer."
  (when (bound-and-true-p xref-union-mode)
    (xref-union-mode -1)))

(defun cm/xref-union-excluded-backend-p (backend-fn)
  "Return non-nil when BACKEND-FN should be excluded from xref-union."
  (or (eq backend-fn #'etags--xref-backend)
      ;; In LSP-managed buffers, avoid dumb-jump/rg shadowing Eglot xref.
      (and (bound-and-true-p eglot--managed-mode)
           (eq backend-fn #'dumb-jump-xref-activate))))

(use-package eglot
  :straight nil
  :hook
  ((go-ts-mode
    c-ts-mode
    c++-ts-mode
    python-ts-mode
    bash-ts-mode
    yaml-ts-mode
    rust-ts-mode
    cmake-ts-mode
    js-ts-mode
    typescript-ts-mode
    tsx-ts-mode
    dockerfile-ts-mode
    lua-ts-mode
    html-ts-mode
    css-ts-mode
    java-ts-mode
    zig-mode
    odin-mode
    haskell-mode
    jai-mode
    templ-ts-mode) . eglot-ensure)
  :custom
  (eglot-extend-to-xref t)
  (eglot-autoshutdown t)
  (eglot-autoreconnect t)
  :bind (:map eglot-mode-map
              ("C-c e r" . eglot-rename)
              ("C-c e a" . eglot-code-actions)
              ("C-c e f" . eglot-format)
              ("C-c e i" . eglot-find-implementation)
              ("C-c e o" . eglot-code-action-organize-imports))
  :config
  (add-hook 'eglot-managed-mode-hook
            #'cm/xref-union-disable-in-eglot-managed-buffer)
  (add-to-list 'eglot-server-programs '(odin-mode . ("ols")))
  (add-to-list 'eglot-server-programs '(zig-mode . ("zls")))
  (add-to-list 'eglot-server-programs '(templ-ts-mode . ("templ" "lsp")))
  (add-to-list 'eglot-server-programs '(glsl-mode . ("glslls" "--stdin")))
  (add-to-list 'eglot-server-programs '(fish-mode . ("fish-lsp" "start")))
  (add-to-list 'eglot-server-programs
               '((haskell-mode) . ("haskell-language-server-wrapper" "--lsp")))
  (add-to-list 'eglot-server-programs
               `(jai-mode . (,(expand-file-name "~/projects/Jails/bin/jails")
                             "-jai_path" ,(expand-file-name "~/jai/jai/")
                             "-jai_exe_name" ,(pcase system-type
                                               ('gnu/linux "jai-linux")
                                               ('darwin "jai-macos")
                                               ('windows-nt "jai.exe")
                                               (_ "jai-linux")))))
  ;; Harper — grammar/spell checking for writing modes.
  ;; Requires: sudo pacman -S harper (provides harper-ls)
  (add-to-list 'eglot-server-programs
               '((org-mode markdown-mode gfm-mode text-mode) . ("harper-ls" "--stdio"))))

;;;; Harper eglot hooks — enable grammar checking in writing modes.
(when (executable-find "harper-ls")
  (dolist (hook '(org-mode-hook markdown-mode-hook gfm-mode-hook))
    (add-hook hook #'eglot-ensure)))

;;;; dumb-jump — xref fallback for languages without stable LSP/tags.
(use-package dumb-jump
  :custom
  (dumb-jump-prefer-searcher 'rg)
  :config
  ;; Append so language-aware backends (e.g. Eglot) run first.
  (add-hook 'xref-backend-functions #'dumb-jump-xref-activate t))

;;;; xref-union — combine xref backends (Eglot + dumb-jump fallback).
(use-package xref-union
  :custom
  (xref-union-excluded-backends #'cm/xref-union-excluded-backend-p)
  :hook
  ((prog-mode . xref-union-mode)
   (sql-mode . xref-union-mode)))

;;;; eglot-booster — faster JSON parsing for LSP communication.
;; Requires: cargo install emacs-lsp-booster
(use-package eglot-booster
  :straight (:host github :repo "jdtsmith/eglot-booster")
  :after eglot
  :config
  (eglot-booster-mode))

;;;; consult-eglot — workspace symbol search.
(use-package consult-eglot
  :after (consult eglot)
  :bind (:map eglot-mode-map
              ("C-c e s" . consult-eglot-symbols)))

;;;; eldoc-box — floating documentation at point.
(use-package eldoc-box
  :after eglot
  :bind (:map eglot-mode-map
              ("C-c e h" . eldoc-box-help-at-point)))

;;;; Flymake keybindings (built-in, used by eglot for diagnostics).
(use-package flymake
  :straight nil
  :bind (:map flymake-mode-map
              ("C-c ! n" . flymake-goto-next-error)
              ("C-c ! p" . flymake-goto-prev-error)
              ("C-c ! l" . consult-flymake)
              ("C-c ! L" . flymake-show-project-diagnostics)))

;;;; Dape — Debug Adapter Protocol client.
(use-package dape
  :bind
  (("C-c d d" . dape)
   ("C-c d t" . cm/dape-go-debug-test-at-point)
   ("C-c d m" . cm/dape-go-debug-main)
   ("C-c d p" . cm/dape-go-debug-package-tests)))

;;;; Go Dape wrappers.
(defun cm/go-test-name-at-point ()
  "Return enclosing Go test name like `TestFoo', or nil."
  (save-excursion
    (end-of-line)
    (when (re-search-backward
           "^func[[:space:]]+\\(Test[[:alnum:]_]+\\)[[:space:]]*("
           nil t)
      (match-string-no-properties 1))))

(defun cm/go-test-func-line ()
  "Return the line number of the enclosing Go test function signature, or nil."
  (save-excursion
    (end-of-line)
    (when (re-search-backward
           "^func[[:space:]]+Test[[:alnum:]_]+[[:space:]]*("
           nil t)
      (line-number-at-pos (point)))))

(defun cm/dape-go-debug-test-at-point ()
  "Debug Go test at point using Delve via Dape.
Automatically places a breakpoint on the test function's first line
if one isn't already set there."
  (interactive)
  (require 'dape)
  (let ((test (cm/go-test-name-at-point)))
    (unless test
      (user-error "No Go test function found at point"))
    ;; Ensure a breakpoint exists on the test function's opening line.
    (when-let* ((func-line (cm/go-test-func-line)))
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- func-line))
        ;; Move to the line after the signature (first line of body).
        (forward-line 1)
        (unless (dape--breakpoints-at-point)
          (dape-breakpoint-toggle))))
    (let ((pkg-dir (file-name-directory (buffer-file-name))))
      (dape `(modes (go-mode go-ts-mode)
               command "dlv"
               command-args ("dap" "--listen" "127.0.0.1::autoport")
               command-cwd ,pkg-dir
               command-insert-stderr t
               port :autoport
               :request "launch"
               :type "go"
               :mode "test"
               :cwd ,pkg-dir
               :program "."
               :args ["-test.run" ,(format "^%s$" test)])))))

(defun cm/dape-go-debug-main ()
  "Debug Go main/package with optional build tags and CLI args using Dape."
  (interactive)
  (let* ((tags (string-trim (read-string "Build tags (empty for none): ")))
         (args-input (string-trim (read-string "Program args: ")))
         (program-args (if (string-empty-p args-input)
                           []
                         (vconcat (split-string-and-unquote args-input))))
         (build-flags (if (string-empty-p tags)
                          ""
                        (concat "-tags=" tags))))
    (let ((pkg-dir (file-name-directory (buffer-file-name))))
      (dape `(modes (go-mode go-ts-mode)
               command "dlv"
               command-args ("dap" "--listen" "127.0.0.1::autoport")
               command-cwd ,pkg-dir
               command-insert-stderr t
               port :autoport
               :request "launch"
               :type "go"
               :mode "debug"
               :cwd ,pkg-dir
               :program "."
               :args ,program-args
               :buildFlags ,build-flags)))))

(defun cm/dape-go-debug-package-tests ()
  "Debug Go package tests, with optional build tags and -test.run pattern."
  (interactive)
  (let* ((tags (string-trim (read-string "Build tags (empty for none): ")))
         (test-run (string-trim (read-string "Test run regex (empty for all): ")))
         (build-flags (if (string-empty-p tags)
                          ""
                        (concat "-tags=" tags)))
         (args (if (string-empty-p test-run)
                   []
                 `["-test.run" ,test-run])))
    (let ((pkg-dir (file-name-directory (buffer-file-name))))
      (dape `(modes (go-mode go-ts-mode)
               command "dlv"
               command-args ("dap" "--listen" "127.0.0.1::autoport")
               command-cwd ,pkg-dir
               command-insert-stderr t
               port :autoport
               :request "launch"
               :type "go"
               :mode "test"
               :cwd ,pkg-dir
               :program "."
               :args ,args
               :buildFlags ,build-flags)))))

;;; -----------------------------------------------------------------------
;;; Language configurations
;;; -----------------------------------------------------------------------

;;;; Go.
;; go-ts-mode and go-mod-ts-mode are built-in; gopls is eglot's default.
(setq go-ts-mode-indent-offset 4)

(defun cm/eglot-organize-imports ()
  "Run gopls organize-imports code action via eglot, if available."
  (when (eglot-managed-p)
    (condition-case nil
        (eglot-code-action-organize-imports (point-min) (point-max))
      (t nil))))

(add-hook 'go-ts-mode-hook
          (lambda ()
            (setq-local tab-width 4)
            (setq-local indent-tabs-mode t)
            (add-hook 'before-save-hook #'cm/eglot-organize-imports nil t)
            (add-hook 'before-save-hook #'eglot-format nil t)))

(use-package gotest
  :after go-ts-mode
  :bind (:map go-ts-mode-map
              ("C-c t t" . go-test-current-test)
              ("C-c t f" . go-test-current-file)
              ("C-c t p" . go-test-current-project)))

;;;; go-templ.
(use-package templ-ts-mode
  :straight (:host github :repo "danderson/templ-ts-mode"))

;;;; GLSL.
(use-package glsl-mode)

;;;; SQL.
;; SQL buffers should always indent with spaces, never literal tabs.
(setq sql-product 'postgres)

(defun cm/sql--sqli-buffer-or-error ()
  "Return active SQLi buffer or raise a user error."
  (or (sql-find-sqli-buffer)
      (user-error "No SQL interactive buffer found")))

(defun cm/sql--object-bounds ()
  "Return bounds of SQL identifier/object at point."
  (save-excursion
    (let ((origin (point)))
      (goto-char origin)
      (skip-chars-backward "[:alnum:]_$.")
      (let ((beg (point)))
        (goto-char origin)
        (skip-chars-forward "[:alnum:]_$.")
        (cons beg (point))))))

(defun cm/sql-refresh-completions (&optional schema)
  "Refresh SQL object/column completion cache for optional SCHEMA."
  (interactive)
  (let ((sqlbuf (cm/sql--sqli-buffer-or-error)))
    (with-current-buffer sqlbuf
      (setq-local sql-completion-object nil)
      (setq-local sql-completion-column nil)
      (sql-build-completions schema)
      (message "SQL completions refreshed (%d objects)"
               (length sql-completion-object)))))

;;;; SQL xref helpers.
(defconst cm/sql-xref-rg-globs
  '("*.go" "*.py" "*.ts" "*.tsx" "*.js" "*.jsx" "*.java" "*.scala"
    "*.sql" "*.psql" "*.yaml" "*.yml" "*.json" "*.toml")
  "File globs to search for SQL object references in project files.")

(defconst cm/sql-xref-sql-only-globs
  '("*.sql" "*.psql")
  "File globs to search only SQL files for references.")

(defcustom cm/sql-xref-strict-identifiers nil
  "When non-nil, use stricter token-like matching for plain identifiers."
  :type 'boolean
  :group 'sql)

(defun cm/sql--project-root ()
  "Return best-effort project root for SQL reference searches."
  (expand-file-name
   (or
    (when-let* ((project (project-current nil)))
      (project-root project))
    (let ((dir (file-truename default-directory)))
      (or (locate-dominating-file dir ".git")
          (locate-dominating-file dir "go.mod")
          (locate-dominating-file dir "pyproject.toml")
          (locate-dominating-file dir "package.json")
          (locate-dominating-file dir ".projectile")))
    default-directory)))

(defun cm/sql--identifier-at-point ()
  "Return SQL object-like identifier near point, without text properties."
  (let* ((bounds (cm/sql--object-bounds))
         (beg (car bounds))
         (end (cdr bounds))
         (ident (buffer-substring-no-properties beg end)))
    (unless (string-empty-p ident)
      ident)))

(defun cm/sql--normalize-identifier (identifier)
  "Normalize IDENTIFIER from xref to a usable string, or nil."
  (let ((id (cond
             ((stringp identifier) identifier)
             ((symbolp identifier) (symbol-name identifier))
             (t nil))))
    (when id
      (let ((trimmed (string-trim id)))
        (unless (string-empty-p trimmed)
          trimmed)))))

(defun cm/sql--identifier-search-variants (identifier)
  "Return likely search variants for SQL IDENTIFIER in non-SQL code."
  (let* ((raw (cm/sql--normalize-identifier identifier))
         (dequoted (replace-regexp-in-string "\"" "" raw))
         (parts (split-string dequoted "\\." t))
         (leaf (car (last parts)))
         (variants (list raw dequoted)))
    ;; In code, SQL objects are often referenced without schema qualification.
    (when (and leaf (not (string= leaf dequoted)))
      (push leaf variants))
    (delete-dups (seq-filter (lambda (s) (and s (not (string-empty-p s)))) variants))))

(defun cm/sql--reference-files (root &optional globs)
  "Return candidate files under ROOT for SQL reference searching.
Optional GLOBS overrides `cm/sql-xref-rg-globs'."
  (let* ((search-root (expand-file-name root))
         (file-globs (or globs cm/sql-xref-rg-globs))
         (files
         (if (executable-find "rg")
             (let ((args (append '("--files")
                                 (mapcar (lambda (glob) (concat "--glob=" glob))
                                         file-globs)
                                 (list search-root))))
               (ignore-errors (apply #'process-lines "rg" args)))
           (directory-files-recursively search-root ".*" t))))
    (seq-filter #'file-regular-p (or files '()))))

(defun cm/sql--identifier-regexp (identifier)
  "Build a practical regexp for IDENTIFIER references."
  (let* ((variants (cm/sql--identifier-search-variants identifier))
         (parts
          (mapcar
           (lambda (v)
             (let ((q (regexp-quote v)))
               (if (and cm/sql-xref-strict-identifiers
                        (string-match-p "\\`[a-zA-Z_][a-zA-Z0-9_]*\\'" v))
                   (format "\\(^\\|[^[:alnum:]_$]\\)\\(%s\\)\\([^[:alnum:]_$]\\|$\\)" q)
                 q)))
           variants)))
    (string-join parts "\\|")))

(defun cm/sql--xref-collect (identifier &optional globs)
  "Collect xref candidates for IDENTIFIER across project files.
Optional GLOBS narrows searched file types."
  (let* ((root (cm/sql--project-root))
         (files (cm/sql--reference-files root globs))
         (regexp (cm/sql--identifier-regexp identifier))
         (case-fold-search nil))
    (if (null files)
        (user-error "No candidate files found under %s" root)
      (xref-matches-in-files regexp files))))

;;;; SQL xref interactive commands.
(defun cm/sql-find-references (&optional prefix identifier)
  "Find IDENTIFIER references across project files from SQL buffers.
Uses project file scanning and displays matches via xref."
  (interactive "P")
  (let* ((default (cm/sql--normalize-identifier
                   (or identifier
                       (cm/sql--identifier-at-point)
                       (thing-at-point 'symbol t))))
         (prompt (if default
                     (format "Find references (default %s): " default)
                   "Find references: "))
         (query (string-trim (read-string prompt nil nil default))))
    (when (string-empty-p query)
      (user-error "No identifier provided"))
    (let ((cm/sql-xref-strict-identifiers
           (or cm/sql-xref-strict-identifiers prefix))
          (xrefs (cm/sql--xref-collect query)))
      (if xrefs
          (xref--show-xrefs xrefs nil)
        (user-error "No references found for %s" query)))))

(defun cm/sql-find-references-sql-only (&optional prefix identifier)
  "Find IDENTIFIER references in SQL files only."
  (interactive "P")
  (let* ((default (cm/sql--normalize-identifier
                   (or identifier
                       (cm/sql--identifier-at-point)
                       (thing-at-point 'symbol t))))
         (prompt (if default
                     (format "Find SQL references (default %s): " default)
                   "Find SQL references: "))
         (query (string-trim (read-string prompt nil nil default))))
    (when (string-empty-p query)
      (user-error "No identifier provided"))
    (let ((cm/sql-xref-strict-identifiers
           (or cm/sql-xref-strict-identifiers prefix))
          (xrefs (cm/sql--xref-collect query cm/sql-xref-sql-only-globs)))
      (if xrefs
          (xref--show-xrefs xrefs nil)
        (user-error "No SQL-file references found for %s" query)))))

(defun cm/sql--pg-dequote-safe-identifiers (s)
  "Drop unnecessary quotes in PostgreSQL identifier string S.
Only dequote identifiers that are already lowercase and contain
characters accepted unquoted by PostgreSQL."
  (replace-regexp-in-string
   "\"\\([a-z_][a-z0-9_$]*\\)\""
   "\\1"
   s))

(defun cm/sql-complete-object (&optional refresh)
  "Complete SQL object name at point.
With prefix argument REFRESH, rebuild completion cache first."
  (interactive "P")
  (let* ((sqlbuf (cm/sql--sqli-buffer-or-error))
         (sql-completion-sqlbuf sqlbuf)
         (product (with-current-buffer sqlbuf sql-product))
         (completion-ignore-case t))
    (unless (sql-get-product-feature product :completion-object)
      (user-error "%s does not support SQL object completion" product))
    (when refresh
      (cm/sql-refresh-completions))
    (with-current-buffer sqlbuf
      (unless sql-completion-object
        (sql-build-completions nil)))
    (let* ((bounds (cm/sql--object-bounds))
           (beg (car bounds))
           (end (cdr bounds))
           (initial (buffer-substring-no-properties beg end))
           (choice (completing-read "SQL object: "
                                    #'sql--completion-table nil nil initial)))
      (when (eq product 'postgres)
        (setq choice (cm/sql--pg-dequote-safe-identifiers choice)))
      (delete-region beg end)
      (insert choice))))

(use-package sql
  :straight nil
  :bind (:map sql-mode-map
              ("M-?"     . cm/sql-find-references)
              ("C-c ? s" . cm/sql-find-references-sql-only)
              ("C-c C-o"   . cm/sql-complete-object)
              ("C-c C-l r" . cm/sql-refresh-completions))
  :hook
  ((sql-mode . (lambda ()
                 (setq-local indent-tabs-mode nil)
                 ;; Keep union enabled for non-LSP SQL buffers; references are
                 ;; primarily handled by explicit SQL commands bound above.
                 (xref-union-mode 1)))
   (sql-interactive-mode . (lambda ()
                             (setq-local indent-tabs-mode nil)))))

;;;; C / C++.
;; c-ts-mode and c++-ts-mode are built-in; clangd is eglot's default.

;;;; Odin.
(use-package odin-mode
  :straight (:host sourcehut :repo "mgmarlow/odin-mode")
  :mode "\\.odin\\'")

;;;; Zig.
(use-package zig-mode)

;;;; Python.
;; python-ts-mode is built-in; pyright/pylsp are eglot defaults.

;;;; Bash.
;; bash-ts-mode is built-in; bash-language-server is eglot's default.

;;;; Fish.
(use-package fish-mode)

;;;; YAML.
;; yaml-ts-mode is built-in; yaml-language-server is eglot's default.

;;;; TOML.
;; toml-ts-mode is built-in; no LSP needed.

;;;; Rust.
;; rust-ts-mode is built-in; rust-analyzer is eglot's default.

;;;; CMake.
;; cmake-ts-mode is built-in; cmake-language-server is eglot's default.

;;;; Markdown.
(use-package markdown-mode
  :mode ("\\.md\\'" . gfm-mode)
  :custom
  (markdown-fontify-code-blocks-natively t))

;;;; JavaScript / TypeScript.
;; js-ts-mode, typescript-ts-mode, tsx-ts-mode are built-in.
;; typescript-language-server is eglot's default.

;;;; Dockerfile.
;; dockerfile-ts-mode is built-in.

;;;; docker — manage containers, images, volumes, and networks.
(use-package docker
  :bind ("C-c D" . docker))

;;;; Lua.
;; lua-ts-mode is built-in (Emacs 30); lua-language-server is eglot's default.

;;;; HTML / CSS.
;; html-ts-mode and css-ts-mode are built-in.
;; vscode-html/css-language-server are eglot defaults.
(use-package web-mode
  :mode ("\\.vue\\'" "\\.svelte\\'" "\\.njk\\'" "\\.hbs\\'"))

;;;; Java.
;; java-ts-mode is built-in; jdtls is eglot's default.
;; Install eclipse.jdt.ls and ensure it is on your PATH.

;;;; Jai.
(use-package jai-mode
  :straight (:host github :repo "elp-revive/jai-mode")
  :mode "\\.jai\\'")

;;;; Haskell.
(use-package haskell-mode)

;;;; pdf-tools — PDF viewer with annotation support.
(use-package pdf-tools
  :mode ("\\.pdf\\'" . pdf-view-mode)
  :custom
  (pdf-view-display-size 'fit-page)
  :config
  (pdf-tools-install :no-query))

;;;; CSV.
(use-package csv-mode)

;;;; org-mode.
(use-package org
  :straight nil
  :custom
  (org-hide-leading-stars t)
  (org-startup-indented t)
  (org-indent-indentation-per-level 2)
  :hook
  ((org-mode . visual-line-mode)
   (org-mode . org-indent-mode)
   (org-mode . cm/org-apply-heading-scale)))

;;;; org heading sizing.
(defvar cm/org-heading-scale-factor 1.2
  "Multiplier used to enlarge org heading faces.")

(defvar cm/org-heading-base-heights nil
  "Original org heading heights captured from the active theme.")

(defun cm/org-heading-faces-ready-p (faces)
  "Return non-nil when every face in FACES has been defined."
  (catch 'missing
    (dolist (face faces t)
      (unless (facep face)
        (throw 'missing nil)))))

(defun cm/org-apply-heading-scale ()
  "Scale `org-level-*' faces by `cm/org-heading-scale-factor'."
  (let ((faces '(org-level-1 org-level-2 org-level-3 org-level-4
                             org-level-5 org-level-6 org-level-7 org-level-8)))
    (when (cm/org-heading-faces-ready-p faces)
      (unless cm/org-heading-base-heights
        (setq cm/org-heading-base-heights
              (mapcar (lambda (face)
                        (cons face (face-attribute face :height nil 'default)))
                      faces)))
      (dolist (entry cm/org-heading-base-heights)
        (let ((face (car entry))
              (height (cdr entry)))
          (when (numberp height)
            (set-face-attribute
             face nil :height
             (truncate (* (if (integerp height) height (* 100 height))
                          cm/org-heading-scale-factor)))))))))

(defun cm/org-refresh-heading-scale (&rest _)
  "Recompute and apply org heading scale after theme changes."
  (setq cm/org-heading-base-heights nil)
  (cm/org-apply-heading-scale))

(advice-add 'load-theme :after #'cm/org-refresh-heading-scale)
(cm/org-apply-heading-scale)

(setq shift-select-mode 'permanent)

;;; -----------------------------------------------------------------------
;;; AI writing assistant — exchange protocol for Claude Code integration
;;; -----------------------------------------------------------------------
;; Side-by-side workflow: Emacs for writing, Claude Code for feedback.
;; Communication uses a shared directory (~/.emacs-ai/) with file exchange.
;;
;; From Emacs:
;;   C-c a s   share buffer, region, or org subtree (C-u) with AI
;;   C-c a a   accept/apply AI suggestion at point or region
;;   C-c a d   diff current text against AI suggestion
;;
;; Remote query (Claude Code calls via emacsclient -e):
;;   (cm/ai-current-context)             → JSON: file, mode, line, region, etc.
;;   (cm/ai-visible-buffers)             → JSON array of all visible buffers
;;   (cm/ai-get-content)                 → snapshot focused buffer → exchange dir
;;   (cm/ai-get-content "buf-name")      → snapshot named buffer → exchange dir
;;   (cm/ai-paragraph-at-point)          → text of paragraph at point
;;   (cm/ai-line-at-point)               → text of current line
;;   (cm/ai-region-or-paragraph)         → JSON: region if active, else paragraph
;;   (cm/ai-org-subtree-at-point)        → org subtree text (nil if not org-mode)
;;   (cm/ai-nearby-lines)                → ±5 lines around point with → marker
;;   (cm/ai-nearby-lines N)              → ±N lines around point
;;
;; File exchange:
;;   ~/.emacs-ai/context.json   metadata (written by share/get-content)
;;   ~/.emacs-ai/content.txt    buffer text (written by share/get-content)
;;   ~/.emacs-ai/suggestion.txt AI suggestion (read by accept/diff)
;;   Or: edit the file directly (auto-revert picks it up)

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

;;;; Remote-query functions — called by Claude Code via emacsclient -e.
;; These let the AI inspect Emacs state without the user pressing anything.

(defun cm/ai-current-context ()
  "Return JSON string describing the focused buffer's editing context.
Designed for `emacsclient -s <server> -e \\='(cm/ai-current-context)\\=''.
Returns file path, mode, cursor position, active region bounds, etc."
  (let* ((win (selected-window))
         (buf (window-buffer win)))
    (with-current-buffer buf
      (let* ((region-p (use-region-p))
             (context
              `((file . ,(or (buffer-file-name) ""))
                (buffer . ,(buffer-name))
                (mode . ,(symbol-name major-mode))
                (line . ,(line-number-at-pos))
                (column . ,(current-column))
                (org-path . ,(or (cm/ai--org-heading-path) []))
                (modified . ,(if (buffer-modified-p) t :json-false))
                (server . ,(or (cm/ai--server-name) ""))
                (region . ,(if region-p
                               `((start-line . ,(line-number-at-pos (region-beginning)))
                                 (end-line . ,(line-number-at-pos (region-end)))
                                 (chars . ,(- (region-end) (region-beginning))))
                             :json-false))
                (timestamp . ,(format-time-string "%Y-%m-%dT%H:%M:%S")))))
        (json-encode context)))))

(defun cm/ai-visible-buffers ()
  "Return JSON array describing all visible buffers across frames.
Designed for `emacsclient -e' — lets AI see what windows are open."
  (let (result)
    (walk-windows
     (lambda (win)
       (let ((buf (window-buffer win)))
         (push `((file . ,(or (buffer-file-name buf) ""))
                 (buffer . ,(buffer-name buf))
                 (mode . ,(symbol-name (buffer-local-value 'major-mode buf)))
                 (selected . ,(if (eq win (selected-window)) t :json-false)))
               result)))
     nil t)
    (json-encode (nreverse result))))

(defun cm/ai-get-content (&optional buffer-name-or-nil)
  "Snapshot buffer content to exchange dir; return context as JSON string.
Without BUFFER-NAME-OR-NIL, uses the focused window's buffer.
If the buffer has an active region, only that text is captured.
Writes content.txt and context.json to `cm/ai-exchange-dir'.
Designed for `emacsclient -e \\='(cm/ai-get-content)\\='' or
`emacsclient -e \\='(cm/ai-get-content \"some-buffer\")\\=''."
  (cm/ai--ensure-dir)
  (let* ((buf (if buffer-name-or-nil
                  (or (get-buffer buffer-name-or-nil)
                      (error "No buffer named %s" buffer-name-or-nil))
                (window-buffer (selected-window)))))
    (with-current-buffer buf
      (let* ((region-p (use-region-p))
             (content (if region-p
                          (buffer-substring-no-properties (region-beginning) (region-end))
                        (buffer-substring-no-properties (point-min) (point-max))))
             (scope (if region-p "region" "buffer"))
             (context
              `((file . ,(or (buffer-file-name) ""))
                (buffer . ,(buffer-name))
                (mode . ,(symbol-name major-mode))
                (line . ,(line-number-at-pos))
                (column . ,(current-column))
                (scope . ,scope)
                (org-path . ,(or (cm/ai--org-heading-path) []))
                (modified . ,(if (buffer-modified-p) t :json-false))
                (server . ,(or (cm/ai--server-name) ""))
                (timestamp . ,(format-time-string "%Y-%m-%dT%H:%M:%S"))
                (chars . ,(length content)))))
        (with-temp-file (expand-file-name "content.txt" cm/ai-exchange-dir)
          (insert content))
        (let ((json (json-encode context)))
          (with-temp-file (expand-file-name "context.json" cm/ai-exchange-dir)
            (insert json))
          json)))))

(defun cm/ai-paragraph-at-point ()
  "Return the paragraph surrounding point in the focused buffer.
Does not disturb point, mark, or region."
  (with-current-buffer (window-buffer (selected-window))
    (save-excursion
      (let ((beg (progn (backward-paragraph) (skip-chars-forward "\n") (point)))
            (end (progn (forward-paragraph) (skip-chars-backward "\n") (point))))
        (buffer-substring-no-properties beg end)))))

(defun cm/ai-line-at-point ()
  "Return the current line in the focused buffer."
  (with-current-buffer (window-buffer (selected-window))
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

(defun cm/ai-region-or-paragraph ()
  "Return active region text if any, otherwise the paragraph at point.
Returns a JSON object with `scope' (\"region\" or \"paragraph\") and `text'."
  (with-current-buffer (window-buffer (selected-window))
    (let* ((region-p (use-region-p))
           (text (if region-p
                     (buffer-substring-no-properties (region-beginning) (region-end))
                   (save-excursion
                     (let ((beg (progn (backward-paragraph)
                                       (skip-chars-forward "\n") (point)))
                           (end (progn (forward-paragraph)
                                       (skip-chars-backward "\n") (point))))
                       (buffer-substring-no-properties beg end))))))
      (json-encode `((scope . ,(if region-p "region" "paragraph"))
                     (text . ,text)
                     (chars . ,(length text)))))))

(defun cm/ai-org-subtree-at-point ()
  "Return the org subtree at point, or nil if not in `org-mode'."
  (with-current-buffer (window-buffer (selected-window))
    (when (derived-mode-p 'org-mode)
      (save-excursion
        (org-back-to-heading t)
        (let ((beg (point)))
          (org-end-of-subtree t t)
          (buffer-substring-no-properties beg (point)))))))

(defun cm/ai-nearby-lines (&optional n)
  "Return N lines above and below point (default 5) with a → marker on the current line."
  (with-current-buffer (window-buffer (selected-window))
    (let* ((n (or n 5))
           (cur (line-number-at-pos))
           (beg (save-excursion (forward-line (- n)) (point)))
           (end (save-excursion (forward-line (1+ n)) (point)))
           (lines (split-string (buffer-substring-no-properties beg end) "\n"))
           (start-line (- cur n))
           (result '()))
      (dotimes (i (length lines))
        (let* ((lnum (+ start-line i))
               (prefix (if (= lnum cur) "→" " ")))
          (push (format "%s %4d: %s" prefix lnum (nth i lines)) result)))
      (mapconcat #'identity (nreverse result) "\n"))))

(defun cm/ai-share (&optional arg)
  "Share current editing context with AI assistant.
Snapshots buffer content to `cm/ai-exchange-dir' along with JSON
metadata.  With prefix ARG in `org-mode', shares the current
subtree instead of the full buffer.  An active region always
takes priority.

From Claude Code, read ~/.emacs-ai/context.json and
~/.emacs-ai/content.txt to see what was shared."
  (interactive "P")
  (cm/ai--ensure-dir)
  (let* ((region-p (use-region-p))
         (subtree-p (and arg (derived-mode-p 'org-mode)))
         (content
          (cond
           (subtree-p
            (save-excursion
              (org-back-to-heading t)
              (let ((beg (point)))
                (org-end-of-subtree t t)
                (buffer-substring-no-properties beg (point)))))
           (region-p
            (buffer-substring-no-properties (region-beginning) (region-end)))
           (t
            (buffer-substring-no-properties (point-min) (point-max)))))
         (scope (cond (subtree-p "subtree") (region-p "region") (t "buffer")))
         (context
          `((file . ,(or (buffer-file-name) ""))
            (buffer . ,(buffer-name))
            (mode . ,(symbol-name major-mode))
            (line . ,(line-number-at-pos))
            (column . ,(current-column))
            (scope . ,scope)
            (org-path . ,(or (cm/ai--org-heading-path) []))
            (modified . ,(if (buffer-modified-p) t :json-false))
            (server . ,(or (cm/ai--server-name) ""))
            (timestamp . ,(format-time-string "%Y-%m-%dT%H:%M:%S")))))
    (with-temp-file (expand-file-name "content.txt" cm/ai-exchange-dir)
      (insert content))
    (with-temp-file (expand-file-name "context.json" cm/ai-exchange-dir)
      (insert (json-encode context)))
    (message "Shared %s with AI (%d chars)" scope (length content))))

(defun cm/ai-accept ()
  "Apply AI suggestion from exchange directory.
If a region is active, replaces it.  Otherwise inserts at point.
The suggestion file is deleted after application."
  (interactive)
  (let ((path (expand-file-name "suggestion.txt" cm/ai-exchange-dir)))
    (unless (file-exists-p path)
      (user-error "No AI suggestion found in %s" cm/ai-exchange-dir))
    (let ((text (with-temp-buffer
                  (insert-file-contents path)
                  (buffer-string))))
      (when (use-region-p)
        (delete-region (region-beginning) (region-end)))
      (insert text)
      (delete-file path)
      (message "Applied AI suggestion (%d chars)" (length text)))))

(defun cm/ai-diff ()
  "Show diff between current buffer/region and AI suggestion."
  (interactive)
  (let ((suggestion-file (expand-file-name "suggestion.txt" cm/ai-exchange-dir)))
    (unless (file-exists-p suggestion-file)
      (user-error "No AI suggestion found in %s" cm/ai-exchange-dir))
    (let ((current-file (make-temp-file "emacs-ai-current-")))
      (if (use-region-p)
          (write-region (region-beginning) (region-end) current-file nil 'quiet)
        (write-region (point-min) (point-max) current-file nil 'quiet))
      (diff current-file suggestion-file nil t)
      (delete-file current-file))))

(defvar cm/ai-map (make-sparse-keymap)
  "Keymap for AI writing assistant commands under `C-c a'.")
(global-set-key (kbd "C-c a") cm/ai-map)
(define-key cm/ai-map (kbd "s") #'cm/ai-share)
(define-key cm/ai-map (kbd "a") #'cm/ai-accept)
(define-key cm/ai-map (kbd "d") #'cm/ai-diff)
(define-key cm/ai-map (kbd "S") #'cm/ai-show-suggestions)

;;;; Interactive suggestions buffer.
;; Reads ~/.emacs-ai/suggestions.json (written by Claude Code) and presents
;; original text alongside multiple rewrite suggestions in a navigable,
;; read-only buffer.  The user can review, diff, and apply with single keys.

(defface cm/ai-suggestions-heading-original
  '((t :foreground "#80FFEA" :weight bold :height 1.1))
  "Face for the original-text heading in `*ai-suggestions*'.")

(defface cm/ai-suggestions-heading
  '((t :foreground "#8AFF80" :weight bold :height 1.1))
  "Face for suggestion headings in `*ai-suggestions*'.")

(defface cm/ai-suggestions-original
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for original text in `*ai-suggestions*'.")

(defface cm/ai-suggestions-text
  '((t :inherit default))
  "Face for suggestion text in `*ai-suggestions*'.")

(add-to-list 'display-buffer-alist
             '("\\*ai-suggestions\\*"
               (display-buffer-reuse-window display-buffer-below-selected)
               (window-height . 0.4)))

(defvar-local cm/ai-suggestions--source nil
  "Source metadata plist from suggestions.json.")
(defvar-local cm/ai-suggestions--data nil
  "Parsed suggestions.json as an alist.")
(defvar-local cm/ai-suggestions--original nil
  "Original text from suggestions.json.")

(defvar cm/ai-suggestions-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'cm/ai-suggestions-next-section)
    (define-key map (kbd "p") #'cm/ai-suggestions-prev-section)
    (define-key map (kbd "a") #'cm/ai-suggestions-apply)
    (define-key map (kbd "RET") #'cm/ai-suggestions-apply)
    (define-key map (kbd "d") #'cm/ai-suggestions-diff)
    map)
  "Keymap for `cm/ai-suggestions-mode'.")

(define-derived-mode cm/ai-suggestions-mode special-mode "AI-Suggestions"
  "Major mode for reviewing AI writing suggestions.
\\<cm/ai-suggestions-mode-map>
\\[cm/ai-suggestions-next-section]  next section
\\[cm/ai-suggestions-prev-section]  previous section
\\[cm/ai-suggestions-apply]  apply suggestion at point
\\[cm/ai-suggestions-diff]  diff suggestion at point vs original
\\[quit-window]  dismiss"
  :group 'cm
  (setq-local line-spacing 0.2)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

(defun cm/ai-suggestions--read-json ()
  "Read and parse suggestions.json from the AI exchange directory.
Returns the parsed JSON as an alist."
  (let ((path (expand-file-name "suggestions.json" cm/ai-exchange-dir)))
    (unless (file-exists-p path)
      (user-error "No suggestions.json found in %s" cm/ai-exchange-dir))
    (json-parse-string
     (with-temp-buffer
       (insert-file-contents path)
       (buffer-string))
     :object-type 'alist
     :array-type 'list)))

(defun cm/ai-suggestions--render (data)
  "Render DATA (parsed suggestions.json) into the current buffer."
  (let ((inhibit-read-only t)
        (original (alist-get 'original data))
        (suggestions (alist-get 'suggestions data)))
    (erase-buffer)
    ;; Original section
    (let ((header-start (point)))
      (insert (propertize "── Original "
                          'face 'cm/ai-suggestions-heading-original))
      (insert (propertize (make-string (max 1 (- (window-width) 14)) ?─)
                          'face 'cm/ai-suggestions-heading-original))
      (put-text-property header-start (point) 'cm/ai-section-header t)
      (insert "\n"))
    (let ((body-start (point)))
      (insert (propertize original 'face 'cm/ai-suggestions-original))
      (put-text-property body-start (point) 'cm/ai-section 'original)
      (insert "\n\n"))
    ;; Suggestion sections
    (let ((idx 0))
      (dolist (suggestion suggestions)
        (let* ((label (or (alist-get 'label suggestion)
                          (format "Option %d" (1+ idx))))
               (text (alist-get 'text suggestion))
               (header-start (point)))
          (insert (propertize (format "── Suggestion %d: %s " (1+ idx) label)
                              'face 'cm/ai-suggestions-heading))
          (let ((fill (max 1 (- (window-width)
                                (- (point) header-start) 1))))
            (insert (propertize (make-string fill ?─)
                                'face 'cm/ai-suggestions-heading)))
          (put-text-property header-start (point) 'cm/ai-section-header t)
          (insert "\n")
          (let ((body-start (point)))
            (insert (propertize text 'face 'cm/ai-suggestions-text))
            (put-text-property body-start (point) 'cm/ai-section (cons 'suggestion idx))
            (insert "\n\n")))
        (setq idx (1+ idx))))
    (goto-char (point-min))))

(defun cm/ai-show-suggestions ()
  "Display the *ai-suggestions* buffer with contents from suggestions.json.
Call this interactively with \\[cm/ai-show-suggestions] or remotely via:
  emacsclient -e \\='(cm/ai-show-suggestions)\\='"
  (interactive)
  (let* ((data (cm/ai-suggestions--read-json))
         (buf (get-buffer-create "*ai-suggestions*")))
    (with-current-buffer buf
      (cm/ai-suggestions-mode)
      (cm/ai-suggestions--render data)
      (setq cm/ai-suggestions--data data
            cm/ai-suggestions--original (alist-get 'original data)
            cm/ai-suggestions--source (alist-get 'source data))
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defun cm/ai-suggestions-next-section ()
  "Move point to the next section header."
  (interactive)
  (let ((pos (next-single-property-change (point) 'cm/ai-section-header)))
    (when pos
      ;; If we're on a header, skip past it first
      (when (get-text-property pos 'cm/ai-section-header)
        (let ((end (next-single-property-change pos 'cm/ai-section-header)))
          (when end
            (setq pos (next-single-property-change end 'cm/ai-section-header)))))
      (when pos
        (goto-char pos)
        ;; Move to start of body text (line after header)
        (forward-line 1)))))

(defun cm/ai-suggestions-prev-section ()
  "Move point to the previous section header."
  (interactive)
  (let ((pos (previous-single-property-change (point) 'cm/ai-section-header)))
    (when pos
      ;; Find the start of this header
      (let ((start (previous-single-property-change pos 'cm/ai-section-header)))
        (when start
          (goto-char start)
          (forward-line 1))))))

(defun cm/ai-suggestions--section-at-point ()
  "Return the section value at point, or nil."
  (get-text-property (point) 'cm/ai-section))

(defun cm/ai-suggestions--suggestion-text-at-point ()
  "Return the suggestion text for the section at point, or nil."
  (let ((section (cm/ai-suggestions--section-at-point)))
    (cond
     ((and (consp section) (eq (car section) 'suggestion))
      (let* ((idx (cdr section))
             (suggestions (alist-get 'suggestions cm/ai-suggestions--data))
             (entry (nth idx suggestions)))
        (alist-get 'text entry)))
     ((eq section 'original)
      cm/ai-suggestions--original)
     (t
      ;; Try to find nearest section by searching backward
      (save-excursion
        (let ((pos (previous-single-property-change (point) 'cm/ai-section)))
          (when pos
            (goto-char (1- pos))
            (cm/ai-suggestions--suggestion-text-at-point))))))))

(defun cm/ai-suggestions--apply-to-source (text)
  "Replace source content with TEXT using metadata from `cm/ai-suggestions--source'."
  (let* ((source cm/ai-suggestions--source)
         (file (alist-get 'file source))
         (buf-name (alist-get 'buffer source))
         (scope (alist-get 'scope source))
         (start-line (alist-get 'start-line source))
         (end-line (alist-get 'end-line source))
         (buf (or (and file (not (string-empty-p file))
                       (find-buffer-visiting file))
                  (and buf-name (get-buffer buf-name)))))
    (unless buf
      (user-error "Source buffer not found: %s" (or file buf-name)))
    (with-current-buffer buf
      (let (insert-beg insert-end)
        (pcase scope
          ("buffer"
           (let ((inhibit-read-only t))
             (erase-buffer)
             (setq insert-beg (point))
             (insert text)
             (setq insert-end (point))))
          ("subtree"
           (save-excursion
             (goto-char (point-min))
             (when start-line (forward-line (1- start-line)))
             (when (derived-mode-p 'org-mode)
               (org-back-to-heading t)
               (let ((beg (point)))
                 (org-end-of-subtree t t)
                 (delete-region beg (point))
                 (setq insert-beg (point))
                 (insert text)
                 (setq insert-end (point))))))
          (_  ; "region", "paragraph", or anything line-based
           (save-excursion
             (goto-char (point-min))
             (forward-line (1- (or start-line 1)))
             (let ((beg (point)))
               (goto-char (point-min))
               (forward-line (or end-line start-line 1))
               (delete-region beg (point))
               (setq insert-beg (point))
               (insert text)
               (unless (eq (char-before) ?\n)
                 (insert "\n"))
               ;; Preserve blank-line separation if the next line is
               ;; non-empty (prevents Markdown setext-heading misparse
               ;; when text sits directly above a "---" rule).
               (when (and (not (eobp))
                          (not (eq (char-after) ?\n)))
                 (insert "\n"))
               (setq insert-end (point))))))
        (when (and insert-beg insert-end)
          (remove-text-properties insert-beg insert-end
                                  '(face nil font-lock-face nil))
          (font-lock-ensure insert-beg insert-end))))))

(defun cm/ai-suggestions-apply ()
  "Apply the suggestion at point to the source buffer."
  (interactive)
  (let ((text (cm/ai-suggestions--suggestion-text-at-point)))
    (unless text
      (user-error "No suggestion at point"))
    (when (string= text cm/ai-suggestions--original)
      (user-error "That's the original text, not a suggestion"))
    (when (y-or-n-p "Apply this suggestion to source buffer? ")
      (cm/ai-suggestions--apply-to-source text)
      (message "Suggestion applied.")
      (let ((json-path (expand-file-name "suggestions.json" cm/ai-exchange-dir)))
        (when (file-exists-p json-path)
          (delete-file json-path)))
      (quit-window t))))

(defun cm/ai-suggestions-diff ()
  "Diff the suggestion at point against the original text."
  (interactive)
  (let ((text (cm/ai-suggestions--suggestion-text-at-point)))
    (unless text
      (user-error "No suggestion at point"))
    (let ((orig-file (make-temp-file "ai-original-"))
          (sugg-file (make-temp-file "ai-suggestion-")))
      (with-temp-file orig-file
        (insert cm/ai-suggestions--original))
      (with-temp-file sugg-file
        (insert text))
      (diff orig-file sugg-file nil t))))

;;;; Keybinding cheat sheet (high-frequency).
;; Search/navigation:
;;   C-S-s   consult-line (region-seeded)
;;   C-c s   consult-ripgrep (region-seeded)
;;   M-s .   consult-ripgrep thing-at-point (literal)
;;   M-s ,   consult-ripgrep thing-at-point (regexp)
;;   M-s q   consult-ripgrep thing-at-point in SQL files only
;;   M-s g   consult-git-grep (region-seeded)
;;   M-g e   consult-compile-error
;;
;; Actions/completion:
;;   C-.     embark-act
;;   C-;     embark-dwim
;;   M-R     vertico-repeat
;;   C-=     er/expand-region
;;   C--     er/contract-region
;;
;; AI writing assistant (interactive):
;;   C-c a s  share buffer/region/subtree with AI
;;   C-c a a  accept AI suggestion
;;   C-c a d  diff current vs AI suggestion
;;   C-c a S  show *ai-suggestions* buffer (n/p/a/d/q)
;;
;; AI writing assistant (remote — Claude Code calls via emacsclient -e):
;;   (cm/ai-current-context)         → JSON metadata for focused buffer
;;   (cm/ai-visible-buffers)         → JSON array of all visible buffers
;;   (cm/ai-get-content)             → snapshot focused buffer to exchange dir
;;   (cm/ai-get-content "buf-name")  → snapshot named buffer to exchange dir
;;   (cm/ai-paragraph-at-point)      → paragraph text at point
;;   (cm/ai-line-at-point)           → current line text
;;   (cm/ai-region-or-paragraph)     → JSON: region if active, else paragraph
;;   (cm/ai-org-subtree-at-point)    → org subtree (nil outside org-mode)
;;   (cm/ai-nearby-lines)            → ±5 lines with → marker on current line
;;   (cm/ai-nearby-lines N)          → ±N lines with → marker
;;   (cm/ai-show-suggestions)        → display *ai-suggestions* from suggestions.json


;;; init.el ends here
