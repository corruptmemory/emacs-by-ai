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

(ert-deftest cm/herdr-push-ok-p ()
  (should (cm/ai-herdr--push-ok-p '(:exit 0 :output "{\"type\":\"agent_prompted\"}")))
  (should-not (cm/ai-herdr--push-ok-p '(:exit 0 :output "{\"error\":\"agent_blocked\"}")))
  (should-not (cm/ai-herdr--push-ok-p '(:exit 1 :output ""))))

(ert-deftest cm/herdr-bind-agent-pushes-handshake ()
  ;; Stub the shell + UI: agent list from fixture, pick the working one, capture the push.
  (let (captured (cm/ai-bound-agent nil))
    (cl-letf (((symbol-function 'cm/ai-herdr--available-p) (lambda () t))
              ((symbol-function 'cm/ai-herdr--agent-list)
               (lambda () (cm/ai-herdr--parse-agent-list cm/herdr-test--fixture)))
              ((symbol-function 'cm/ai-herdr--this-emacs-descriptor)
               (lambda () '((server_name . "emacs-4242")
                            (socket . "/run/user/1000/emacs/emacs-4242")
                            (project_root . "/home/jim/projects/emacs-again/"))))
              ((symbol-function 'completing-read)
               (lambda (_p _c &rest _) "claude · emacs-again · working · wH:p1"))
              ((symbol-function 'cm/ai-herdr--push)
               (lambda (pane text) (setq captured (list pane text))
                 '(:exit 0 :output "{\"type\":\"agent_prompted\"}"))))
      (cm/ai-bind-agent)
      (should (equal (car captured) "wH:p1"))
      (should (string-prefix-p "[emacs-bridge] connect " (cadr captured)))
      (should (string-match-p "emacs-4242" (cadr captured)))
      ;; bind now also records the agent locally
      (should cm/ai-bound-agent)
      (should (equal (plist-get cm/ai-bound-agent :pane_id) "wH:p1")))))

(ert-deftest cm/herdr-bind-agent-blocked-confirm-declined ()
  ;; A blocked target with the user declining the y-or-n-p must NOT push.
  (let ((pushed nil)
        (blocked-fixture
         (concat "{\"result\":{\"agents\":[{\"agent\":\"claude\",\"agent_status\":\"blocked\","
                 "\"cwd\":\"/x\",\"pane_id\":\"wZ:p1\"}]}}")))
    (cl-letf (((symbol-function 'cm/ai-herdr--available-p) (lambda () t))
              ((symbol-function 'cm/ai-herdr--agent-list)
               (lambda () (cm/ai-herdr--parse-agent-list blocked-fixture)))
              ((symbol-function 'cm/ai-herdr--this-emacs-descriptor)
               (lambda () '((server_name . "e") (socket . "s") (project_root . "/x/"))))
              ((symbol-function 'completing-read) (lambda (&rest _) "claude · x · blocked · wZ:p1"))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
              ((symbol-function 'cm/ai-herdr--push) (lambda (&rest _) (setq pushed t) '(:exit 0 :output ""))))
      (should-error (cm/ai-bind-agent) :type 'user-error)
      (should-not pushed))))

(defconst cm/herdr-test--bound-agent
  '(:agent "claude" :agent_status "working"
    :cwd "/home/jim/projects/emacs-again" :pane_id "wH:p1")
  "Fixture agent plist for bound-agent tests.")

(ert-deftest cm/herdr-agent-mode-line-unbound ()
  (let ((cm/ai-bound-agent nil))
    (should-not (cm/ai-agent--mode-line))))

(ert-deftest cm/herdr-agent-mode-line-bound ()
  (let ((cm/ai-bound-agent cm/herdr-test--bound-agent))
    (let ((s (cm/ai-agent--mode-line)))
      (should (stringp s))
      (should (string-match-p "wH:p1" s))
      (should (eq (get-text-property 0 'face s) 'cm/ai-agent-mode-line)))))

(ert-deftest cm/herdr-agent-require-bound-returns-agent ()
  (let ((cm/ai-bound-agent cm/herdr-test--bound-agent))
    (should (equal (cm/ai-agent--require-bound) cm/herdr-test--bound-agent))))

(ert-deftest cm/herdr-agent-require-bound-errors-when-nil ()
  (let ((cm/ai-bound-agent nil))
    (should-error (cm/ai-agent--require-bound) :type 'user-error)))

(ert-deftest cm/herdr-agent-push-sends-to-bound-pane ()
  (let ((cm/ai-bound-agent cm/herdr-test--bound-agent)
        captured)
    (cl-letf (((symbol-function 'cm/ai-herdr--push)
               (lambda (pane text) (setq captured (list pane text))
                 '(:exit 0 :output "{\"type\":\"agent_prompted\"}"))))
      (cm/ai-agent-push "hello")
      (should (equal captured '("wH:p1" "hello"))))))

(ert-deftest cm/herdr-agent-push-errors-when-unbound ()
  (let ((cm/ai-bound-agent nil))
    (should-error (cm/ai-agent-push "hello") :type 'user-error)))

(ert-deftest cm/herdr-unbind-agent-clears-state ()
  (let ((cm/ai-bound-agent cm/herdr-test--bound-agent))
    (cm/ai-unbind-agent)
    (should-not cm/ai-bound-agent)))

(ert-deftest cm/herdr-global-mode-string-has-agent-eval ()
  (should (member '(:eval (cm/ai-agent--mode-line)) global-mode-string)))

(provide 'cm-herdr-tests)
;;; cm-herdr-tests.el ends here
