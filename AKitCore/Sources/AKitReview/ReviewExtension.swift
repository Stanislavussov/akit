import Foundation

/// The Pi extension of a review pass, `<run>/akit-review.ts` (`docs/design/review.md`, "The agent
/// in a pass"). It is thin: the tools that write into the run folder, and a `tool_call` policy.
/// AKit passes it, per pass: `AKIT_REVIEW_RUN` (the run folder), `AKIT_REVIEW_MODE` (`fetch`,
/// `review` or `send`), `AKIT_REVIEW_PASS`, `AKIT_REVIEW_ROLE`, `AKIT_REVIEW_MAX`,
/// `AKIT_REVIEW_ROOTS` (folders reads may reach, `:`-separated), `AKIT_REVIEW_MCP` (the run's
/// `ReviewMCPAccess` as JSON), `AKIT_REVIEW_RUN_ID`, `AKIT_REVIEW_SCENARIO`, `AKIT_REVIEW_HEAD`.
///
/// MCP calls (R2–R3): every call of a Pi MCP tool, direct or from a codemode script, passes the
/// policy of `ReviewMCPPolicy`. Reading tools of the run's servers are allowed; a writing tool
/// only in `send` mode and only with the text of a request the user approved
/// (`<run>/send/approved.json`); publishing, approving, merging and resolving never. Every answer
/// is saved word for word in `<run>/mcp/calls/`, and every write in `<run>/send/log.jsonl`:
/// AKit reads those, not the model's account.
public enum ReviewExtension {
    /// Bumped when the text changes; written into the file's first line.
    public static let version = 3

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

    public static let source = #"""
    // akit-review.ts v3: written by AKit for one review run. Do not edit: AKit writes it again.
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
    const readPatterns: string[] = access.read ?? [];
    const writePatterns: string[] = access.write ?? [];
    const mcpAllowed = mode !== "review" || access.inPasses !== false;
    const severities = ["nit", "low", "medium", "high", "critical"];
    const verdicts = ["confirmed", "rejected", "question", "merged"];
    const kinds = ["finding", "ac", "question"];
    const readTools = ["read", "grep", "find", "ls"];
    const ownTools = ["akit_submit_findings", "akit_report_context_gap", "akit_submit_context", "akit_approved_requests"];
    const resourceTools = ["list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource"];
    const forbiddenVerbs = ["publish", "submit", "approve", "unapprove", "merge", "resolve", "unresolve", "rebase", "close", "reopen", "accept"];
    const forbiddenWords = ["publish", "submit", "approve", "unapprove"];
    const writeWords = ["create", "update", "delete", "remove", "add", "set", "post", "put", "patch", "edit", "write", "upload",
      "push", "fork", "cancel", "retry", "run", "trigger", "execute", "exec", "invoke", "assign", "unassign",
      "move", "link", "unlink", "archive", "restore", "import", "transfer", "subscribe", "unsubscribe", "comment",
      "reply", "mark", "toggle", "start", "stop", "label", "graphql", "api", "send", "save",
      "make", "change", "modify", "rename", "lock", "unlock", "play", "erase", "destroy", "revert"];
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

    // The same rules as ReviewMCPPolicy.kind in AKit. null: not an MCP tool.
    function mcpKind(name: string, hints: any): "read" | "write" | "blocked" | null {
      const match = /^mcp__(.+?)__(.+)$/.exec(name);
      if (!match) return null;
      const [, server, tool] = match;
      const words = tool.toLowerCase().split(/[^a-z]+/).filter((w) => w.length > 0);
      if (servers.length > 0 && !servers.includes(norm(server))) return "blocked";
      if (forbiddenVerbs.includes(words[0] ?? "") || words.some((w) => forbiddenWords.includes(w))) return "blocked";
      const writes = words.some((w) => writeWords.includes(w));
      // A write pattern catches only tools that write: *draft_note* takes create_draft_note, not list_draft_notes.
      if (writes && writePatterns.some((p) => like(p, tool))) return "write";
      if (hints?.readOnlyHint === true || readPatterns.some((p) => like(p, tool))) return "read";
      return writes ? "blocked" : "read";
    }

    function leaves(value: any, out: string[] = []): string[] {
      if (typeof value === "string" || typeof value === "number") out.push(String(value).trim());
      else if (Array.isArray(value)) value.forEach((v) => leaves(v, out));
      else if (value !== null && typeof value === "object") Object.values(value).forEach((v) => leaves(v, out));
      return out;
    }

    function verb(name: string): string {
      const lower = name.toLowerCase();
      if (/delete|remove|destroy/.test(lower)) return "delete";
      if (/update|edit|modify|put|change/.test(lower)) return "update";
      return "create";
    }

