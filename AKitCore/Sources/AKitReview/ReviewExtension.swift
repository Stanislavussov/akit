import Foundation

/// The Pi extension of a review pass, `<run>/akit-review.ts` (`docs/design/review.md`, "The agent
/// in a pass"). It is thin: the tools that write into the run folder, and a `tool_call` policy.
/// AKit passes it, per pass: `AKIT_REVIEW_RUN` (the run folder), `AKIT_REVIEW_MODE` (`fetch`,
/// `review` or `send`), `AKIT_REVIEW_PASS`, `AKIT_REVIEW_ROLE`, `AKIT_REVIEW_MAX`,
/// `AKIT_REVIEW_ROOTS` (folders reads may reach, `:`-separated), `AKIT_REVIEW_MCP` (the run's
/// `ReviewMCPAccess` as JSON), `AKIT_REVIEW_RUN_ID`, `AKIT_REVIEW_SCENARIO`, `AKIT_REVIEW_HEAD`,
/// `AKIT_REVIEW_LINKS` (the run's links as JSON); with a knowledge base (v8+, K18) also
/// `AKIT_REVIEW_AKIT` (an absolute akit) and `AKIT_REVIEW_KB_BASE`, and then the review passes
/// get `akit_kb_search` / `akit_kb_show`. Without them the tools are exactly those of the version before the knowledge tools (v12).
///
/// Context servers (`extraServers`) are allowed like the run's own servers but only read: their
/// tools never write, and the send pass doesn't get them at all. Every saved answer names its
/// server; every blocked call goes to `<run>/mcp/blocked.jsonl`. In the fetch pass `akit_reading_link` names the link the next
/// calls read; their saved answers carry it, and calls blocked meanwhile go to
/// `<run>/mcp/blocked.jsonl`, so AKit can say per link what was read and what wasn't.
///
/// MCP calls (R2–R3): every call of a Pi MCP tool, direct or from a codemode script, passes the
/// policy of `ReviewMCPPolicy`. Reading tools of the run's servers are allowed; a writing tool
/// only in `send` mode and only with the text of a request the user approved
/// (`<run>/send/approved.json`); publishing, approving, merging and resolving never. Every answer
/// is saved word for word in `<run>/mcp/calls/`, and every write in `<run>/send/log.jsonl`:
/// AKit reads those, not the model's account.
public enum ReviewExtension {
    /// Bumped when the text changes; written into the file's first line.
    public static let version = 14

    /// Folder names and file names a pass may never read (R15). Gather also deletes such
    /// files from the run's worktree, since `grep` and `find` look into folders.
    public static func isBlocked(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        let lower = name.lowercased()
        return lower.hasPrefix(".env") || parts.dropLast().contains("secrets") || lower.hasPrefix("id_")
            || [".pem", ".key", ".p12", ".pfx", ".jks", ".keystore"].contains { lower.hasSuffix($0) }
            || ["auth.json", "settings.local.json", ".npmrc", ".netrc", ".pypirc", ".git-credentials"].contains(lower)
    }

    /// The extension's pure rules, in plain JavaScript inside the TypeScript file, so AKit's tests
    /// run this same text with JavaScriptCore: the argument limit of open servers and of the
    /// impact pass, the shape of a submitted use and of the brief's overview.
    public static let rules = #"""
    const openArgumentLimit = 300;
    // The whole arguments of a call where the limit applies, as JSON.
    const openInputLimit = 600;

    // Where the limit applies: every server in the impact pass (it searches other projects), and an
    // open server (reached only through every-server reading) in any pass.
    function limitApplies(passName, base, extra) {
      return passName === "impact" || (!base && !extra);
    }

    // No line break and no long text in a call's arguments (keys too), nothing nested deeper than
    // AKit looks, and not much in all, so code of the change can't leave through a search box.
    function tooMuchFor(input) {
      let whole;
      try { whole = JSON.stringify(input === undefined ? null : input); } catch (e) { return true; }
      if (typeof whole !== "string" || whole.length > openInputLimit) return true;
      const texts = [];
      let deep = false;
      const walk = (value, depth) => {
        if (depth > 4) { deep = true; return; }
        if (typeof value === "string") texts.push(value);
        else if (Array.isArray(value)) value.forEach((v) => walk(v, depth + 1));
        else if (value !== null && typeof value === "object") {
          Object.entries(value).forEach(([key, v]) => { texts.push(key); walk(v, depth + 1); });
        }
      };
      walk(input, 0);
      return deep || texts.some((t) => t.length > openArgumentLimit || /[\r\n]/.test(t));
    }

    // A use of a boundary in another repository (the impact pass). AKit checks each against the
    // saved GitLab answers; this only checks the shape.
    function consumerProblems(list) {
      const out = [];
      list.forEach((c, i) => {
        const at = `consumers[${i}]`;
        if (typeof c !== "object" || c === null) { out.push(`${at} is not an object`); return; }
        if (typeof c.boundary !== "string" || c.boundary.trim() === "") out.push(`${at}.boundary names the boundary (its id, such as b1, or its name)`);
        if (typeof c.project !== "string" || c.project.trim() === "") out.push(`${at}.project is the other project's path in GitLab`);
        if (typeof c.file !== "string" || c.file.trim() === "") out.push(`${at}.file is missing`);
        if (c.ref !== undefined && c.ref !== null && typeof c.ref !== "string") out.push(`${at}.ref must be a branch or commit`);
        if (c.line !== undefined && c.line !== null && (!Number.isInteger(c.line) || c.line < 1)) out.push(`${at}.line must be a line number from 1`);
        if (typeof c.quote !== "string" || c.quote.trim() === "") out.push(`${at}.quote must copy the line from GitLab's answer`);
        if (typeof c.usage !== "string" || c.usage.trim() === "") out.push(`${at}.usage says how the file uses the boundary`);
        if (c.breaks !== undefined && typeof c.breaks !== "boolean") out.push(`${at}.breaks must be true or false`);
        if (c.why !== undefined && typeof c.why !== "string") out.push(`${at}.why must be text`);
        if (c.breaks === true && (typeof c.why !== "string" || c.why.trim() === "")) out.push(`${at}.why says how this change breaks it`);
      });
      return out;
    }

