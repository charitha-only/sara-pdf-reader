# Fixtures

Every file here was generated for this package. None is a third-party or
personal document — the suite must be safe to run, publish and share.

They are excluded from the published archive (`.pubignore`): consumers do not
need them, and they would add weight to every download.

| File | How it was made | What it exercises |
| --- | --- | --- |
| `sample.pdf` | Hand-written PDF objects | Two pages, native PDFium path |
| `sample.docx` | Hand-written OOXML | Headings, inline formatting, nested lists, merged and shaded table cells, embedded PNG, page break, theme colours with tint and shade |
| `sample.xlsx` | Hand-written OOXML | Six border styles, theme fills with tint, indexed palette, font variants, alignment and rotation, number formats, merges, frozen panes, hidden rows and columns |
| `edge-cases.pptx` | Hand-written OOXML | Theme colours, gradient fill, preset geometries, bullets inherited from the layout, auto-numbering, CJK and RTL text, table, image, multi-column and vertical text, grouped shapes |
| `sample.rtf` | `textutil -convert rtf` | A real writer's output: `\ucN` handling, backslash-newline paragraph marks, Turkish characters |
| `sample.doc` | `textutil -convert doc` | Word's piece table, mixed 8-bit and UTF-16 runs |
| `sample.xls` | `tool/build_legacy_fixtures.py` | BIFF8 records inside an OLE container, shared string table, Turkish characters |
| `sample.ppt` | `tool/build_legacy_fixtures.py` | PowerPoint 97 record tree; includes a slide master whose placeholder text must **not** appear in the output |
| `malformed/` | Generated | Empty file, truncated archive, valid zip that is not OOXML, OOXML skeleton with no main part, OLE container posing as `.docx`, zip bomb |

## Regenerating

The two legacy binary formats cannot be produced by anything on a stock macOS,
so they are written from their specifications:

```bash
python3 tool/build_legacy_fixtures.py
```

The OOXML fixtures were produced by hand-written builders during development;
their generators are not kept in this repository, so treat the committed files
as the source of truth. If one needs to change, prefer adding a new fixture
over editing an existing one — several tests assert against exact content.
