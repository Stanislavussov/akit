# Pi extension types, 1.0.4 (minimum Pi)

`index.d.ts` is an excerpt of `dist/core/extensions/types.d.ts` from
`@earendil-works/pi-coding-agent` **1.0.4** (npm; the copy installed on the author's Mac),
licence MIT (Copyright (c) Mario Zechner and contributors).

Only the members the Flows runner (`AKitCore/Sources/AKitRender/Resources/flows/*.ts`) uses
are kept, copied as they are. Left out: members that need types from other Pi packages
(`pi-tui`, `pi-ai`, `typebox`), and `sourceInfo` of `RegisteredCommand` (the API omits it in
`registerCommand` anyway). `make test-flows` type-checks the runner against this file, so a
call to an API the minimum Pi lacks fails the build. When `minPi` rises, replace this folder
with the new version's excerpt (flows.md F20).