    // The brief's overview for the user (R45, R47): types and sizes. AKit checks the files and the flow.
    const overviewSources = ["work-item", "description", "notes", "none"];
    function overviewProblems(params) {
      const out = [];
      const p = params !== null && typeof params === "object" && !Array.isArray(params) ? params : {};
      const given = (key) => (p[key] === undefined || p[key] === null ? [] : p[key]);
      const points = given("points");
      if (!Array.isArray(points)) out.push("points must be a list");
      else {
        if (points.length > 8) out.push("at most 8 points (AKit keeps 3–5)");
        points.forEach((t, i) => {
          if (typeof t !== "string" || t.trim() === "" || t.length > 400) out.push(`points[${i}] must be text of 1–400 characters`);
        });
      }
      const modules = given("modules");
      if (!Array.isArray(modules)) out.push("modules must be a list");
      else {
        if (modules.length > 20) out.push("at most 20 modules");
        modules.forEach((m, i) => {
          const at = `modules[${i}]`;
          if (typeof m !== "object" || m === null || Array.isArray(m)) { out.push(`${at} is not an object`); return; }
          if (typeof m.name !== "string" || m.name.trim() === "" || m.name.length > 120) out.push(`${at}.name must be 1–120 characters`);
          if (!Array.isArray(m.files) || m.files.length === 0) out.push(`${at}.files must list the module's changed files`);
          else {
            if (m.files.length > 50) out.push(`${at}.files: at most 50`);
            if (m.files.some((f) => typeof f !== "string" || f.trim() === "")) out.push(`${at}.files must hold file paths`);
          }
          if (m.why !== undefined && m.why !== null && (typeof m.why !== "string" || m.why.length > 400)) out.push(`${at}.why must be text of at most 400 characters`);
        });
      }
      const sources = given("why_sources");
      if (!Array.isArray(sources)) out.push("why_sources must be a list");
      else sources.forEach((s, i) => {
        if (!overviewSources.includes(s)) out.push(`why_sources[${i}] must be one of ${overviewSources.join(", ")}`);
      });
      if (p.flow !== undefined && p.flow !== null) {
        if (typeof p.flow !== "string") out.push("flow must be Mermaid text");
        else if (p.flow.length > 6000) out.push("flow must have at most 6000 characters");
      }
      if (p.flow_kind !== undefined && p.flow_kind !== null && p.flow_kind !== "flowchart" && p.flow_kind !== "sequenceDiagram") {
        out.push("flow_kind must be flowchart or sequenceDiagram");
      }
      return out;
    }
    """#

    public static let source = #"""
    // akit-review.ts v14: written by AKit for one review run. Do not edit: AKit writes it again.
    import { execFile } from "node:child_process";
    import * as fs from "node:fs";
    import * as path from "node:path";

    const run = process.env.AKIT_REVIEW_RUN ?? "";
    const mode = process.env.AKIT_REVIEW_MODE ?? "review";
    const pass = process.env.AKIT_REVIEW_PASS ?? "pass";
    const role = process.env.AKIT_REVIEW_ROLE ?? "";
    const max = Number(process.env.AKIT_REVIEW_MAX ?? "20");
    const roots = (process.env.AKIT_REVIEW_ROOTS ?? "").split(":").filter((r) => r.length > 0).map((r) => real(r));
    const access = parse(process.env.AKIT_REVIEW_MCP ?? "{}") ?? {};
    const servers: string[] = (access.servers ?? []).map(norm);
    // Context servers: read only in the fetch pass and the review passes; never in the send pass.
    const extras: string[] = mode === "send" ? [] : (access.extraServers ?? []).map(norm);
    const links: string[] = parse(process.env.AKIT_REVIEW_LINKS ?? "[]") ?? [];
    let currentLink: string | null = null;
    const readPatterns: string[] = access.read ?? [];
    const writePatterns: string[] = access.write ?? [];
    const mcpAllowed = mode !== "review" || access.inPasses !== false;
    // The review passes may read through every server of the user's Pi but the risky ones
    // (a browser, a file system, a web fetcher), which only a profile or a run names.
    const everyServer = mode === "review" && access.allServers === true;
    const riskyWords = ["browser", "playwright", "puppeteer", "selenium", "chrome", "chromium", "firefox", "safari", "file", "files",
      "filesystem", "fs", "fetch", "http", "web", "curl", "shell", "terminal", "exec", "command", "desktop", "computer",
      "vault", "secret", "secrets", "keychain", "password", "passwords", "sql", "db", "database", "postgres", "postgresql", "mysql",
      "sqlite", "mongo", "mongodb", "redis", "kubernetes", "k8s", "kubectl", "aws", "gcloud", "ssh"];
    const riskyParts = ["fetch", "web", "crawl", "browser", "puppeteer", "playwright", "firecrawl", "tavily", "exa", "jina", "brightdata",
      "filesystem", "1password", "bitwarden", "lastpass", "keepass", "postgres", "mysql", "sqlite", "mongo", "clickhouse", "snowflake",
      "bigquery"];
    const actingWords = ["create", "add", "post", "new", "update", "edit", "modify", "put", "patch", "delete", "remove", "destroy",
      "execute", "exec", "run", "send", "merge", "trigger", "cancel", "close", "archive", "set", "complete", "order", "invite", "share",
      "upload", "sql", "query", "insert", "drop", "move", "rename", "start", "stop", "deploy", "pay", "buy", "checkout", "submit", "reply",
      "comment"];
    \#(rules)
    const severities = ["nit", "low", "medium", "high", "critical"];
    const verdicts = ["confirmed", "rejected", "question", "merged"];
    const kinds = ["finding", "ac", "question"];
    const boundaryKinds = ["http-api", "graphql", "mfe", "shared-lib", "event", "db-schema", "infra", "ci", "config"];
    const readTools = ["read", "grep", "find", "ls"];
    const ownTools = ["akit_submit_findings", "akit_submit_boundaries", "akit_submit_overview", "akit_submit_consumers", "akit_report_context_gap", "akit_submit_context", "akit_approved_requests", "akit_reading_link",
      "akit_kb_search", "akit_kb_show"];
    // The team's knowledge base (K18): only when AKit names its own akit and the base.
    const akit = process.env.AKIT_REVIEW_AKIT ?? "";
    const kbBase = process.env.AKIT_REVIEW_KB_BASE ?? "";
    const kbTools = ["akit_kb_search", "akit_kb_show"];
    const kbOn = mode === "review" && akit.startsWith("/") && kbBase.startsWith("/");
    const kbTimeout = 20000;
    const kbOutputCap = 65536;
    const kbMaxTokens = 4000;
    const kbArgumentLimit = 300;
    const resourceTools = ["list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource"];
    const forbiddenWords = ["publish", "submit", "approve", "unapprove", "vote", "resolve", "unresolve", "rebase"];
    const readVerbs = ["get", "list", "search", "read", "show", "view", "fetch", "find", "query", "describe", "download"];
    const writeVerbs = ["create", "add", "post", "new", "update", "edit", "modify", "put", "patch", "delete", "remove", "destroy"];
    const knownReads = ["mr_discussions", "wit_work_item", "wit_query", "wit_work_item_attachment", "repo_pull_request",
      "repo_pull_request_thread", "repo_file", "repo_repository", "repo_branch", "wiki"];
    const knownExactReads = ["resolve-library-id", "resolve_library_id", "query-docs", "query_docs", "get-library-docs", "get_library_docs"];
    const defaultServerWords = ["gitlab", "azure", "devops"];
    const approved: any[] = mode === "send" ? (parse(readText(path.join(run, "send/approved.json"))) ?? []) : [];
    const claimed = new Set<string>();
    const pending = new Map<string, string>();
    let saved = 0;

