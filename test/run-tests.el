;;; run-tests.el --- Batch test runner for vulpea-markdown -*- lexical-binding: t; -*-

;; Usage: emacs --batch -l test/run-tests.el

(require 'ert)

(let ((straight (expand-file-name "~/.config/emacs/.local/straight/build-31.1")))
  (when (file-directory-p straight)
    (dolist (pkg '("vulpea" "emacsql" "markdown-mode" "s" "dash" "seq"))
      (let ((dir (expand-file-name pkg straight)))
        (when (file-directory-p dir)
          (add-to-list 'load-path dir))))))

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (root (expand-file-name ".." here)))
  (add-to-list 'load-path root)
  (add-to-list 'load-path here))

(require 'vulpea-md)
(require 'vulpea-md-test)

(ert-run-tests-batch-and-exit t)