    // The approved request a write call carries out: the same action, the approved text word for
    // word, and the draft, thread, file and line the request names. null: none, so it is blocked.
    function approvedMatch(name: string, input: any): any {
      const values = leaves(input);
      for (const request of approved) {
        if (claimed.has(request.id) || request.action !== verb(name)) continue;
        if (request.action !== "delete" && !values.includes(String(request.body ?? "").trim())) continue;
        if (request.draft_id != null && !values.includes(String(request.draft_id))) continue;
        if (request.discussion_id && !values.includes(String(request.discussion_id))) continue;
        if (request.path && !values.includes(String(request.path))) continue;
        if (request.line != null && !values.includes(String(request.line))) continue;
        return request;
      }
      return null;
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

    function save(tool: string, input: any, text: string[], structured: any, isError: boolean) {
      saved += 1;
      write(`mcp/calls/${pass}-${Date.now()}-${String(saved).padStart(4, "0")}.json`, JSON.stringify({ pass, tool,
        input: JSON.stringify(input ?? {}), text, structured: structured === undefined ? null : JSON.stringify(structured), isError }));
    }

    function problems(findings: any[], verdictList: any[]): string[] {
      const out: string[] = [];
      if (findings.length > max) out.push(`at most ${max} findings for this role; send the strongest ones`);
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
      });
      verdictList.forEach((v, i) => {
        const at = `verdicts[${i}]`;
        if (typeof v?.id !== "string") out.push(`${at}.id is missing`);
        if (!verdicts.includes(v?.verdict)) out.push(`${at}.verdict must be one of ${verdicts.join(", ")}`);
        if (typeof v?.note !== "string") out.push(`${at}.note is missing`);
        if (v?.verdict === "merged" && typeof v?.into !== "string") out.push(`${at}.into names the finding it merges into`);
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
                  },
                  required: ["id", "verdict", "note"],
                },
              },
            },
          },
          async execute(_id: string, params: any) {
            const findings = Array.isArray(params?.findings) ? params.findings : [];
            const verdictList = Array.isArray(params?.verdicts) ? params.verdicts : [];
            const wrong = problems(findings, verdictList);
            if (wrong.length > 0) {
              return { content: [{ type: "text", text: "Not saved. Fix these and call again:\n- " + wrong.join("\n- ") }], details: undefined, isError: true };
            }
            const name = pass === "discuss" ? `passes/discuss-${Date.now()}.json` : `passes/${pass}.json`;
            write(name, JSON.stringify({ pass, role, findings, verdicts: verdictList }, null, 2));
            return { content: [{ type: "text", text: `Saved ${findings.length} findings and ${verdictList.length} verdicts.` }], details: undefined };
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

      pi.on("tool_call", async (event: any, ctx: any) => {
        const name = String(event.toolName ?? "");
        if (ownTools.includes(name)) return undefined;
        if (name === "codemode" || name === "tool_search") {
          // Every tool a script or a search reaches comes back through this check.
          return mcpAllowed ? undefined : { block: true, reason: "AKit review gives this pass no MCP tools." };
        }
        if (resourceTools.includes(name)) {
          if (!mcpAllowed) return { block: true, reason: "AKit review gives this pass no MCP tools." };
          const server = norm(event.input?.server ?? "");
          if (servers.length > 0 && !servers.includes(server)) return { block: true, reason: `The project lets review use only ${servers.join(", ")}.` };
          return undefined;
        }
        const hints = (pi.getAllTools?.() ?? []).find((tool: any) => tool.name === name)?.annotations;
        const kind = mcpKind(name, hints);
        if (kind !== null) {
          if (!mcpAllowed) return { block: true, reason: "AKit review gives this pass no MCP tools." };
          if (kind === "blocked") {
            return { block: true, reason: `AKit review doesn't let ${name} run: it isn't a reading tool of the project's servers, `
              + "and review never publishes, approves, merges or resolves." };
          }
          if (kind === "write") {
            if (mode !== "send") return { block: true, reason: "Only Send Drafts writes, and only what the user approved." };
            const request = approvedMatch(name, event.input);
            if (request === null) {
              return { block: true, reason: "This call carries none of the approved requests word for word (action, text, draft, "
                + "thread, file and line). Use the bodies from akit_approved_requests unchanged." };
            }
            claimed.add(request.id);
            pending.set(String(event.toolCallId), request.id);
          }
          return undefined;
        }
        if (mode !== "review") return { block: true, reason: `${name}: this pass works only through MCP tools.` };
        if (!readTools.includes(name)) return { block: true, reason: `AKit review allows only reading tools; ${name} is not one.` };
        const given = typeof event.input?.path === "string" && event.input.path.length > 0 ? event.input.path : ".";
        // Pi expands a leading ~ and @ and reads file:// addresses itself: never let one through,
        // or the check below would see a different path than Pi reads.
        if (/^\s*(~|@|file:)/i.test(given)) return { block: true, reason: `AKit review takes plain paths only; ${given} is not one.` };
        const target = real(path.resolve(ctx?.cwd ?? process.cwd(), given));
        if (!inside(target)) return { block: true, reason: `AKit review reads only the worktree and the run's context pack; ${given} is outside.` };
        if (blocked(target)) return { block: true, reason: `${given} usually holds secrets; AKit review never reads it.` };
        for (const key of ["glob", "pattern"]) {
          const value = event.input?.[key];
          if (name !== "grep" || key === "glob") {
            if (typeof value === "string" && (blocked(value) || value.includes("..") || /^\s*(\/|~|@|file:)/i.test(value))) {
              return { block: true, reason: "That pattern leaves the folder or names files that usually hold secrets." };
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