    function parse(text: string): any {
      try { return JSON.parse(text); } catch { return undefined; }
    }

    function readText(file: string): string {
      try { return fs.readFileSync(file, "utf8"); } catch { return ""; }
    }

    function real(p: string): string {
      try { return fs.realpathSync(p); } catch { return path.resolve(p); }
    }

    function norm(name: string): string {
      return String(name).replace(/[^A-Za-z0-9_]/g, "_");
    }

    function like(pattern: string, name: string): boolean {
      const parts = pattern.toLowerCase().split("*").map((p) => p.replace(/[.+?^${}()|[\]\\]/g, "\\$&"));
      return new RegExp("^" + parts.join(".*") + "$").test(name.toLowerCase());
    }

    // The same rules as ReviewMCPAccess.isBase, isExtra and allows in AKit.
    function serverBase(server: string): boolean {
      const name = norm(server).toLowerCase();
      if (servers.length > 0) return servers.map((s) => s.toLowerCase()).includes(name);
      return defaultServerWords.some((w) => name.includes(w)) || name === "ado";
    }

    function serverExtra(server: string): boolean {
      return !serverBase(server) && extras.map((s) => s.toLowerCase()).includes(norm(server).toLowerCase());
    }

    // The same rules as ReviewMCPAccess.isRisky in AKit.
    function risky(server: string): boolean {
      const lower = String(server).toLowerCase();
      const words = lower.split(/[^a-z]+/).filter((w) => w.length > 0);
      return words.some((w) => riskyWords.includes(w)) || riskyParts.some((p) => lower.includes(p));
    }

    function serverAllowed(server: string): boolean {
      return serverBase(server) || serverExtra(server) || (everyServer && !risky(server));
    }

    // mcp__<server>__<tool>: the server is one the run allows, the longest that fits, so a
    // server named like another plus `__…` is never taken for it.
    function split(name: string): { server: string; tool: string } | null {
      const match = /^mcp__(.+)$/.exec(name);
      if (!match) return null;
      const rest = match[1];
      const named = [...servers, ...extras].filter((s) => rest.startsWith(s + "__")).sort((a, b) => b.length - a.length)[0];
      if (named !== undefined) return { server: named, tool: rest.slice(named.length + 2) };
      const at = rest.indexOf("__");
      return at < 0 ? { server: rest, tool: "" } : { server: rest.slice(0, at), tool: rest.slice(at + 2) };
    }

    // Everything after `mcp__`: a server named `docs--fetch` must not pass as `docs`.
    function match_rest(name: string): string {
      return name.replace(/^mcp__/, "");
    }

    function lead(tool: string): string[] {
      return tool.toLowerCase().split(/[^a-z]+/).filter((w) => w.length > 0).slice(0, 2);
    }

    // The same rules as ReviewMCPPolicy.kind in AKit. null: not an MCP tool.
    function mcpKind(name: string, hints: any): "read" | "write" | "blocked" | null {
      const parts = split(name);
      if (parts === null) return null;
      const { server, tool } = parts;
      if (!serverAllowed(server)) return "blocked";
      if (knownExactReads.includes(tool.toLowerCase())) return "read";
      const words = tool.toLowerCase().split(/[^a-z]+/).filter((w) => w.length > 0);
      if (words.some((w) => forbiddenWords.includes(w))) return "blocked";
      // An open server (reached only through every-server reading): only a tool its server marks
      // read-only, or one named like a plain read with no word that acts anywhere in the name.
      if (!serverBase(server) && !serverExtra(server)) {
        if (risky(match_rest(name))) return "blocked";
        if (hints?.readOnlyHint === true) return "read";
        if (words.some((w) => actingWords.includes(w)) || tool.includes("__")) return "blocked";
        return readVerbs.includes(words[0] ?? "") ? "read" : "blocked";
      }
      const verbs = lead(tool);
      if (verbs.some((w) => writeVerbs.includes(w))) return serverBase(server) && writePatterns.some((p) => like(p, tool)) ? "write" : "blocked";
      if (readVerbs.includes(verbs[0] ?? "") || (verbs.length === 2 && readVerbs.includes(verbs[1]))) return "read";
      if (hints?.readOnlyHint === true || [...readPatterns, ...knownReads].some((p) => like(p, tool))) return "read";
      return "blocked";
    }

    function verb(name: string): string | null {
      const verbs = lead(split(name)?.tool ?? "");
      if (verbs.some((w) => ["delete", "remove", "destroy"].includes(w))) return "delete";
      if (verbs.some((w) => ["update", "edit", "modify", "put", "patch"].includes(w))) return "update";
      if (verbs.some((w) => ["create", "add", "post", "new"].includes(w))) return "create";
      return null;
    }

