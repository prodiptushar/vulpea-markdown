;;; compile.el --- Byte-compile the package with dependencies available -*- lexical-binding: t; -*-

(let ((straight (expand-file-name "~/.config/emacs/.local/straight/build-31.1")))
  (when (file-directory-p straight)
    (dolist (pkg '("vulpea" "emacsql" "markdown-mode" "s" "dash" "seq"))
      (let ((dir (expand-file-name pkg straight)))
        (when (file-directory-p dir)
          (add-to-list 'load-path dir))))))

(add-to-list 'load-path (expand-file-name ".." (file-name-directory
                                                (or load-file-name
                                                    buffer-file-name))))

(batch-byte-compile
 (list (expand-file-name "../vulpea-md.el"
                         (file-name-directory (or load-file-name
                                                  buffer-file-name)))))
