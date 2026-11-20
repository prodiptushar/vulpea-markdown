# vulpea-markdown

[![License GPL 3][badge-license]](http://www.gnu.org/licenses/gpl-3.0.txt)

Markdown notes in the [Vulpea](https://github.com/d12frosted/vulpea) v2
database.  This is a port of [md-roam](https://github.com/nobiot/md-roam)
from Org-roam to Vulpea: it lets Markdown and Org files live in the same
Vulpea database, with titles, aliases, tags, backlinks, queries and
Pandoc-style citations working for both.

Unlike md-roam, this package does not advise a dozen internals.  It uses
only two supported Vulpea seams:

1. `vulpea-db--parse-file` is advised to build a `vulpea-parse-ctx`
   directly for Markdown files (no `org-element` involved).
2. Two extractors rewrite `:links` into `id:` links and store citations,
   so everything downstream — notes/tags/links tables, backlinks,
   `vulpea-select`, org-ql-style queries — works unchanged.

[badge-license]: https://img.shields.io/badge/license-GPL--3.0-blue.svg

## Requirements

- Emacs 29.1+
- `vulpea` 2.0+ (developed against 2.7)
- `markdown-mode` 2.5+
- `emacsql` (Vulpea dependency)

## Installation

The package is not on MELPA.  The repository is
<https://github.com/prodiptushar/vulpea-markdown>.

### Regular Emacs with `use-package` + `straight.el`

```elisp
(use-package vulpea-md
  :straight (vulpea-markdown :type git :host github
                             :repo "prodiptushar/vulpea-markdown"
                             :files ("vulpea-md.el"))
  :after vulpea
  :config
  (vulpea-md-mode 1))
```

Or, without straight, clone the repository and point `use-package` at it:

```sh
git clone https://github.com/prodiptushar/vulpea-markdown.git \
  ~/.emacs.d/lisp/vulpea-markdown
```

```elisp
(use-package vulpea-md
  :load-path "~/.emacs.d/lisp/vulpea-markdown"
  :after vulpea
  :config
  (vulpea-md-mode 1))
```

### Doom Emacs

Add to `~/.doom.d/packages.el` (or `~/.config/doom/packages.el`) and run
`doom sync`:

```elisp
(package! vulpea-md
  :recipe (:host github :repo "prodiptushar/vulpea-markdown"
           :files ("vulpea-md.el")))
```

Then add to `~/.doom.d/config.el` (or `~/.config/doom/config.el`) and
restart Doom:

```elisp
(after! vulpea
  (vulpea-md-mode 1))
```

If Vulpea's autosync was already running when the mode was enabled, run
`M-x vulpea-md-reindex` once so Markdown files are indexed.

## Configuration

A minimal setup for a plain Emacs config.  **Enable `vulpea-md-mode`
before `vulpea-db-autosync-mode`** — the mode registers `.md` and
`.markdown` with `vulpea-db-extra-extensions`, which the sync scanner
needs:

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp/vulpea-markdown")
(require 'vulpea-md)

(setq vulpea-directory "~/notes")          ; your vault ( Org + Markdown )
(vulpea-md-mode 1)                         ; must come first
(vulpea-db-autosync-mode 1)
```

Other extensions can be changed before enabling the mode:

```elisp
(setq vulpea-md-extensions '("md" "markdown" "mdown"))
```

If you toggle the mode in a running session, force a re-index so the
database matches the new setup:

```elisp
M-x vulpea-md-reindex
```

## Note format

Only the file-level note is indexed, and it needs an `id` in YAML front
matter — exactly like md-roam.  Headings are not separate notes.

```markdown
---
id: 6b0b6b0e-0c1d-4f6e-9f1a-3b2c4d5e6f70
title: My note
aliases: [One, "Two words"]     # ROAM_ALIASES also works
tags: [project, "#status"]      # or: tags: #project #status
ROAM_REFS: https://example.org/source
---

# My note

Links: [[Another note]], [[Another note|friendly label]],
[[alias of another note]], [[id:UUID-of-a-note]],
[relative file](another-note.md), [with anchor](another-note.md#intro),
[external](https://example.com).

A Pandoc citation like [@doe2020] or -@smith2021 is indexed too.
```

`M-x vulpea-md-add-id` inserts an `id` (and a `title` if needed) into the
front matter of the current file.

### Link resolution

- `[[Title]]`, `[[Title|label]]` and alias links resolve to a note's id.
- `[label](other.md)` and `[label](other.md#heading)` resolve by path;
  anchors and query strings are ignored for lookup.
- `[[id:UUID]]` and `[label](id:UUID)` work directly.
- External schemes (`https`, `http`, ...) are indexed as their own link
  type, just like Org links.
- Unresolvable wiki/file links are dropped, as in md-roam.

Resolution is **order-independent**: a forward link to a note that has
not been indexed yet still resolves.  The package builds a small index
from the front matter of the Markdown files in your sync directories and
falls back to the database (which also covers Org notes).  The index
refreshes when files are added, removed or modified.

### Following and inserting links

- `M-x vulpea-md-new-note` (alias: `vulpea-markdown-new-note`) prompts for
  a title, creates a file with front matter (`id` and `title`) in
  `vulpea-markdown-directory` and opens it.  The directory defaults to a
  `markdown/` subdirectory of `vulpea-directory` (or `org-directory`) and
  is created if missing.  Override it with:

  ```elisp
  (setq vulpea-markdown-directory "~/notes/markdown")
  ```

- `M-x vulpea-md-insert` picks a note and inserts `[[title]]`.
- `M-x markdown-follow-wiki-link-at-point` (`M-.` in `markdown-mode`)
  follows `[[wiki links]]` to indexed Org or Markdown notes.
- Following an inline link to a `.md` file or `id:` goes to the indexed
  note as well.

### Backlinks and queries

Everything uses Vulpea's normal database, so no special API is needed:

```elisp
(vulpea-db-query-by-links-some (list (vulpea-note-id note)))
(vulpea-db-query-by-tags-some '("project"))
```

`vulpea-find-backlink`, `vulpea-select` and the rest of the Vulpea
ecosystem work with Markdown notes out of the box.  Citations are stored
in the `md-citations` table (columns `note-id`, `citekey`).

## Limitations

- One file-level note per file; headings are not indexed.
- The YAML reader understands the flat subset shown above (scalars, flow
  and block lists).  It is not a full YAML parser.
- Links inside fenced code blocks are currently indexed too.
- Notes without an `id` are not added to the database.

## Development / tests

The test suite needs Emacs with the dependencies available on
`load-path` (the runner auto-detects a local `straight` build tree):

```sh
make test
```

or directly:

```sh
emacs --batch -l test/run-tests.el
```

Byte-compile check:

```sh
make compile
```

## License

GPL-3.0-or-later, same as md-roam and Vulpea.  See [LICENSE](LICENSE).