    // The arguments a write may have, by meaning: anything else (resolve_discussion, another
    // field with the text, …) blocks the call.
    const fields: Record<string, string[]> = {
      project: ["project_id", "projectId", "project", "project_path", "projectPath"],
      iid: ["merge_request_iid", "mergeRequestIid", "iid", "mr_iid"],
      body: ["body", "note"],
      draft: ["draft_note_id", "draftNoteId", "draft_id", "note_id"],
      discussion: ["in_reply_to_discussion_id", "discussion_id", "discussionId"],
      position: ["position"],
    };
    const positionFields = ["position_type", "base_sha", "start_sha", "head_sha", "old_path", "new_path", "old_line", "new_line"];

    function given(input: any, field: string): any[] {
      return fields[field].filter((k) => input[k] !== undefined && input[k] !== null).map((k) => input[k]);
    }

    function same(a: any, b: any): boolean {
      return a !== undefined && a !== null && b !== undefined && b !== null && String(a).trim() === String(b).trim();
    }

    // Why a write's arguments are not exactly this approved request; null when they are.
    function mismatch(request: any, name: string, input: any): string | null {
      if (request.action !== verb(name)) return "another action";
      if (input === null || typeof input !== "object" || Array.isArray(input)) return "no arguments";
      const known = Object.values(fields).flat();
      for (const [key, value] of Object.entries(input)) {
        if (value !== undefined && value !== null && !known.includes(key)) return `the argument ${key}`;
      }
      const projects = given(input, "project");
      if (projects.length === 0 || !projects.every((p) => (request.mr?.projects ?? []).some((q: any) => same(p, q)))) return "another project";
      const iids = given(input, "iid");
      if (iids.length === 0 || !iids.every((i) => same(i, request.mr?.iid))) return "another merge request";
      const bodies = given(input, "body");
      if (request.action === "delete" ? bodies.length > 0 : (bodies.length === 0 || !bodies.every((b) => same(b, request.body)))) return "another text";
      const drafts = given(input, "draft");
      if (request.draft_id != null ? (drafts.length === 0 || !drafts.every((d) => same(d, request.draft_id))) : drafts.length > 0) return "another draft";
      const threads = given(input, "discussion");
      if (request.discussion_id ? (threads.length === 0 || !threads.every((d) => same(d, request.discussion_id))) : threads.length > 0) return "another thread";
      const positions = given(input, "position");
      if (request.position && request.action !== "delete") {
        const p = positions[0];
        if (positions.length !== 1 || typeof p !== "object") return "no position";
        for (const key of Object.keys(p)) if (p[key] !== undefined && p[key] !== null && !positionFields.includes(key)) return `the position field ${key}`;
        for (const key of positionFields) {
          const want = request.position[key];
          const got = p[key];
          if ((want === undefined || want === null) !== (got === undefined || got === null)) return "another place in the diff";
          if (want !== undefined && want !== null && !same(want, got)) return "another place in the diff";
        }
      } else if (positions.length > 0) return "a position the request doesn't have";
      return null;
    }

    // The approved request a write call carries out exactly. null: none, so it is blocked.
    function approvedMatch(name: string, input: any): { request: any; why: string } {
      let why = "no approved request is waiting";
      for (const request of approved) {
        if (claimed.has(request.id)) continue;
        const wrong = mismatch(request, name, input);
        if (wrong === null) return { request, why: "" };
        // The reason of a request with the call's own action says what to fix.
        if (wrong !== "another action" || why === "no approved request is waiting") why = wrong;
      }
      return { request: null, why };
    }

    function blocked(p: string): boolean {
      const parts = p.split("/").filter((x) => x.length > 0);
      const name = (parts[parts.length - 1] ?? "").toLowerCase();
      return name.startsWith(".env") || parts.slice(0, -1).includes("secrets") || name.startsWith("id_")
        || [".pem", ".key", ".p12", ".pfx", ".jks", ".keystore"].some((s) => name.endsWith(s))
        || ["auth.json", "settings.local.json", ".npmrc", ".netrc", ".pypirc", ".git-credentials"].includes(name);
    }

    function inside(p: string): boolean {
      return roots.some((root) => p === root || p.startsWith(root + "/"));
    }

