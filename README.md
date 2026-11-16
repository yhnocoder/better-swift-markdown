# better-swift-markdown

Markdown and code, read, drawn and edited natively on the Mac. No web view: text is laid out with Core Text, drawn
into layers and edited through AppKit's text input (input methods included). It renders and edits the same Markdown
the web editor [@yhnocoder/markdown](https://www.npmjs.com/package/@yhnocoder/markdown) does, with the same rules and
the same look (sizes, spacing and colours; not pixel for pixel), so one document can be shown in a browser and in a
Mac app.

macOS 27 or later, Swift 6.

## Products

| Product | Imports | What it is |
|---|---|---|
| `CodeCore` | Foundation | Code editing without a view: the text, the selection, keys as commands, undo, find and replace, line comments, and `LineAnchors` (where a line went after an edit, for anything pinned to lines). |
| `CodeUI` | AppKit, CodeCore | Code laid out and drawn (`CodeLines`, `CodeDraw`), and `CodeEditorView`: line numbers, current line, selection, wrapping by width, tab stops, bands behind lines, room after lines for the host's own content, a find bar. Colours come from a `CodeHighlighter`. |
| `TreeSitterHighlight` | CodeUI, tree-sitter | A `CodeHighlighter` on tree-sitter: Python, Rust, C, C++ and CUDA built in, any other grammar registered by the host; incremental parsing while text is edited (`HighlightSession`). |
| `MarkdownCore` | Foundation, CodeCore | Markdown as a document: block and inline lexing (marked's rules, JavaScript regex semantics), the source operations of the editor (blocks moved, lists indented, tables edited, paste shaped), all on the source text. |
| `MarkdownUI` | AppKit, MarkdownCore, CodeUI | Markdown drawn and edited: `BlockLayout` (a document laid out at a width in a `MarkdownTheme`), drawing at any scale, and `MarkdownEditorView` (caret, selection, menus, find, tables, images, formulas, diagrams). |
| `TestGuard` | AppKit | What a test process may not show or touch (menus, alerts, panels, the browser, Finder, the general pasteboard), replaced in a test process only. The editor puts it in; a host whose own tests make windows can too. |

`CodeCore` and `MarkdownCore` have no UI and can run anywhere Foundation does.

## Code

```swift
import CodeUI
import TreeSitterHighlight

let highlighter = Highlighter()            // make one and share it
let text = "def f(x):\n    return x + 1\n"
let view = CodeEditorView(text: text, look: myLook)   // CodeEditorView.Look: fonts, colours, metrics
view.colors = CodeColors(TreeSitterColors(HighlightSession(highlighter), language: "python"), text: text)
view.onHeight = { h in /* the view does not scroll: size it */ }
view.onChange = { text in /* save */ }
```

Another grammar, with a highlight query that uses the capture names `kw`, `op`, `fn`, `str`, `com`, `num`, `self`,
`p` and `plain`:

```swift
let highlighter = Highlighter(grammars: [
  Grammar(names: ["go"], language: tree_sitter_go(), highlights: goQuery)
])
```

## Markdown

```swift
import MarkdownCore
import MarkdownUI

let doc = MarkdownDocument(text)
let layout = BlockLayout(doc, width: 360, theme: theme, layout: nil, resources: myResources)
let editor = MarkdownEditorView(layout: layout)
editor.delegate = self   // MarkdownEditorDelegate: the text as edited, size changes, leaving
```

`BlockLayout` can also be drawn without an editor, into any `CGContext`, at any scale.

## What the host gives

- **`MarkdownResources`**: image sizes (read before layout, never waited on), what a `[[reference]]` points at,
  code colours (`highlight(lines:language:)`, for which `TreeSitterHighlight` is one answer), the math preamble, and
  the optional formula (`MathTypesetter`) and diagram (`DiagramRenderer`) engines. The engines bundled in `MarkdownUI`
  (`MarkdownAssets.engines()`) run MathJax and Mermaid in JavaScriptCore; a host that leaves them out gets formulas and
  diagrams as their source.
- **`MarkdownTheme`**: colours, fonts, sizes and spacing, one value per CSS variable of the web editor's stylesheet.
  `MarkdownTheme.sample(dark:)` is a look to start from.
- **Fonts**: the font families a theme names come from the system, or from the host's own files: set
  `MarkdownAssets.fontFolder` and `MarkdownAssets.fontFiles` before the first layout, and each family is registered
  the first time it is drawn with.
- **What the slash menu calls a reference** (`MarkdownEditing.referenceTitle`) and the pasteboard type the editor
  copies Markdown source under (`MarkdownEditorView.sourceType`), when not the defaults.
- **`CodeHighlighter`**: colours of the lines asked for, off the main thread.
- **`CodeEditorView.Look`** and **`FindBar.Look`**: how code and the find bar look.
- A pasteboard, when not the general one (tests give their own).

An app made of a build's binaries carries `better-swift-markdown_MarkdownUI.bundle` (the engines) in its
`Contents/Resources`, as Xcode puts it; `MarkdownAssets` finds it there or beside the binary, and reports it missing
(`MarkdownAssetError`) rather than stopping.

## Try it

`swift run MarkdownEditorDemo [file.md]` opens a Markdown file in a window, to read and edit in the component's
sample look (`MarkdownTheme.sample`), light or dark as the system is. `swift run -c release MarkdownBench --notes`
times forty made-up Notes laid out and drawn (`--editor`: a key in a long Note; `--first`: from a cold process).

## Tests

`swift test`. The UI tests open their windows under the desktop picture, never in front of anyone, and never touch
the general pasteboard. `PackageBoundaryTests` keeps each target to the imports in the table above.

## Licence

MIT. The bundled engines (MathJax, pele and what they bundle) keep their own licences, listed with their texts in
`Sources/MarkdownUI/Assets/THIRD-PARTY-NOTICES.txt`; `tools/engines` builds them again. The fonts the tests draw with
are under the SIL Open Font License, its texts beside them in `Tests/MarkdownUITests/Fonts`. The Python grammar's
scanner in `Sources/CTreeSitterScanners/python` keeps its MIT licence beside it.
