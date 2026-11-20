;;; vulpea-md.el --- Markdown notes in the Vulpea database -*- lexical-binding: t; -*-

;; Project: vulpea-markdown
;; URL: https://github.com/prodiptushar/vulpea-markdown
;; Port of md-roam (Noboru Ota, https://github.com/nobiot/md-roam) from
;; org-roam to Vulpea v2.  License: GPL-3.0-or-later, same as both.
;; Package-Requires: ((emacs "29.1") (vulpea "2.0") (markdown-mode "2.5"))

;;; Commentary:
;;
;; md-roam advised ~15 org-roam functions.  Vulpea has no such seam, but
;; it has two clean ones, and this file uses only those:
;;
;;  1. `vulpea-db--parse-file' returns a `vulpea-parse-ctx'.  For markdown
;;     files we build that struct ourselves (no org-element involved).
;;     Everything downstream (notes/tags/aliases/links tables, backlinks,
;;     queries) then works unchanged.
;;  2. Extractors may rewrite :links in note-data.  Wiki links and
;;     relative file links are resolved to `id:' links there, so they show
;;     up in backlinks exactly like org links.
;;
;; Enabling `vulpea-md-mode' also registers the markdown extensions with
;; `vulpea-db-extra-extensions', so the sync scanner actually sees them.
;;
;; Front matter understood (YAML, file-level note only, like md-roam):
;;
;;   ---
;;   id: 6b0b6b0e-...
;;   title: My note
;;   aliases: [One, "Two words"]      # or a block list; ROAM_ALIASES works
;;   tags: [a, b]                     # or: tags: #a #b
;;   ---
;;
;; Links understood in the body:
;;   [[Title]]  [[Title|label]]  [[id:UUID]]  [label](other.md)
;;   [label](other.md#heading)  [label](id:UUID)  [label](https://...)
;;   and pandoc [@citekey].
;;
;; Usage:
;;   (require 'vulpea-md)
;;   (vulpea-md-mode 1)             ; BEFORE vulpea-db-autosync-mode
;;   (vulpea-db-autosync-mode 1)
;;
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'org-id)
(require 'emacsql)
(require 'json)
(require 'vulpea)
(require 'markdown-mode)

(defconst vulpea-md-version "1.0.0"
  "Version of vulpea-markdown.")

(defgroup vulpea-md nil
  "Markdown notes in Vulpea."
  :group 'vulpea
  :prefix "vulpea-md-")

(defcustom vulpea-md-extensions '("md" "markdown")
  "File extensions (without the dot) treated as markdown notes.
Change this before enabling `vulpea-md-mode', or re-enable the mode
afterwards."
  :type '(repeat string)
  :group 'vulpea-md)

(defcustom vulpea-markdown-directory
  (expand-file-name "markdown" (or (bound-and-true-p vulpea-directory)
                                   (bound-and-true-p org-directory)
                                   user-emacs-directory))
  "Directory where new markdown notes are stored.
Defaults to a `markdown' subdirectory of `vulpea-directory' (falling
back to `org-directory').  It is created automatically if missing."
  :type 'directory
  :group 'vulpea-md)

(defvar vulpea-md--added-extensions nil
  "Extensions this mode added to `vulpea-db-extra-extensions'.")

;;;; Helpers

(defun vulpea-md--dot-extensions ()
  "Return `vulpea-md-extensions' with leading dots, as Vulpea wants them."
  (mapcar (lambda (ext) (concat "." ext)) vulpea-md-extensions))

(defun vulpea-md-file-p (path)
  "Non-nil when PATH names a markdown note file."
  (and (stringp path)
       (member (downcase (or (file-name-extension path) ""))
               (mapcar #'downcase vulpea-md-extensions))
       t))

(defun vulpea-md--front-matter ()
  "Return (TEXT . BODY-START) for the YAML front matter, or nil.
A UTF-8 BOM at the beginning of the file is tolerated."
  (save-excursion
    (goto-char (point-min))
    (when (eq (char-after) ?\ufeff)
      (forward-char 1))
    (when (looking-at "---[ \t]*$")
      (forward-line 1)
      (let ((beg (point)))
        (when (re-search-forward "^\\(?:---\\|\\.\\.\\.\\)[ \t]*$" nil t)
          (cons (buffer-substring-no-properties beg (match-beginning 0))
                (min (1+ (match-end 0)) (point-max))))))))

(defun vulpea-md--unquote (s)
  "Strip one pair of surrounding quotes from S."
  (if (string-match "\\`\\(['\"]\\)\\(.*\\)\\1\\'" s)
      (match-string 2 s)
    s))

(defun vulpea-md--strip-comment (s)
  "Remove a trailing YAML comment (#) from S outside quotes."
  (let ((quote nil) (escape nil) (i 0) (cut nil))
    (while (and (< i (length s)) (not cut))
      (let ((c (aref s i)))
        (cond
         (escape (setq escape nil))
         ((and quote (eq c ?\\) (eq quote ?\")) (setq escape t))
         (quote (when (eq c quote) (setq quote nil)))
         ((memq c '(?\" ?\')) (setq quote c))
         ((and (eq c ?#)
               (or (= i 0)
                   (memq (aref s (1- i)) '(?\s ?\t)))
               (not (eq (aref s 0) ?#)))
          (setq cut (substring s 0 i)))))
      (setq i (1+ i)))
    (string-trim (or cut s))))

(defun vulpea-md--yaml-scalar (front keys)
  "Value of the first of KEYS found in FRONT text, or nil."
  (let ((case-fold-search t))
    (when (string-match
           (format "^[ \t]*\\(?:%s\\):[ \t]*\\(.+?\\)[ \t]*$" (regexp-opt keys))
           front)
      (vulpea-md--unquote (vulpea-md--strip-comment (match-string 1 front))))))

(defun vulpea-md--split-flow (s)
  "Split a YAML flow sequence S on commas outside quotes."
  (let ((chunks nil) (start 0) (quote nil) (escape nil))
    (dotimes (i (length s))
      (let ((c (aref s i)))
        (cond
         (escape (setq escape nil))
         ((and quote (eq c ?\\) (eq quote ?\")) (setq escape t))
         (quote (when (eq c quote) (setq quote nil)))
         ((memq c '(?\" ?\')) (setq quote c))
         ((eq c ?,)
          (push (substring s start i) chunks)
          (setq start (1+ i))))))
    (push (substring s start) chunks)
    (mapcar (lambda (x) (vulpea-md--unquote (string-trim x)))
            (nreverse chunks))))

(defun vulpea-md--yaml-list (front keys &optional split-scalar)
  "List value of the first of KEYS in FRONT text.
Understands flow (`[a, b]') and block (`- a') sequences.  With
SPLIT-SCALAR, a bare `a b, c' value is split on spaces and commas."
  (let ((case-fold-search t))
    (when (string-match
           (format "^[ \t]*\\(?:%s\\):[ \t]*\\(.*?\\)[ \t]*$" (regexp-opt keys))
           front)
      (let* ((raw (match-string 1 front))
             ;; A bare `tags: #a #b' is a value, not a comment.
             (inline (if (and split-scalar (string-prefix-p "#" (string-trim raw)))
                         (string-trim raw)
                       (vulpea-md--strip-comment raw)))
             (rest (cdr (split-string (substring front (match-end 0)) "\n"))))
        (cond
         ((string-prefix-p "[" inline)
          (vulpea-md--split-flow
           (string-trim inline "\\[\\s-*" "\\s-*\\]")))
         ((not (string-empty-p inline))
          (if split-scalar
              (split-string inline "[ \t,*]+" t "\\s-*")
            (list (vulpea-md--unquote inline))))
         (t
          (cl-loop for line in rest
                   while (string-match "^[ \t]*-[ \t]+\\(.+?\\)[ \t]*$" line)
                   collect (vulpea-md--unquote
                            (vulpea-md--strip-comment (match-string 1 line))))))))))

(defun vulpea-md--links (beg)
  "Collect links in the current buffer from BEG as Vulpea link plists.
Wiki and relative-file links are emitted unresolved (types `md-wiki'
and `md-file'); `vulpea-md--resolve-links' turns them into id links."
  (let (links)
    ;; `string-trim' clobbers match data in some Emacs versions, so keep
    ;; the outer match data and capture positions before trimming.
    (save-match-data
      (save-excursion
        (goto-char beg)
        (while (re-search-forward "\\[\\[\\([^]\n]+\\)\\]\\]" nil t)
          (let* ((pos (match-beginning 0))
                 (parts (split-string (match-string-no-properties 1) "|"))
                 (target (string-trim (car parts)))
                 (desc (and (cdr parts) (string-trim (cadr parts))))
                 (id (and (string-prefix-p "id:" target) (substring target 3))))
            (push (list :dest (or id target)
                        :type (if id "id" "md-wiki")
                        :pos pos
                        :description desc)
                  links)))
        (goto-char beg)
        (while (re-search-forward
                "\\(!?\\)\\[\\([^]\n]*\\)\\](\\([^) \t\n]+\\)\\(?:[ \t]+\"[^\"]*\"\\)?)"
                nil t)
          (unless (string= (match-string 1) "!")
            (let* ((pos (match-beginning 0))
                   (desc (match-string-no-properties 2))
                   (url (match-string-no-properties 3))
                   ;; Anchors and query strings do not take part in note lookup.
                   (file (car (split-string url "[#?]"))))
              (push (cond
                     ((string-match "\\`\\([A-Za-z][A-Za-z0-9+.-]*\\):\\(.*\\)" url)
                      (list :dest (match-string 2 url) :type (match-string 1 url)
                            :pos pos :description desc))
                     ((vulpea-md-file-p file)
                      (list :dest file :type "md-file"
                            :pos pos :description desc)))
                    links)))))
      (nreverse (delq nil links)))))

;;;; Parsing: markdown file -> `vulpea-parse-ctx'

(defun vulpea-md--parse (path)
  "Parse markdown file at PATH into a `vulpea-parse-ctx'."
  (with-temp-buffer
    (insert-file-contents path)
    (let* ((attrs (file-attributes path))
           (fm (vulpea-md--front-matter))
           (front (car fm))
           (id (and front (vulpea-md--yaml-scalar front '("id" "ROAM_ID"))))
           (yaml-title (and front (vulpea-md--yaml-scalar front '("title"))))
           (title (or yaml-title (file-name-base path)))
           (refs (and front (vulpea-md--yaml-scalar front '("ROAM_REFS"))))
           (file-node
            (when id
              (list :id id
                    :title title
                    :title-source (if yaml-title 'keyword 'filename)
                    :aliases (and front
                                  (vulpea-md--yaml-list
                                   front '("aliases" "ROAM_ALIASES")))
                    :tags (and front
                               (mapcar (lambda (s)
                                         (replace-regexp-in-string "\\`[#@]" "" s))
                                       (vulpea-md--yaml-list
                                        front '("tags" "ROAM_TAGS") t)))
                    :links (vulpea-md--links (or (cdr fm) (point-min)))
                    :properties (append
                                 (list (cons "ID" id) (cons "TITLE" title))
                                 (when refs (list (cons "ROAM_REFS" refs))))
                    :meta nil
                    :todo nil :priority nil
                    :scheduled nil :deadline nil :closed nil
                    :category (file-name-base path)
                    :category-source 'filename
                    :attach-dir nil
                    :file-title title))))
      (make-vulpea-parse-ctx
       :path path
       :ast nil
       :file-node file-node
       :heading-nodes nil
       :hash (secure-hash 'sha256 (current-buffer))
       :mtime (float-time (file-attribute-modification-time attrs))
       :size (file-attribute-size attrs)))))

(defun vulpea-md--parse-advice (orig path)
  "Around advice for `vulpea-db--parse-file'.
Call ORIG with PATH for non-markdown files; parse markdown ourselves."
  (if (vulpea-md-file-p path)
      (vulpea-md--parse path)
    (funcall orig path)))

;;;; Note lookup
;;
;; Resolution must not depend on the order in which Vulpea happens to
;; visit files: a note can link forward to a note that has not been
;; indexed yet.  The database is tried first (it also covers org notes),
;; then an index built from the front matter of the markdown files on
;; disk.  The index is invalidated whenever a candidate file appears,
;; disappears or changes its mtime.

(defvar vulpea-md--front-matter-index nil
  "Cached plist with :stamp, :by-title and :by-path tables.")

(defun vulpea-md--index-files ()
  "List markdown files under the configured sync directories."
  (cl-loop for dir in vulpea-db-sync-directories
           when (file-directory-p dir)
           append (cl-remove-if-not
                   #'vulpea-md-file-p
                   (directory-files-recursively dir "" nil))))

(defun vulpea-md--front-matter-index ()
  "Return the on-disk front-matter index, rebuilding it if stale."
  (let* ((files (vulpea-md--index-files))
         (stamp (mapcar (lambda (file)
                          (cons file (file-attribute-modification-time
                                      (file-attributes file))))
                        files)))
    (when (or (null vulpea-md--front-matter-index)
              (not (equal stamp (plist-get vulpea-md--front-matter-index
                                           :stamp))))
      (let ((by-title (make-hash-table :test 'equal))
            (by-path (make-hash-table :test 'equal)))
        (dolist (file files)
          (with-temp-buffer
            (insert-file-contents file)
            (when-let* ((fm (vulpea-md--front-matter))
                        (front (car fm))
                        (id (vulpea-md--yaml-scalar front '("id" "ROAM_ID"))))
              (puthash (file-truename file) id by-path)
              (let ((title (vulpea-md--yaml-scalar front '("title"))))
                (when title
                  (puthash title id by-title)))
              (dolist (alias (vulpea-md--yaml-list
                              front '("aliases" "ROAM_ALIASES")))
                (puthash alias id by-title)))))
        (setq vulpea-md--front-matter-index
              (list :stamp stamp :by-title by-title :by-path by-path))))
    vulpea-md--front-matter-index))

(defun vulpea-md--index-id-by-title (title)
  "ID recorded for TITLE in the on-disk index, or nil."
  (gethash title (plist-get (vulpea-md--front-matter-index) :by-title)))

(defun vulpea-md--index-id-by-path (path)
  "ID recorded for PATH in the on-disk index, or nil."
  (gethash (file-truename path)
           (plist-get (vulpea-md--front-matter-index) :by-path)))

;;;; Extractors

(defun vulpea-md--id-by-title (title)
  "ID of the note titled TITLE, or nil.
Looks in the database first, then in the on-disk front-matter index so
forward links resolve even before the target has been indexed."
  (or (caar (emacsql (vulpea-db)
                     [:select [id] :from notes :where (= title $s1)]
                     title))
      (vulpea-md--index-id-by-title title)))

(defun vulpea-md--id-by-alias (alias)
  "ID of a note with ALIAS, or nil.
Vulpea stores aliases as a JSON array in the notes table, so the
match is done in Lisp, with the on-disk index as fallback."
  (or (cl-loop for row in (emacsql (vulpea-db) [:select [id aliases] :from notes])
               thereis
               (let ((value (cadr row)))
                 (when value
                   (let* ((decoded (if (stringp value)
                                       (json-parse-string
                                        value :object-type 'alist
                                        :array-type 'list :null-object nil)
                                     value))
                          (aliases (if (vectorp decoded)
                                       (append decoded nil) decoded)))
                     (when (member alias aliases) (car row))))))
      (vulpea-md--index-id-by-title alias)))

(defun vulpea-md--id-by-path (rel from)
  "ID of the file-level note at REL, resolved against file FROM, or nil."
  (let ((absolute (expand-file-name rel (file-name-directory from))))
    (or (caar (emacsql (vulpea-db)
                       [:select [id] :from notes
                        :where (and (= path $s1) (= level 0))]
                       absolute))
        (vulpea-md--index-id-by-path absolute))))

(defun vulpea-md--resolve-links (_ctx note-data)
  "Rewrite `md-wiki' and `md-file' links of NOTE-DATA into `id' links.
Unresolvable ones are dropped, as md-roam does."
  (let ((path (plist-get note-data :path)))
    (when (vulpea-md-file-p path)
      (plist-put
       note-data :links
       (cl-loop for link in (plist-get note-data :links)
                for dest = (plist-get link :dest)
                for id = (pcase (plist-get link :type)
                           ("md-wiki" (or (vulpea-md--id-by-title dest)
                                          (vulpea-md--id-by-alias dest)))
                           ("md-file" (vulpea-md--id-by-path dest path))
                           (_ t))
                when id
                collect (if (eq id t)
                            link
                          (list :dest id :type "id"
                                :pos (plist-get link :pos)
                                :description (plist-get link :description))))))
    note-data))

(defun vulpea-md--extract-citations (_ctx note-data)
  "Store pandoc [@citekey] citations of markdown NOTE-DATA."
  (let ((path (plist-get note-data :path))
        (id (plist-get note-data :id))
        keys)
    (when (and (vulpea-md-file-p path) id)
      (with-temp-buffer
        (insert-file-contents path)
        (while (re-search-forward
                "\\(?:[^[:alnum:]]\\|^\\)-?@\\([-a-zA-Z0-9_+:]+\\)" nil t)
          (push (match-string-no-properties 1) keys)))
      (emacsql (vulpea-db) [:delete :from md-citations :where (= note-id $s1)] id)
      (when keys
        (emacsql (vulpea-db)
                 [:insert :or :replace :into md-citations :values $v1]
                 (mapcar (lambda (k) (vector id k)) (delete-dups keys)))))
    note-data))

;;;; Following and inserting links

(defun vulpea-md--follow-wiki-link (name &optional other)
  "Before-until advice for `markdown-follow-wiki-link'.
Follow NAME to an indexed note, in another window when OTHER is non-nil."
  (when-let* ((file (buffer-file-name (buffer-base-buffer)))
              (vulpea-md-file-p file)
              (id (or (vulpea-md--id-by-title name)
                      (vulpea-md--id-by-alias name)))
              (note (vulpea-db-get-by-id id)))
    (funcall (if other #'find-file-other-window #'find-file)
             (vulpea-note-path note))
    t))

(defun vulpea-md--follow-inline-link (url)
  "Follow markdown inline link URL when it points at a Vulpea note.
Intended for `markdown-follow-link-functions'."
  (when-let* ((file (buffer-file-name (buffer-base-buffer)))
              (vulpea-md-file-p file)
              (id (cond
                   ((string-prefix-p "id:" url) (substring url 3))
                   ((vulpea-md-file-p (car (split-string url "[#?]")))
                    (vulpea-md--id-by-path
                     (car (split-string url "[#?]")) file))))
              (note (vulpea-db-get-by-id id)))
    (find-file (vulpea-note-path note))
    t))

;;;###autoload
(defun vulpea-md-insert ()
  "Pick a note and insert a [[wiki link]] to it."
  (interactive)
  (let ((note (vulpea-select "Note")))
    (insert "[[" (vulpea-note-title note) "]]")))

(defun vulpea-md--slug (title)
  "Return a file-name-safe slug for TITLE."
  (let ((slug (replace-regexp-in-string
               "\\`-+|-+\\'" ""
               (replace-regexp-in-string "[^[:alnum:]]+" "-"
                                         (downcase title)))))
    (if (string-empty-p slug) "note" slug)))

(defun vulpea-md--unique-path (dir slug)
  "Return an unused .md path in DIR based on SLUG."
  (let ((path (expand-file-name (concat slug ".md") dir))
        (n 1))
    (while (file-exists-p path)
      (setq path (expand-file-name (format "%s-%d.md" slug (1+ n)) dir))
      (setq n (1+ n)))
    path))

;;;###autoload
(defun vulpea-md-new-note (title)
  "Create and open a new markdown note titled TITLE with a fresh id.
The file is written to `vulpea-markdown-directory', which is created
if it does not exist.  Saving the file lets Vulpea index it when
autosync is enabled."
  (interactive "sNote title: ")
  (let* ((dir (file-name-as-directory
               (expand-file-name vulpea-markdown-directory)))
         (path (vulpea-md--unique-path dir (vulpea-md--slug title)))
         (id (org-id-uuid)))
    (make-directory dir t)
    (find-file path)
    (insert (format "---\nid: %s\ntitle: %S\n---\n\n" id title))
    (save-buffer)
    (message "Created markdown note: %s" path)
    path))

(defalias 'vulpea-markdown-new-note #'vulpea-md-new-note
  "Alias for `vulpea-md-new-note'.")

;;;###autoload
(defun vulpea-md-add-id ()
  "Add an `id' (and a `title' if needed) to the front matter."
  (interactive)
  (let* ((id (org-id-uuid))
         (fm (vulpea-md--front-matter))
         (front (car fm))
         (title (file-name-base (or buffer-file-name (buffer-name)))))
    (save-excursion
      (cond
       ((and front (vulpea-md--yaml-scalar front '("id" "ROAM_ID")))
        (user-error "This note already has an id"))
       (front
        (goto-char (point-min))
        (when (eq (char-after) ?\ufeff) (forward-char 1))
        (forward-line 1)
        (insert (format "id: %s\n" id))
        (unless (vulpea-md--yaml-scalar front '("title"))
          (insert (format "title: %s\n" title))))
       (t
        (goto-char (point-min))
        (insert (format "---\nid: %s\ntitle: %s\n---\n\n" id title)))))
    id))

;;;###autoload
(defun vulpea-md-reindex ()
  "Force a full Vulpea re-index after changing markdown settings."
  (interactive)
  (vulpea-db-sync-full-scan 'force))

;;;; Mode

;;;###autoload
(define-minor-mode vulpea-md-mode
  "Index markdown files into the Vulpea database.
Enable before `vulpea-db-autosync-mode' and re-index with
\\[vulpea-md-reindex] when toggling it in a running session."
  :global t
  :lighter " vmd"
  (if vulpea-md-mode
      (progn
        ;; Make the sync scanner see markdown files.
        (setq vulpea-md--added-extensions
              (cl-remove-if (lambda (ext)
                              (member ext vulpea-db-extra-extensions))
                            (vulpea-md--dot-extensions)))
        (setq vulpea-db-extra-extensions
              (append vulpea-db-extra-extensions vulpea-md--added-extensions))
        (advice-add 'vulpea-db--parse-file :around #'vulpea-md--parse-advice)
        (advice-add 'markdown-follow-wiki-link
                    :before-until #'vulpea-md--follow-wiki-link)
        (add-hook 'markdown-follow-link-functions
                  #'vulpea-md--follow-inline-link)
        (vulpea-db-register-extractor
         (make-vulpea-extractor
          :name 'vulpea-md-links
          :priority 10
          :requires-ast nil
          :reads-dir-locals nil
          :extract-fn #'vulpea-md--resolve-links))
        (vulpea-db-register-extractor
         (make-vulpea-extractor
          :name 'vulpea-md-citations
          :version 1
          :priority 20
          :requires-ast nil
          :reads-dir-locals nil
          :schema '((md-citations
                     [(note-id :not-null) (citekey :not-null)]
                     (:primary-key [note-id citekey])
                     (:foreign-key [note-id] :references notes [id]
                                   :on-delete :cascade)))
          :extract-fn #'vulpea-md--extract-citations)))
    (setq vulpea-db-extra-extensions
          (cl-set-difference vulpea-db-extra-extensions
                             vulpea-md--added-extensions :test #'equal))
    (setq vulpea-md--added-extensions nil)
    (advice-remove 'vulpea-db--parse-file #'vulpea-md--parse-advice)
    (advice-remove 'markdown-follow-wiki-link #'vulpea-md--follow-wiki-link)
    (remove-hook 'markdown-follow-link-functions
                 #'vulpea-md--follow-inline-link)
    (vulpea-db-unregister-extractor 'vulpea-md-links)
    (vulpea-db-unregister-extractor 'vulpea-md-citations)))

(provide 'vulpea-md)
(provide 'vulpea-markdown)
;;; vulpea-md.el ends here
