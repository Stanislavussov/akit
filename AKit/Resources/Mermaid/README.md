# mermaid 11.17.2

`mermaid.min.js` from the npm package `mermaid@11.17.2` (`dist/mermaid.min.js`), MIT (`LICENSE`).
sha256 581ed7d74bd9048d0e3a91363927d72ef22942d7722546b27f7cc29e35390eb8.
The Review screen draws a run's flow with it (`AKit/Review/MermaidView.swift`), offline.

Updated from 11.4.1 on 2026-10-24 for CVE-2025-54881 (a sequence diagram's KaTeX labels went to
`innerHTML` unsanitized; fixed in 11.10). The flow is written by a model that reads untrusted
merge request text, so the bundled copy should stay on a release without known XSS fixes.
