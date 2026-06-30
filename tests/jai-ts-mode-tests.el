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

(provide 'jai-ts-mode-tests)
;;; jai-ts-mode-tests.el ends here
