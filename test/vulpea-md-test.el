;;; vulpea-md-test.el --- Tests for vulpea-markdown -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with: emacs --batch -l test/run-tests.el

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'vulpea-md)

(defconst vulpea-md-test-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding this test file.")

(defun vulpea-md-test--write (dir name content)
  "Write CONTENT to NAME in DIR and return the absolute path."
  (let ((path (expand-file-name name dir)))
    (with-temp-file path (insert content))
    path))

(defun vulpea-md-test--notes ()
  "Return all indexed notes, sorted by title."
  (cl-sort (vulpea-db-query) #'string< :key #'vulpea-note-title))

(defun vulpea-md-test--citations (id)
  "Return sorted citation keys recorded for note ID."
  (sort (mapcar #'car
                (emacsql (vulpea-db)
                         [:select citekey :from md-citations
                          :where (= note-id $s1)]
                         id))
        #'string<))

;;; Unit tests (no database needed)

(ert-deftest vulpea-md-test-file-p ()
  (should (vulpea-md-file-p "/tmp/note.md"))
  (should (vulpea-md-file-p "/tmp/note.MARKDOWN"))
  (should-not (vulpea-md-file-p "/tmp/note.org"))
  (should-not (vulpea-md-file-p nil)))

(ert-deftest vulpea-md-test-front-matter ()
  (with-temp-buffer
    (insert "---\ntitle: Hi\nid: xyz\n---\n\nbody\n")
    (let ((fm (vulpea-md--front-matter)))
      (should (string-match-p "title: Hi" (car fm)))
      (should (= (cdr fm) (save-excursion (goto-char (point-min))
                                         (search-forward "---\n" nil t 2))))))
  (with-temp-buffer
    (insert "# No front matter\n")
    (should-not (vulpea-md--front-matter))))

(ert-deftest vulpea-md-test-yaml-scalar-and-comments ()
  (let ((front "title: \"A # B\" # a comment\nid: abc\n"))
    (should (equal (vulpea-md--yaml-scalar front '("title")) "A # B"))
    (should (equal (vulpea-md--yaml-scalar front '("id")) "abc")))
  (should (equal (vulpea-md--split-flow "a, \"b, c\", 'd'")
                 '("a" "b, c" "d"))))

(ert-deftest vulpea-md-test-yaml-list ()
  (let ((front "aliases: [One, \"Two words\"] # hi\ntags: #a #b\n"))
    (should (equal (vulpea-md--yaml-list front '("aliases"))
                   '("One" "Two words")))
    ;; The `#' prefix is kept by the YAML reader and stripped by the
    ;; parser when it fills the :tags field.
    (should (equal (vulpea-md--yaml-list front '("tags") t)
                   '("#a" "#b"))))
  (let ((front "aliases:\n  - First\n  - Second\n"))
    (should (equal (vulpea-md--yaml-list front '("aliases"))
                   '("First" "Second")))))

(ert-deftest vulpea-md-test-parse-links ()
  (let ((path (vulpea-md-test--write
               (temporary-file-directory) "vulpea-md-links.md"
               "---\nid: aaa\ntitle: Alpha\n---\n\n[[Beta|B]] [[id:ccc]]\n\
[file](beta.md#head) [url](https://example.com) ![img](pic.png)\n")))
    (unwind-protect
        (let* ((ctx (vulpea-md--parse path))
               (node (vulpea-parse-ctx-file-node ctx))
               (links (plist-get node :links)))
          (should (equal (plist-get node :id) "aaa"))
          (should (equal (plist-get node :title) "Alpha"))
          (should (eq (plist-get node :title-source) 'keyword))
          (should (= (length links) 4))
          (should (equal (mapcar (lambda (l) (plist-get l :type)) links)
                         '("md-wiki" "id" "md-file" "https")))
          (should (equal (plist-get (nth 2 links) :dest) "beta.md")))
      (delete-file path))))

;;; Integration test: real database, real sync

(ert-deftest vulpea-md-test-integration ()
  (let* ((root (make-temp-file "vulpea-md-vault-" t))
         (db (expand-file-name "test.db" root))
         (vulpea-db-location db)
         (vulpea-db--connection nil)
         (vulpea-db-sync-directories (list root))
         (vulpea-db-extra-extensions nil)
         (vulpea-md-mode nil))
    (unwind-protect
        (progn
          (vulpea-md-test--write
           root "alpha.md"
           "---\nid: aaa\ntitle: Alpha\naliases: [First, \"Old Alpha\"]\n\
tags: [project, \"#status\"]\nROAM_REFS: https://example.org/a\n---\n\n\
[[Beta|B]] [[Old Beta]] [[id:ccc]] [[Missing]]\n\
[inline](beta.md) [anchor](beta.md#heading) [ext](https://example.com)\n\
See [@doe2020] and @smith2021.\n")
          (vulpea-md-test--write
           root "beta.md"
           "---\nid: bbb\ntitle: Beta\naliases:\n  - Old Beta\n---\n\nBody.\n")
          (vulpea-md-test--write
           root "gamma.md"
           "---\nid: ccc\ntitle: Gamma\n---\n\nBody.\n")
          (vulpea-md-test--write
           root "plain.md" "# Untitled note without front matter\n")

          (vulpea-md-mode 1)
          (should (member ".md" vulpea-db-extra-extensions))
          (should (member ".markdown" vulpea-db-extra-extensions))
          (vulpea-db-sync-full-scan 'force)

          ;; Only notes with an id are indexed; plain.md is ignored.
          (let ((notes (vulpea-md-test--notes)))
            (should (= (length notes) 3))
            (should (equal (mapcar #'vulpea-note-title notes)
                           '("Alpha" "Beta" "Gamma")))
            (let ((alpha (vulpea-db-get-by-id "aaa")))
              (should (equal (vulpea-note-tags alpha) '("project" "status")))
              (should (equal (vulpea-note-aliases alpha)
                             '("First" "Old Alpha")))
              (should (equal (cdr (assoc "ROAM_REFS"
                                         (vulpea-note-properties alpha)))
                             "https://example.org/a"))
              ;; Wiki links, alias links, id links and relative file links
              ;; (including anchors) all resolve to real note ids, even
              ;; though beta.md is indexed after alpha.md.  External links
              ;; are kept as-is; unresolvable wiki links are dropped.
              (let* ((links (vulpea-note-links alpha))
                     (ids (cl-remove-duplicates
                           (cl-remove-if-not
                            (lambda (l) (string= (plist-get l :type) "id"))
                            links)
                           :key (lambda (l) (plist-get l :dest))
                           :test #'equal)))
                (should (= (length links) 6))
                (should (equal (sort (mapcar (lambda (l) (plist-get l :dest)) ids)
                                     #'string<)
                               '("bbb" "ccc")))
                (should (= 1 (cl-count-if
                              (lambda (l) (string= (plist-get l :type) "https"))
                              links)))
                (should-not (cl-some (lambda (l)
                                       (member (plist-get l :type)
                                               '("md-wiki" "md-file")))
                                     links)))
              (should (equal (vulpea-md-test--citations "aaa")
                             '("doe2020" "smith2021")))))

          ;; Backlinks use the same normalized links table as org notes.
          (let ((backlinks (vulpea-db-query-by-links-some '("bbb" "ccc"))))
            (should (= (length backlinks) 1))
            (should (equal (vulpea-note-id (car backlinks)) "aaa")))

          ;; Following links opens the indexed note, regardless of format.
          (let ((alpha-buffer (find-file (expand-file-name "alpha.md" root))))
            (unwind-protect
                (progn
                  (should (vulpea-md--follow-wiki-link "Beta"))
                  (should (equal (buffer-file-name)
                                 (expand-file-name "beta.md" root)))
                  ;; The markdown-follow-link-functions hook handles
                  ;; inline links to relative files as well.
                  (should (vulpea-md--follow-inline-link "gamma.md"))
                  (should (equal (buffer-file-name)
                                 (expand-file-name "gamma.md" root))))
              (dolist (name '("alpha.md" "beta.md" "gamma.md"))
                (when-let* ((buf (find-buffer-visiting
                                 (expand-file-name name root))))
                  (kill-buffer buf)))))

          ;; Toggling the mode removes everything it installed.
          (vulpea-md-mode -1)
          (should-not (member ".md" vulpea-db-extra-extensions))
          (should (equal vulpea-md--added-extensions nil))
          (should-not (advice-member-p #'vulpea-md--parse-advice
                                       'vulpea-db--parse-file))
          (should-not (member 'vulpea-md-links
                              (mapcar #'vulpea-extractor-name
                                      vulpea-db--extractors))))
      (when vulpea-md-mode (vulpea-md-mode -1))
      (vulpea-db-close)
      (delete-directory root t))))

(ert-deftest vulpea-md-test-add-id ()
  (let ((default-directory (temporary-file-directory)))
    (with-temp-buffer
      (insert "---\ntitle: Existing\n---\n\nBody\n")
      (let ((id (vulpea-md-add-id)))
        (should (stringp id))
        (should (string-match-p (format "id: %s" id) (buffer-string)))
        (goto-char (point-min))
        (should (= 1 (how-many "^title:")))))
    (with-temp-buffer
      (let ((id (vulpea-md-add-id)))
        (should (stringp id))
        (should (string-match-p "^---\n" (buffer-string)))
        (should (string-match-p (format "id: %s" id) (buffer-string)))))))

(provide 'vulpea-md-test)
;;; vulpea-md-test.el ends here
