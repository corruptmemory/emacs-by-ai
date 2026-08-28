;;; cm-herdr.el --- herdr bind/push layer for the Emacs<->agent bridge  -*- lexical-binding: t; -*-
;;; Commentary:
;; `cm/ai-bind-agent' lists running herdr-managed agents (`herdr agent list'),
;; lets you pick one, and pushes this Emacs's socket handshake into it
;; (`herdr agent prompt <pane> "[emacs-bridge] connect {…}"'), so the chosen
;; agent gains a direct line back to THIS Emacs.  Explicit / cross-project
;; binding on top of Phase 1's automatic same-project registry.
;; See docs/plans/2026-08-28-emacs-agents-bridge-design.md (Section B).
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'cm-ai-registry)  ; for cm/ai-registry-descriptor (this Emacs's socket/project)

(defcustom cm/ai-herdr-executable "herdr"
  "Name or path of the herdr CLI."
  :type 'string :group 'tools)

(defun cm/ai-herdr--available-p ()
  "Return non-nil if the herdr CLI is on PATH."
  (and (executable-find cm/ai-herdr-executable) t))

(defun cm/ai-herdr--parse-agent-list (json-string)
  "Parse `herdr agent list' JSON-STRING into a list of agent plists."
  (let* ((json-object-type 'plist) (json-key-type 'keyword) (json-array-type 'list)
         (data (json-read-from-string json-string)))
    (plist-get (plist-get data :result) :agents)))

(defun cm/ai-herdr--this-emacs-descriptor ()
  "Return this Emacs's registry descriptor alist (server_name/socket/project_root)."
  (cm/ai-registry-descriptor))

(defun cm/ai-herdr--this-project-root ()
  "Return this Emacs's project root (slash-terminated) from the registry."
  (alist-get 'project_root (cm/ai-herdr--this-emacs-descriptor)))

(defun cm/ai-herdr--handshake-payload (descriptor)
  "Build the `[emacs-bridge] connect' handshake string from DESCRIPTOR (alist)."
  (format "[emacs-bridge] connect %s"
          (json-encode
           (list (cons 'server_name (alist-get 'server_name descriptor))
                 (cons 'socket (alist-get 'socket descriptor))
                 (cons 'project_root (alist-get 'project_root descriptor))
                 (cons 'protocol 1)))))

(defun cm/ai-herdr--candidate-label (agent)
  "A `completing-read' label for AGENT plist: agent · cwd-base · status · pane."
  (format "%s · %s · %s · %s"
          (plist-get agent :agent)
          (file-name-nondirectory
           (directory-file-name (or (plist-get agent :cwd) "")))
          (plist-get agent :agent_status)
          (plist-get agent :pane_id)))

(defun cm/ai-herdr--cwd-match-p (agent root)
  "Non-nil if AGENT's :cwd is within ROOT (both normalized, slash-terminated)."
  (let ((cwd (plist-get agent :cwd)))
    (and root cwd
         (string-prefix-p (file-name-as-directory (expand-file-name root))
                           (file-name-as-directory (expand-file-name cwd))))))

(defun cm/ai-herdr--sort-agents (agents this-root)
  "Return AGENTS with any whose :cwd is within THIS-ROOT floated to the front."
  (cl-stable-sort (copy-sequence agents)
                   (lambda (a b) (and (cm/ai-herdr--cwd-match-p a this-root)
                                       (not (cm/ai-herdr--cwd-match-p b this-root))))))

(provide 'cm-herdr)
;;; cm-herdr.el ends here
