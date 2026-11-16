# engines

`engines.ts` is the formula and diagram engine the Markdown component runs in JavaScriptCore: MathJax turns TeX into
SVG, pele turns Mermaid into SVG, and the component draws that SVG itself. `npm install && npm run build` writes
`Sources/MarkdownUI/Assets/engines.js` and the licences of what it bundles (`THIRD-PARTY-NOTICES.txt`).