    function write(file: string, text: string) {
      const target = path.join(run, file);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, text);
    }

    function append(file: string, line: string) {
      const target = path.join(run, file);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.appendFileSync(target, line + "\n");
    }

    // Every saved answer names its server (the longest allowed name, as in split), so AKit takes
    // only the run's own servers' answers as the merge request's data.
    function serverOf(tool: string, input: any): string | null {
      if (tool.startsWith("mcp__")) return split(tool)?.server ?? null;
      if (kbTools.includes(tool)) return "akit-kb";
      if (resourceTools.includes(tool)) return norm(input?.server ?? "");
      return null;
    }

    function save(tool: string, input: any, text: string[], structured: any, isError: boolean) {
      saved += 1;
      const server = serverOf(tool, input);
      write(`mcp/calls/${pass}-${Date.now()}-${String(saved).padStart(4, "0")}.json`, JSON.stringify({ pass, tool,
        input: JSON.stringify(input ?? {}), text, structured: structured === undefined ? null : JSON.stringify(structured), isError,
        server, link: server !== null ? currentLink : null }));
    }

    // Every blocked call goes to mcp/blocked.jsonl: while the fetch pass reads a link, AKit says
    // why the link wasn't read.
    function refuse(name: string, reason: string): { block: true; reason: string } {
      append("mcp/blocked.jsonl", JSON.stringify({ link: currentLink, tool: name, pass, reason }));
      return { block: true, reason };
    }

    // A value akit gets as one argument: text, short, one line, never read as an option.
    function kbValue(value: any): string | null {
      if (typeof value !== "string") return null;
      const text = value.trim();
      return text.length > 0 && text.length <= kbArgumentLimit && !text.startsWith("-") && !/[\r\n\0]/.test(text) ? text : null;
    }

    // Runs akit with fixed arguments: no shell, a timeout, an output cap. akit scrubs its answer
    // (--scrub: the same masking as the context pack); the call is saved like an MCP answer.
    function kb(tool: string, args: string[], input: any): Promise<{ content: any[]; details: undefined; isError?: boolean }> {
      const argv = ["kb", ...args, "--json", "--scrub", "--max-tokens", String(kbMaxTokens), "--base", kbBase];
      return new Promise((resolve) => {
        execFile(akit, argv, { shell: false, timeout: kbTimeout, maxBuffer: kbOutputCap, encoding: "utf8",
          env: { PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: process.env.HOME ?? "", LANG: process.env.LANG ?? "en_US.UTF-8" } },
          (error: any, stdout: string) => {
            let text = String(stdout ?? "").slice(0, kbOutputCap);
            let isError = false;
            if (error) {
              isError = true;
              text = error.killed || error.signal ? "The knowledge base didn't answer in time; ask a narrower question."
                : error.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" ? "The answer was over 64 KB; ask a narrower question."
                : "The knowledge base couldn't answer: " + String(stdout || error.message || "").slice(0, 500);
            }
            save(tool, input, [text], undefined, isError);
            resolve({ content: [{ type: "text", text }], details: undefined, ...(isError ? { isError: true } : {}) });
          });
      });
    }

    function problems(findings: any[], verdictList: any[]): string[] {
      const out: string[] = [];
      if (findings.filter((f) => f?.kind !== "ac").length > max) out.push(`at most ${max} findings for this role; send the strongest ones`);
      findings.forEach((f, i) => {
        const at = `findings[${i}]`;
        if (typeof f !== "object" || f === null) { out.push(`${at} is not an object`); return; }
        if (typeof f.title !== "string" || f.title.trim() === "") out.push(`${at}.title is missing`);
        if (f.kind !== undefined && !kinds.includes(f.kind)) out.push(`${at}.kind must be one of ${kinds.join(", ")}`);
        if (f.file !== undefined && f.file !== null && typeof f.file !== "string") out.push(`${at}.file must be a path or null`);
        if (f.line !== undefined && f.line !== null && (!Number.isInteger(f.line) || f.line < 1)) out.push(`${at}.line must be a line number from 1`);
        if (f.side !== undefined && f.side !== "new" && f.side !== "old") out.push(`${at}.side must be new or old`);
        if (typeof f.evidence !== "string") out.push(`${at}.evidence must quote the code`);
        if (typeof f.why !== "string" || f.why.trim() === "") out.push(`${at}.why is missing`);
        if (!severities.includes(f.severity)) out.push(`${at}.severity must be one of ${severities.join(", ")}`);
        if (typeof f.confidence !== "number" || f.confidence < 0 || f.confidence > 1) out.push(`${at}.confidence must be 0–1`);
        if (f.preExisting !== undefined && typeof f.preExisting !== "boolean") out.push(`${at}.preExisting must be true or false`);
      });
      verdictList.forEach((v, i) => {
        const at = `verdicts[${i}]`;
        if (typeof v?.id !== "string") out.push(`${at}.id is missing`);
        if (!verdicts.includes(v?.verdict)) out.push(`${at}.verdict must be one of ${verdicts.join(", ")}`);
        if (typeof v?.note !== "string") out.push(`${at}.note is missing`);
        if (v?.verdict === "merged" && typeof v?.into !== "string") out.push(`${at}.into names the finding it merges into`);
        if (v?.preExisting !== undefined && typeof v?.preExisting !== "boolean") out.push(`${at}.preExisting must be true or false`);
      });
      return out;
    }

    // A key that is there must hold a list: a string or an object is a mistake, not an empty answer.
    function listOf(params: any, key: string): { list: any[]; wrong: string[] } {
      const value = params?.[key];
      if (value === undefined || value === null) return { list: [], wrong: [] };
      return Array.isArray(value) ? { list: value, wrong: [] } : { list: [], wrong: [`${key} must be a list`] };
    }

    function boundaryProblems(list: any[]): string[] {
      const out: string[] = [];
      if (list.length > 50) out.push("at most 50 boundaries; send the ones other repositories most likely use");
      list.forEach((b, i) => {
        const at = `boundaries[${i}]`;
        if (typeof b !== "object" || b === null) { out.push(`${at} is not an object`); return; }
        if (!boundaryKinds.includes(b.kind)) out.push(`${at}.kind must be one of ${boundaryKinds.join(", ")}`);
        if (b.direction !== "provides" && b.direction !== "uses") out.push(`${at}.direction must be provides or uses`);
        if (typeof b.name !== "string" || b.name.trim() === "" || b.name.length > 120) out.push(`${at}.name must be 1–120 characters`);
        if (typeof b.file !== "string" || b.file.trim() === "") out.push(`${at}.file is missing`);
        if (b.line !== undefined && b.line !== null && (!Number.isInteger(b.line) || b.line < 1)) out.push(`${at}.line must be a line number from 1`);
        if (typeof b.quote !== "string" || b.quote.trim() === "" || b.quote.length > 500) out.push(`${at}.quote must quote the code (at most 500 characters)`);
        if (b.side !== undefined && b.side !== "new" && b.side !== "old") out.push(`${at}.side must be new or old`);
        if (b.note !== undefined && (typeof b.note !== "string" || b.note.length > 300)) out.push(`${at}.note must be text of at most 300 characters`);
      });
      return out;
    }

    export default function (pi: any) {
      if (mode === "review") {
        pi.registerTool({
          name: "akit_submit_findings",
          label: "Submit findings",
          description: "Hand your findings (role passes) or verdicts (the verifier) to AKit. Call it once per pass; an empty list is a valid answer. "
            + "AKit checks every field and shows nothing to anyone before the user approves it.",
          parameters: {
            type: "object",
            properties: {
              findings: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    kind: { type: "string", enum: kinds },
                    file: { type: ["string", "null"], description: "Path in the repository" },
                    side: { type: "string", enum: ["new", "old"], description: "new: the line in the changed file; old: a removed line" },
                    line: { type: ["integer", "null"] },
                    title: { type: "string" },
                    evidence: { type: "string", description: "The exact code line(s) you rely on, copied from the file; never a secret's value" },
                    why: { type: "string" },
                    severity: { type: "string", enum: severities },
                    confidence: { type: "number", minimum: 0, maximum: 1 },
                    suggestion: { type: "string", description: "Replacement code for the anchored line, when there is a clear fix" },
                    related: { type: "array", items: { type: "string" } },
                    preExisting: { type: "boolean", description: "true: the problem is already there at the base commit; this change didn't bring it" },
                  },
                  required: ["title", "evidence", "why", "severity", "confidence"],
                },
              },
              verdicts: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    id: { type: "string" },
                    verdict: { type: "string", enum: verdicts },
                    note: { type: "string" },
                    into: { type: "string" },
                    severity: { type: "string", enum: severities },
                    confidence: { type: "number", minimum: 0, maximum: 1 },
                    preExisting: { type: "boolean", description: "true: the problem is already there at the base commit" },
                  },
                  required: ["id", "verdict", "note"],
                },
              },
            },
          },
          async execute(_id: string, params: any) {
            const given = listOf(params, "findings");
            const givenVerdicts = listOf(params, "verdicts");
            const findings = given.list;
            const verdictList = givenVerdicts.list;
            const wrong = [...given.wrong, ...givenVerdicts.wrong, ...problems(findings, verdictList)];
            if (wrong.length > 0) {
              return { content: [{ type: "text", text: "Not saved. Fix these and call again:\n- " + wrong.join("\n- ") }], details: undefined, isError: true };
            }
            const name = pass === "discuss" ? `passes/discuss-${Date.now()}.json` : `passes/${pass}.json`;
            write(name, JSON.stringify({ pass, role, findings, verdicts: verdictList }, null, 2));
            return { content: [{ type: "text", text: `Saved ${findings.length} findings and ${verdictList.length} verdicts.` }], details: undefined };
          },
        });
      }

      if (mode === "review") {
        pi.registerTool({
          name: "akit_submit_boundaries",
          label: "Submit boundaries",
          description: "Hand AKit what the change provides or uses across the repository's edge: an HTTP or GraphQL API, a micro-frontend "
            + "module, a published package, an event or queue, a database schema, infrastructure, a shared CI template, a config key. "
            + "Removed ones count too (side old). Call it once with at most 50; an empty list is a valid answer. AKit keeps a boundary only "
            + "when its quote is in the changed file or on the diff's removed lines, with its name near it.",
          parameters: {
            type: "object",
            properties: {
              boundaries: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    kind: { type: "string", enum: boundaryKinds },
                    direction: { type: "string", enum: ["provides", "uses"] },
                    name: { type: "string", maxLength: 120, description: "What to search for in other repositories: an endpoint path, a package, module, topic or variable name; it must be on the quoted line or near it" },
                    file: { type: "string", description: "The changed file in the repository" },
                    side: { type: "string", enum: ["new", "old"], description: "new: a line of the changed file; old: a removed line (a boundary the change removes, a deleted file)" },
                    line: { type: ["integer", "null"], description: "The line in the changed file, or in the old file for side old" },
                    quote: { type: "string", maxLength: 500, description: "The exact code line that declares or uses it, copied from the file or the removed line; never a secret's value" },
                    note: { type: "string", maxLength: 300, description: "One short sentence: what changes for its users" },
                  },
                  required: ["kind", "direction", "name", "file", "quote"],
                },
              },
            },
          },
          async execute(_id: string, params: any) {
            const { list, wrong: notList } = listOf(params, "boundaries");
            const wrong = [...notList, ...boundaryProblems(list)];
            if (wrong.length > 0) {
              return { content: [{ type: "text", text: "Not saved. Fix these and call again:\n- " + wrong.join("\n- ") }], details: undefined, isError: true };
            }
            write("passes/boundaries.json", JSON.stringify({ pass, boundaries: list }, null, 2));
            return { content: [{ type: "text", text: `Saved ${list.length} boundaries.` }], details: undefined };
          },
        });
      }

      if (mode === "review") {
        pi.registerTool({
          name: "akit_submit_overview",
          label: "Submit the overview",
          description: "Hand AKit a short overview of the change for the user (never posted): 3–5 points on what happens, the modules "
            + "that change with their files and why, where the why comes from, and a Mermaid flow of the path a request or data takes "
            + "where the change is. Call it once. AKit keeps only changed files and checks the flow.",
          parameters: {
            type: "object",
            properties: {
              points: { type: "array", maxItems: 8, items: { type: "string", maxLength: 400 }, description: "3–5 short points on what happens" },
              modules: {
                type: "array",
                maxItems: 20,
                items: {
                  type: "object",
                  properties: {
                    name: { type: "string", maxLength: 120 },
                    files: { type: "array", maxItems: 50, items: { type: "string" }, description: "Its changed files, as paths in the repository" },
                    why: { type: "string", maxLength: 400, description: "Why it changes" },
                  },
                  required: ["name", "files", "why"],
                },
              },
              why_sources: { type: "array", items: { type: "string", enum: overviewSources }, description: "Where the why comes from" },
              flow: { type: "string", maxLength: 6000, description: "A Mermaid flowchart or sequenceDiagram, at most 40 nodes; changed parts in class changed" },
              flow_kind: { type: "string", enum: ["flowchart", "sequenceDiagram"] },
            },
            required: ["points", "modules", "why_sources"],
          },
          async execute(_id: string, params: any) {
            const wrong = overviewProblems(params);
            if (wrong.length > 0) {
              return { content: [{ type: "text", text: "Not saved. Fix these and call again:\n- " + wrong.join("\n- ") }], details: undefined, isError: true };
            }
            const p = params ?? {};
            write("passes/overview.json", JSON.stringify({ pass, points: p.points ?? [], modules: p.modules ?? [], why_sources: p.why_sources ?? [],
              flow: p.flow ?? null, flow_kind: p.flow_kind ?? null }, null, 2));
            return { content: [{ type: "text", text: `Saved the overview (${(p.points ?? []).length} points, ${(p.modules ?? []).length} modules).` }], details: undefined };
          },
        });
      }

      if (mode === "review" && pass === "impact") {
        pi.registerTool({
          name: "akit_submit_consumers",
          label: "Submit uses in other repositories",
          description: "Hand AKit the uses of the change's boundaries you found in other GitLab projects, each once. You may call it "
            + "again with more; an empty list is a valid answer. AKit keeps a use only when its quote is in an answer GitLab gave you "
            + "in this pass.",
          parameters: {
            type: "object",
            properties: {
              consumers: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    boundary: { type: "string", description: "The boundary's id (b1, b2, …) or, for one you named yourself, its name" },
                    project: { type: "string", description: "The other project's path in GitLab (group/project)" },
                    file: { type: "string", description: "The file's path in that project" },
                    ref: { type: ["string", "null"], description: "The branch or commit you read it at" },
                    line: { type: ["integer", "null"] },
                    quote: { type: "string", description: "The exact line that uses the boundary, copied from GitLab's answer; never a secret's value" },
                    usage: { type: "string", description: "One short sentence: how the file uses the boundary" },
                    breaks: { type: "boolean", description: "true: this change breaks the use" },
                    why: { type: "string", description: "How this change breaks it (or why not)" },
                  },
                  required: ["boundary", "project", "file", "quote", "usage"],
                },
              },
            },
          },
          async execute(_id: string, params: any) {
            const { list, wrong: notList } = listOf(params, "consumers");
            const wrong = [...notList, ...consumerProblems(list)];
            if (wrong.length > 0) {
              return { content: [{ type: "text", text: "Not saved. Fix these and call again:\n- " + wrong.join("\n- ") }], details: undefined, isError: true };
            }
            const file = path.join(run, "passes/consumers.json");
            const earlier = parse(readText(file))?.consumers;
            const all = (Array.isArray(earlier) ? earlier : []).concat(list).slice(0, 200);
            write("passes/consumers.json", JSON.stringify({ pass, consumers: all }, null, 2));
            return { content: [{ type: "text", text: `Saved ${list.length} uses (${all.length} in all).` }], details: undefined };
          },
        });
      }

      if (mode === "fetch") {
        pi.registerTool({
          name: "akit_submit_context",
          label: "Submit context",
          description: "Only when an MCP tool answers in prose instead of JSON: hand AKit what it said, in GitLab's and Azure DevOps's "
            + "JSON field names. AKit already saves every JSON answer of your MCP tools itself.",
          parameters: {
            type: "object",
            properties: {
              merge_request: { type: "object" }, versions: { type: "array" }, diffs: { type: "array" }, discussions: { type: "array" },
              draft_notes: { type: "array" }, user: { type: "object" }, work_items: { type: "array" },
            },
          },
          async execute(_id: string, params: any) {
            save("akit_submit_context", {}, [], params ?? {}, false);
            return { content: [{ type: "text", text: "Saved." }], details: undefined };
          },
        });
      }

      if (mode === "fetch" && links.length > 0) {
        pi.registerTool({
          name: "akit_reading_link",
          label: "Reading a link",
          description: "Say which of the review's links your next MCP calls read, before you call them. Read one link at a time: "
            + "AKit files each answer under the link named last.",
          parameters: { type: "object", properties: { url: { type: "string", description: "The link exactly as AKit listed it" } }, required: ["url"] },
          async execute(_id: string, params: any) {
            const url = String(params?.url ?? "").trim();
            if (!links.includes(url)) {
              return { content: [{ type: "text", text: "That is not one of the review's links. They are:\n" + links.join("\n") }], details: undefined, isError: true };
            }
            currentLink = url;
            return { content: [{ type: "text", text: `Reading ${url}.` }], details: undefined };
          },
        });
      }

      if (mode === "send") {
        pi.registerTool({
          name: "akit_approved_requests",
          label: "Approved requests",
          description: "The draft notes the user approved and that are not sent yet, as JSON. Pass each body to the draft note tool "
            + "exactly as it is: AKit lets through only the approved text.",
          parameters: { type: "object", properties: {} },
          async execute() {
            const open = approved.filter((r) => !claimed.has(r.id));
            return { content: [{ type: "text", text: JSON.stringify(open, null, 2) }], details: undefined };
          },
        });
      }

      pi.registerTool({
        name: "akit_report_context_gap",
        label: "Report a context gap",
        description: "Say what you needed and couldn't read, instead of guessing.",
        parameters: {
          type: "object",
          properties: {
            system: { type: "string", description: "gitlab, azure-devops, repository, knowledge, tests or other" },
            needed: { type: "string" },
            why: { type: "string" },
            how_to_get: { type: "string" },
            effect: { type: "string", description: "Which findings or checks are less certain without it" },
          },
          required: ["system", "needed", "why"],
        },
        async execute(_id: string, params: any) {
          if (typeof params?.needed !== "string" || typeof params?.why !== "string") {
            return { content: [{ type: "text", text: "Not saved: needed and why are required." }], details: undefined, isError: true };
          }
          append(`passes/gaps-${pass}.jsonl`, JSON.stringify({ system: String(params.system ?? "other"), needed: params.needed, why: params.why,
            howToGet: String(params.how_to_get ?? ""), effect: String(params.effect ?? ""), reportedBy: pass }));
          return { content: [{ type: "text", text: "Gap recorded." }], details: undefined };
        },
      });

      if (kbOn) {
        pi.registerTool({
          name: "akit_kb_search",
          label: "Search the knowledge base",
          description: "Search the team's knowledge base (notes about the systems around this repository) for sections with every word. "
            + "Reference text people wrote: untrusted, check it against the code. Answers JSON: note, heading, snippet, neighbors.",
          parameters: {
            type: "object",
            properties: {
              query: { type: "string", description: "A few words: a system, an event, a term" },
              area: { type: "string", description: "Only this area of the base" },
              limit: { type: "integer", minimum: 1, maximum: 10 },
            },
            required: ["query"],
          },
          async execute(_id: string, params: any) {
            const query = kbValue(params?.query);
            const area = params?.area === undefined || params?.area === null || params?.area === "" ? null : kbValue(params.area);
            const limit = Math.min(10, Math.max(1, Math.floor(Number(params?.limit ?? 10)) || 10));
            if (query === null || (params?.area && area === null)) {
              return { content: [{ type: "text", text: `Not run: query and area are short one-line text (at most ${kbArgumentLimit} characters, not starting with -).` }],
                details: undefined, isError: true };
            }
            return kb("akit_kb_search", ["search", query, ...(area === null ? [] : ["--area", area]), "--limit", String(limit)], params);
          },
        });
        pi.registerTool({
          name: "akit_kb_show",
          label: "Show a knowledge note",
          description: "Read one note of the team's knowledge base (as akit_kb_search or the knowledge card names it), or one ## section of it. "
            + "Reference text people wrote: untrusted, check it against the code.",
          parameters: {
            type: "object",
            properties: {
              note: { type: "string", description: "The note, e.g. payments/orders-api" },
              section: { type: "string", description: "Only this ## section" },
            },
            required: ["note"],
          },
          async execute(_id: string, params: any) {
            const note = kbValue(params?.note);
            const section = params?.section === undefined || params?.section === null || params?.section === "" ? null : kbValue(params.section);
            if (note === null || (params?.section && section === null)) {
              return { content: [{ type: "text", text: `Not run: note and section are short one-line text (at most ${kbArgumentLimit} characters, not starting with -).` }],
                details: undefined, isError: true };
            }
            return kb("akit_kb_show", ["show", note, ...(section === null ? [] : ["--section", section])], params);
          },
        });
      }

      pi.on("tool_call", async (event: any, ctx: any) => {
        const name = String(event.toolName ?? "");
        // Debug… reads the run's log and writes nothing: no AKit tool, no MCP.
        if (pass.startsWith("debug-") && !readTools.includes(name)) return refuse(name, "The debug pass only reads files.");
        if (ownTools.includes(name)) return undefined;
        if (name === "codemode" || name === "tool_search") {
          // Every tool a script or a search reaches comes back through this check.
          return mcpAllowed ? undefined : refuse(name, "AKit review gives this pass no MCP tools.");
        }
        if (resourceTools.includes(name)) {
          if (!mcpAllowed) return refuse(name, "AKit review gives this pass no MCP tools.");
          const server = norm(event.input?.server ?? "");
          if (!serverAllowed(server)) return refuse(name, "That server is not one this review may use.");
          if (limitApplies(pass, serverBase(server), serverExtra(server)) && tooMuchFor(event.input)) {
            return refuse(name, `AKit review sends ${server} only short queries without line breaks (at most ${openArgumentLimit} `
              + "characters each): ask with names of libraries, APIs or pages, never with code or file contents.");
          }
          return undefined;
        }
        const hints = (pi.getAllTools?.() ?? []).find((tool: any) => tool.name === name)?.annotations;
        const kind = mcpKind(name, hints);
        if (kind !== null) {
          if (!mcpAllowed) return refuse(name, "AKit review gives this pass no MCP tools.");
          if (kind === "blocked") {
            return refuse(name, `AKit review doesn't let ${name} run: it isn't a reading tool of the project's servers, `
              + "and review never publishes, approves, merges or resolves.");
          }
          const parts = split(name);
          // The impact pass searches other projects: short queries to every server, GitLab too.
          if (parts !== null && limitApplies(pass, serverBase(parts.server), serverExtra(parts.server)) && tooMuchFor(event.input)) {
            return refuse(name, `AKit review sends ${parts.server} only short queries without line breaks (at most ${openArgumentLimit} `
              + "characters each): ask with names of libraries, APIs or pages, never with code or file contents.");
          }
          if (kind === "write") {
            if (mode !== "send") return refuse(name, "Only Send Drafts writes, and only what the user approved.");
            const { request, why } = approvedMatch(name, event.input);
            if (request === null) {
              return refuse(name, `This call carries none of the approved requests exactly (${why}). Pass the project, the `
                + "merge request number, and each request's body, draft_id, discussion_id and position from akit_approved_requests "
                + "unchanged, and no other argument.");
            }
            claimed.add(request.id);
            pending.set(String(event.toolCallId), request.id);
          }
          return undefined;
        }
        if (mode !== "review") return refuse(name, `${name}: this pass works only through MCP tools.`);
        if (!readTools.includes(name)) return refuse(name, `AKit review allows only reading tools; ${name} is not one.`);
        const given = typeof event.input?.path === "string" && event.input.path.length > 0 ? event.input.path : ".";
        // Pi expands a leading ~ and @ and reads file:// addresses itself: never let one through,
        // or the check below would see a different path than Pi reads.
        if (/^\s*(~|@|file:)/i.test(given)) return refuse(name, `AKit review takes plain paths only; ${given} is not one.`);
        const target = real(path.resolve(ctx?.cwd ?? process.cwd(), given));
        if (!inside(target)) return refuse(name, `AKit review reads only the worktree and the run's context pack; ${given} is outside.`);
        if (blocked(target)) return refuse(name, `${given} usually holds secrets; AKit review never reads it.`);
        for (const key of ["glob", "pattern"]) {
          const value = event.input?.[key];
          if (name !== "grep" || key === "glob") {
            if (typeof value === "string" && (blocked(value) || value.includes("..") || /^\s*(\/|~|@|file:)/i.test(value))) {
              return refuse(name, "That pattern leaves the folder or names files that usually hold secrets.");
            }
          }
        }
        return undefined;
      });

      pi.on("tool_result", async (event: any) => {
        const name = String(event.toolName ?? "");
        if (!name.startsWith("mcp__") && !resourceTools.includes(name)) return undefined;
        const text = (event.content ?? []).filter((c: any) => c?.type === "text").map((c: any) => String(c.text));
        save(name, event.input, text, event.structuredContent, Boolean(event.isError));
        const id = String(event.toolCallId);
        const request = pending.get(id);
        if (request !== undefined) {
          pending.delete(id);
          if (event.isError) claimed.delete(request);
          append("send/log.jsonl", JSON.stringify({ request, tool: name, isError: Boolean(event.isError), text: text.join("\n").slice(0, 4000) }));
        }
        return undefined;
      });

      pi.on("session_start", async () => {
        pi.appendEntry("akit-review", { run: process.env.AKIT_REVIEW_RUN_ID ?? "", pass, mode, scenario: process.env.AKIT_REVIEW_SCENARIO ?? "",
          head: process.env.AKIT_REVIEW_HEAD ?? "" });
      });
    }
    """#
}
