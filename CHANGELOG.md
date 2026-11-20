# Changelog

## 1.0.0

- Initial port of md-roam to Vulpea v2.
- Parse Markdown front matter directly into `vulpea-parse-ctx`.
- Resolve wiki, alias, `id:` and relative-file links into Vulpea `id:`
  links, independent of indexing order.
- Store Pandoc-style citations in the `md-citations` table.
- Register Markdown extensions with Vulpea's sync scanner.
- Follow wiki links and inline note links to indexed Org/Markdown notes.
- `vulpea-markdown-directory` and `vulpea-md-new-note` for creating
  ready-to-index Markdown notes from a title.
- ERT test suite and batch test runner.
