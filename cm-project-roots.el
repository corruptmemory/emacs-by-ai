;;; cm-project-roots.el --- Multi-root project search ("Add Folder to Project")  -*- lexical-binding: t; -*-
;;; Commentary:
;; Opt-in commands that run search / references / find-file / jump-to-definition
;; across directories listed in a `.project-roots' file at the primary project
;; root.  LSP-first for jump/refs; rg-based for search/find-file.
;; See docs/plans/2026-06-06-multi-root-project-design.md.
;;; Code:

(require 'project)
(require 'xref)
(require 'subr-x)
(require 'cl-lib)

(declare-function consult-ripgrep "consult")
(declare-function consult--read "consult")
(declare-function dumb-jump-fetch-results "dumb-jump")
(declare-function dumb-jump-get-language "dumb-jump")
(declare-function eglot-managed-p "eglot")
(declare-function eglot-server-capable "eglot")

(defconst cm/project-roots-file ".project-roots"
  "Name of the file (at the primary project root) listing extra roots.")

(defun cm/project-roots--parse (text base-dir)
  "Parse TEXT (a `.project-roots' file body) into a list of absolute dirs.
Lines beginning with or containing `#' are comment-stripped; blank lines
are dropped; `~' expands; relative entries resolve against BASE-DIR.
Pure: performs no filesystem access."
  (let (dirs)
    (dolist (line (split-string text "\n"))
      (let ((s (string-trim (replace-regexp-in-string "#.*\\'" "" line))))
        (unless (string-empty-p s)
          (push (expand-file-name s base-dir) dirs))))
    (nreverse dirs)))

(defun cm/project-roots--from-file (file)
  "Return the primary root (FILE's directory) plus existing declared roots.
Nonexistent declared dirs are skipped with a `message' warning."
  (let* ((base (file-name-as-directory (file-name-directory (expand-file-name file))))
         (declared (cm/project-roots--parse
                    (with-temp-buffer (insert-file-contents file) (buffer-string))
                    base))
         (roots (list base)))
    (dolist (d declared)
      (if (file-directory-p d)
          (push (file-name-as-directory d) roots)
        (message "cm/project-roots: skipping missing dir %s" d)))
    (delete-dups (nreverse roots))))

(defun cm/project-roots ()
  "Return the list of root directories for the current multi-root project.
If a `.project-roots' file dominates `default-directory', return its
primary root plus the existing declared roots.  Otherwise degrade to the
current project root, or `default-directory'."
  (if-let* ((dir (locate-dominating-file default-directory cm/project-roots-file)))
      (cm/project-roots--from-file (expand-file-name cm/project-roots-file dir))
    (list (file-name-as-directory
           (expand-file-name
            (if-let* ((proj (project-current))) (project-root proj)
              default-directory))))))

(defun cm/project-add-root--append (file dir)
  "Append DIR (abbreviated, slash-terminated) to FILE; create FILE if absent.
No-op when DIR is already listed."
  (let* ((abbr (abbreviate-file-name (file-name-as-directory (expand-file-name dir))))
         (lines (and (file-exists-p file)
                     (with-temp-buffer (insert-file-contents file)
                       (mapcar #'string-trim
                               (split-string (buffer-string) "\n" t))))))
    (unless (member abbr lines)
      (with-temp-buffer
        (when (file-exists-p file) (insert-file-contents file))
        (goto-char (point-max))
        (unless (or (bobp) (bolp)) (insert "\n"))
        (insert abbr "\n")
        (write-region (point-min) (point-max) file)))))

(defun cm/project--primary-root ()
  "Return the directory that should hold this project's `.project-roots'."
  (file-name-as-directory
   (expand-file-name
    (or (locate-dominating-file default-directory cm/project-roots-file)
        (when-let* ((proj (project-current))) (project-root proj))
        default-directory))))

(defun cm/project-add-root (dir)
  "Add DIR to this project's `.project-roots' (\"Add Folder to Project\")."
  (interactive "DAdd folder to project: ")
  (cm/project-add-root--append
   (expand-file-name cm/project-roots-file (cm/project--primary-root)) dir)
  (message "Added %s to project roots" (abbreviate-file-name dir)))

(defun cm/project-edit-roots ()
  "Open this project's `.project-roots' file for editing."
  (interactive)
  (find-file (expand-file-name cm/project-roots-file (cm/project--primary-root))))

(provide 'cm-project-roots)
;;; cm-project-roots.el ends here
