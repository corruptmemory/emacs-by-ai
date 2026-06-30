;;; jai-ts-mode-tests.el --- Tests for jai-ts-mode  -*- lexical-binding: t; -*-

(require 'ert)
(require 'jai-ts-mode)

(defun jai-ts-mode-tests--reindent (code)
  "Return CODE re-indented from scratch in a `jai-ts-mode' buffer."
  (with-temp-buffer
    (jai-ts-mode)
    (insert code)
    (indent-region (point-min) (point-max))
    (buffer-string)))

(ert-deftest jai-ts-mode-test-indent-nested-for ()
  "The reported for-loop example: body to 8, closers to 4/0."
  (should (equal (jai-ts-mode-tests--reindent
                  "foo :: () {\nfor * wall: game.walls {\nx := 1;\n}\n}\n")
                 "foo :: () {\n    for * wall: game.walls {\n        x := 1;\n    }\n}\n")))

(ert-deftest jai-ts-mode-test-indent-if-else ()
  "Bracketed if/else indents bodies one level, closers to the opener."
  (should (equal (jai-ts-mode-tests--reindent
                  "f :: () {\nif x {\ny();\n} else {\nz();\n}\n}\n")
                 "f :: () {\n    if x {\n        y();\n    } else {\n        z();\n    }\n}\n")))

(ert-deftest jai-ts-mode-test-indent-directive-no-crash ()
  "A `#'-led directive line indents without signalling and to its brace depth."
  (should (equal (jai-ts-mode-tests--reindent
                  "#import \"Basic\";\nmain :: () {\n#if OS == .WINDOWS {\nx := 1;\n}\n}\n")
                 "#import \"Basic\";\nmain :: () {\n    #if OS == .WINDOWS {\n        x := 1;\n    }\n}\n")))

(ert-deftest jai-ts-mode-test-indent-offset-knob ()
  "`jai-ts-mode-indent-offset' drives the produced indentation."
  (let ((jai-ts-mode-indent-offset 2))
    (should (equal (jai-ts-mode-tests--reindent "f :: () {\nx := 1;\n}\n")
                   "f :: () {\n  x := 1;\n}\n"))))

(ert-deftest jai-ts-mode-test-nested-block-comments ()
  "Jai's /* */ comments NEST: an inner */ does not end the outer comment."
  (with-temp-buffer
    (jai-ts-mode)
    (insert "x /* a /* b */ c */ y\n")
    (goto-char (point-min))
    (search-forward "c")
    (should (nth 4 (syntax-ppss)))        ; still inside the outer comment
    (search-forward "y")
    (should-not (nth 4 (syntax-ppss)))))  ; outside after both closers

(ert-deftest jai-ts-mode-test-here-string-braces-ignored ()
  "Braces inside a #string heredoc don't count toward nesting depth."
  (with-temp-buffer
    (jai-ts-mode)
    (insert "s := #string DONE\n{ not a real brace }\nDONE\nafter := 1;\n")
    (syntax-ppss (point-max))             ; force propertization
    (goto-char (point-min))
    (search-forward "{ not")
    (should (nth 3 (syntax-ppss)))        ; the brace is inside a string
    (goto-char (point-min))
    (search-forward "after :=")
    (beginning-of-line)
    (should (= 0 (car (syntax-ppss))))))  ; heredoc brace ignored → depth 0

(defun jai-ts-mode-tests--face-at (code needle)
  "Fontify CODE in `jai-ts-mode'; return the face at the start of NEEDLE."
  (with-temp-buffer
    (jai-ts-mode)
    (insert code)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward needle)
    (let ((f (get-text-property (match-beginning 0) 'face)))
      (if (and f (listp f)) (car f) f))))

(ert-deftest jai-ts-mode-test-font-lock-number ()
  "Numeric literals get constant face."
  (should (eq 'font-lock-constant-face
              (jai-ts-mode-tests--face-at "x := 42;\n" "42"))))

(ert-deftest jai-ts-mode-test-font-lock-note ()
  "@notes get preprocessor face."
  (should (eq 'font-lock-preprocessor-face
              (jai-ts-mode-tests--face-at "foo :: () {} @MyNote\n" "@MyNote"))))

(ert-deftest jai-ts-mode-test-font-lock-keyword ()
  "Keywords get keyword face."
  (should (eq 'font-lock-keyword-face
              (jai-ts-mode-tests--face-at "f :: () { defer x(); }\n" "defer"))))

(ert-deftest jai-ts-mode-test-font-lock-empty-cast-no-error ()
  "A word-less `.()' must not break font-lock (cast matcher group 3 may be nil)."
  ;; If group 3 is nil and not laxmatched, font-lock signals and disables
  ;; itself, so the later number never gets fontified.
  (should (eq 'font-lock-constant-face
              (jai-ts-mode-tests--face-at "x := foo.(); y := 42;\n" "42"))))

(ert-deftest jai-ts-mode-test-beginning-of-defun ()
  "From inside a proc, beginning-of-defun lands on its declaration line."
  (with-temp-buffer
    (jai-ts-mode)
    (insert "foo :: () {\n    bar();\n    baz();\n}\n")
    (goto-char (point-min))
    (search-forward "baz")
    (jai-ts-mode--beginning-of-defun)
    (should (equal (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position))
                   "foo :: () {"))))

(ert-deftest jai-ts-mode-test-beginning-of-defun-no-signal-malformed ()
  "beginning-of-defun must not signal on a buffer with no brace above point."
  (with-temp-buffer
    (jai-ts-mode)
    (insert "arr := foo(\n  bar,\n  baz")   ; unclosed paren, no { in buffer
    (goto-char (point-max))
    ;; With the unguarded inner loop this signals `beginning-of-buffer';
    ;; the guarded version returns normally.
    (should (progn (jai-ts-mode--beginning-of-defun) t))))

;; Drive the real COMMANDS (`end-of-defun'/`beginning-of-defun'), not the
;; `*-function' internals directly: the command pre-positions point at the
;; defun's beginning before calling `end-of-defun-function', and only that path
;; exposed the contract bug where the old guard no-op'd at depth 0.  Use a proc
;; with nested `.{}' struct literals (point at depth 2) — the shape that broke.
(defconst jai-ts-mode-tests--two-procs
  "add_wall :: (a: A) {\n    wall := W.{\n        mesh = m,\n    };\n}\nnext_thing :: () {\n    return;\n}\n")

(ert-deftest jai-ts-mode-test-end-of-defun-command-nested ()
  "C-M-e moves PAST a proc with nested braces, not backward to its declaration."
  (with-temp-buffer
    (jai-ts-mode)
    (insert jai-ts-mode-tests--two-procs)
    (goto-char (point-min))
    (search-forward "mesh = m")
    (end-of-defun)                          ; the real command, not the *-function
    (should (equal (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position))
                   "next_thing :: () {"))))

(ert-deftest jai-ts-mode-test-beginning-of-defun-command-nested ()
  "C-M-a from a deep line lands on the enclosing proc's declaration."
  (with-temp-buffer
    (jai-ts-mode)
    (insert jai-ts-mode-tests--two-procs)
    (goto-char (point-min))
    (search-forward "mesh = m")
    (beginning-of-defun)                    ; the real command
    (should (equal (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position))
                   "add_wall :: (a: A) {"))))

(ert-deftest jai-ts-mode-test-end-of-defun-command-no-signal-malformed ()
  "The `end-of-defun' command must not signal on an unclosed proc."
  (with-temp-buffer
    (jai-ts-mode)
    (insert "foo :: () {\n    bar(")        ; unclosed, no closing } below
    (goto-char (point-max))
    (should (progn (end-of-defun) t))))

(provide 'jai-ts-mode-tests)
;;; jai-ts-mode-tests.el ends here
