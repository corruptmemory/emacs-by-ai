;;; cm-project-roots-tests.el --- Tests for cm-project-roots  -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cm-project-roots)

(ert-deftest cm/project-roots-harness-loads ()
  "The library loads and the marker constant is defined."
  (should (equal cm/project-roots-file ".project-roots")))

(ert-deftest cm/project-roots--parse-handles-comments-blanks-paths ()
  (should (equal
           (cm/project-roots--parse
            "# full comment\n\n/abs/dir\nrel/dir\n~/home-dir  # trailing\n" "/base")
           (list "/abs/dir" "/base/rel/dir" (expand-file-name "~/home-dir")))))

(provide 'cm-project-roots-tests)
;;; cm-project-roots-tests.el ends here
