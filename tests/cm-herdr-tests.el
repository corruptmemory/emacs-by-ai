;;; cm-herdr-tests.el --- Tests for cm-herdr  -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cm-herdr)
(require 'json)

(defconst cm/herdr-test--fixture
  (concat "{\"id\":\"cli:agent:list\",\"result\":{\"type\":\"agent_list\",\"agents\":["
          "{\"agent\":\"claude\",\"agent_status\":\"idle\",\"cwd\":\"/home/jim/projects/other\",\"pane_id\":\"wF:p1\",\"workspace_id\":\"wF\"},"
          "{\"agent\":\"claude\",\"agent_status\":\"working\",\"cwd\":\"/home/jim/projects/emacs-again\",\"pane_id\":\"wH:p1\",\"workspace_id\":\"wH\"}"
          "]}}"))

(ert-deftest cm/herdr-parse-agent-list ()
  (let ((agents (cm/ai-herdr--parse-agent-list cm/herdr-test--fixture)))
    (should (= (length agents) 2))
    (should (equal (plist-get (car agents) :agent) "claude"))
    (should (equal (plist-get (nth 1 agents) :pane_id) "wH:p1"))
    (should (equal (plist-get (nth 1 agents) :agent_status) "working"))))

(ert-deftest cm/herdr-candidate-label ()
  (let ((a '(:agent "claude" :agent_status "idle" :cwd "/home/jim/projects/other" :pane_id "wF:p1")))
    (should (equal (cm/ai-herdr--candidate-label a) "claude · other · idle · wF:p1"))))

(ert-deftest cm/herdr-sort-floats-cwd-match ()
  (let* ((agents (cm/ai-herdr--parse-agent-list cm/herdr-test--fixture))
         (sorted (cm/ai-herdr--sort-agents agents "/home/jim/projects/emacs-again/")))
    ;; the emacs-again agent (wH:p1) floats to the top
    (should (equal (plist-get (car sorted) :pane_id) "wH:p1"))))

(ert-deftest cm/herdr-sort-multi-match-stable ()
  (let* ((agents (list '(:agent "claude" :agent_status "idle"
                          :cwd "/home/jim/projects/emacs-again/sub1" :pane_id "wA:p1")
                        '(:agent "claude" :agent_status "idle"
                          :cwd "/home/jim/projects/other" :pane_id "wB:p1")
                        '(:agent "claude" :agent_status "working"
                          :cwd "/home/jim/projects/emacs-again/sub2" :pane_id "wC:p1")))
         (sorted (cm/ai-herdr--sort-agents agents "/home/jim/projects/emacs-again/")))
    ;; both matches (wA, wC) precede the non-match (wB), and keep their
    ;; original relative order (wA before wC) -- proves stability, not just
    ;; "a single match floats."
    (should (equal (mapcar (lambda (a) (plist-get a :pane_id)) sorted)
                   '("wA:p1" "wC:p1" "wB:p1")))))

(ert-deftest cm/herdr-handshake-payload ()
  (let* ((desc '((server_name . "emacs-4242")
                 (socket . "/run/user/1000/emacs/emacs-4242")
                 (project_root . "/home/jim/projects/emacs-again/")))
         (s (cm/ai-herdr--handshake-payload desc)))
    (should (string-prefix-p "[emacs-bridge] connect " s))
    (let* ((json (substring s (length "[emacs-bridge] connect ")))
           (json-object-type 'plist) (json-key-type 'keyword)
           (p (json-read-from-string json)))
      (should (equal (plist-get p :server_name) "emacs-4242"))
      (should (equal (plist-get p :socket) "/run/user/1000/emacs/emacs-4242"))
      (should (equal (plist-get p :project_root) "/home/jim/projects/emacs-again/"))
      (should (equal (plist-get p :protocol) 1)))))

(provide 'cm-herdr-tests)
;;; cm-herdr-tests.el ends here
