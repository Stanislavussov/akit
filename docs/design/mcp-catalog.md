# MCP catalog: add a server without looking up its config

Status: built 2026-10-04 (MCP Servers → Catalog…, module `AKitMCPCatalog`), with the fixes
of one code review (secrets in arguments, warnings, tolerant reading). Not built: see [Later](#later).

## Goal

Adding an MCP server meant finding its README, copying a command or URL and the names of
its variables by hand. The catalog does that part: search a public list, pick a server,
and the Add Server form is filled. The user still chooses where the server goes, types the
values, reads the diff and presses Apply. Nothing is written from the catalog itself.

```
MCP Servers → Catalog… → search → pick a server → pick a connection
      │                                              ├─ Remote (the public URL)
      │                                              └─ Local  (a package on this Mac)
      ▼
Fill the Form → change the URL or the values → Preview… → Apply   (existing MCP writer)
```

## Sources

Both answer in the MCP Registry format (`server.json` entries) and need no key, so one
reader covers them (`CatalogDecoder`).

| | Anthropic directory | MCP Registry |
|---|---|---|
| Address | `api.anthropic.com/mcp-registry/v0/servers` | `registry.modelcontextprotocol.io/v0/servers` |
| Size on 2026-10-04 | 327 servers, 4 pages, under 1 s | thousands; open to anyone |
| Reviewed | yes (Anthropic's connector directory) | no; only the namespace owner is checked |
| What it lists | remote servers, most with sign-in | remote servers and packages (npm, pypi, oci, …) |
| How AKit reads it | downloads the whole list, searches it locally | sends the search text, shows the matches |
| Speed | instant after the first download | 15–50 s per search (measured) |

The directory address is the one Claude's own documentation page reads; it is not a
documented public API and may change. If it fails, the registry search still works.

The registry's `search` matches server names only and returns matches in name order, with
no popularity numbers. AKit ranks the matches itself (`MCPCatalog.search`) and shows the
registry under its own heading with a warning on every entry.

## Decisions

- **Two lists, never merged into one.** A reviewed entry and an unreviewed one must not
  look the same. The same server can be in both (Context7 is): the directory has the
  remote URL, the registry also has the local package.
- **The catalog fills the form; it does not install.** The risk of an MCP server is higher
  than of a skill: it runs code on this Mac or receives data. So there is no one-click
  install, and Preview and Apply are the existing ones.
- **Secrets are never taken from the catalog and never prefilled.** A value is a secret when
  the entry says so or when its name looks like a credential (`MCPDraft.looksSecret`);
  it goes to the Keychain like any other MCP secret.
- **A secret never goes into Arguments or the URL.** What is typed there is written into
  the file as it is. An option that needs a secret there (an argument or URL part marked
  secret, or named like one: `--api-key`, `{token}`) is shown as not supported, with the
  reason. Secrets in environment variables and headers are supported.
- **What an entry adds is pointed out.** Arguments an entry brings for the runner
  (`npx --registry …`, `docker -v …`) change what runs, so the option carries a warning with
  the exact words. A value the catalog prefills is named in the option and in the form's
  notes ("Prefilled by the catalog: …"). A package name that reads as an option is dropped.
  A catalog value may fill one part of a URL only if it is a plain name (letters, digits,
  `.`, `_`, `-`), so it can't bring a host or a path of its own.
- **Packages are pinned to the listed version** (`npx -y pkg@1.2.3`, `uvx pkg==1.2.3`,
  `docker run … image:1.2.3`): what the user saw in Preview is what runs. Updating is a
  new pass through the catalog or an edit of the version. An entry without a version
  number (none, `latest`, a tag such as `next`) carries the warning "No version is pinned".
- **`{placeholders}` block Preview.** A URL part, an argument or a plain value that the
  entry leaves open (`https://{api_host}/mcp`, `--dir {folder}`) stays visible in the form,
  and Preview refuses until it is replaced (`CatalogDraft.problems`). This is checked only
  for forms filled from the catalog, so hand-written configs with braces keep working.
- **Optional values are off until ticked.** Required ones and URL parts are always in.
- **What AKit can't start is shown with the reason**, not hidden: `mcpb` and `nuget`
  packages, and packages that run their own HTTP server.
- **Saved copies**: `~/.akit/cache/mcp-catalog.json`, one day; the directory list and the
  last 40 registry searches. Safe to delete. An old directory list is still shown when
  the download fails, with the reason.

## What leaves the Mac

- Directory: a plain download of the whole list. The search text stays on the Mac.
- Registry: the search text goes to `registry.modelcontextprotocol.io`, 0.8 s after typing
  stops. On a work Mac this is the same kind of request as a skills.sh search.
- Nothing about the user's projects, harnesses or configured servers is sent.

## Code

| Piece | Where |
|---|---|
| Entry model (`CatalogServer`, `CatalogOption`, `CatalogParameter`) | `AKitMCPCatalog/CatalogServer.swift` |
| Reader of both catalogs, command building per package type | `AKitMCPCatalog/CatalogDecoder.swift` |
| Download, paging, registry search | `AKitMCPCatalog/MCPCatalogClient.swift` |
| Saved copies, local search and ranking | `AKitMCPCatalog/MCPCatalog.swift` |
| Option → Add Server form, notes, open placeholders | `AKitMCPCatalog/CatalogDraft.swift` |
| Catalog input of the Add Server sheet | `AKit/MCPCatalogPane.swift`, `AKit/MCPServerEditor.swift` |

Snapshot: `make snapshot SECTION=mcp TAB=catalog QUERY=context7 ADD=1`; with
`SELECT=io.github.upstash/context7 CAPTURE=1` the form is filled from that server.

## Later

- A mark on catalog entries that are already configured.
- Arguments as values with their own descriptions (today a required argument without a
  value is a `{placeholder}` in the Arguments line).
- A local copy of the whole registry, if it gets fast enough to download.
- A check for a newer version of a pinned package.
- Secret arguments through a `${VAR}` reference (works only with the env.sh secret mode today).
- `uvx --from` for packages whose program has another name than the package.
- Docker: keeping the `-e NAME` arguments in step with the Environment rows after the form
  is filled (today a note in the form says to do it by hand).
- Catalog entries in layers (waits for "MCP in layers", `layers.md`).
