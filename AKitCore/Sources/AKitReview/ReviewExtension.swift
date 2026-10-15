import Foundation

/// The Pi extension of a review pass, `<run>/akit-review.ts` (`docs/design/review.md`, "The agent
/// in a pass"). It is thin: two tools that write into the run folder, and a `tool_call` policy.
/// Everything that decides what reaches GitLab is Swift. AKit passes it, per pass:
/// `AKIT_REVIEW_RUN` (the run folder), `AKIT_REVIEW_PASS`, `AKIT_REVIEW_ROLE`, `AKIT_REVIEW_MAX`,
/// `AKIT_REVIEW_ROOTS` (folders reads may reach, `:`-separated), `AKIT_REVIEW_RUN_ID`,
/// `AKIT_REVIEW_SCENARIO`, `AKIT_REVIEW_HEAD`.
public enum ReviewExtension {
    /// Bumped when the text changes; written into the file's first line.
    public static let version = 2

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
    // akit-review.ts v2: written by AKit for one review run. Do not edit: AKit writes it again.
    import * as fs from "node:fs";
    import * as path from "node:path";

    const run = process.env.AKIT_REVIEW_RUN ?? "";
    const pass = process.env.AKIT_REVIEW_PASS ?? "pass";
    const role = process.env.AKIT_REVIEW_ROLE ?? "";
    const max = Number(process.env.AKIT_REVIEW_MAX ?? "20");
    const roots = (process.env.AKIT_REVIEW_ROOTS ?? "").split(":").filter((r) => r.length > 0).map((r) => real(r));
    const severities = ["nit", "low", "medium", "high", "critical"];
    const verdicts = ["confirmed", "rejected", "question", "merged"];
    const kinds = ["finding", "ac", "question"];
    const readTools = ["read", "grep", "find", "ls"];
    const ownTools = ["akit_submit_findings", "akit_report_context_gap"];

    function real(p: string): string {
      try { return fs.realpathSync(p); } catch { return path.resolve(p); }
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

      pi.registerTool({
        name: "akit_report_context_gap",
        label: "Report a context gap",
        description: "Say what you needed and the context pack didn't have, instead of guessing.",
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
          const line = JSON.stringify({ system: String(params.system ?? "other"), needed: params.needed, why: params.why,
            howToGet: String(params.how_to_get ?? ""), effect: String(params.effect ?? ""), reportedBy: pass }) + "\n";
          const target = path.join(run, `passes/gaps-${pass}.jsonl`);
          fs.mkdirSync(path.dirname(target), { recursive: true });
          fs.appendFileSync(target, line);
          return { content: [{ type: "text", text: "Gap recorded." }], details: undefined };
        },
      });

      pi.on("tool_call", async (event: any, ctx: any) => {
        const name = String(event.toolName ?? "");
        if (ownTools.includes(name)) return undefined;
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

      pi.on("session_start", async () => {
        pi.appendEntry("akit-review", { run: process.env.AKIT_REVIEW_RUN_ID ?? "", pass, scenario: process.env.AKIT_REVIEW_SCENARIO ?? "",
          head: process.env.AKIT_REVIEW_HEAD ?? "" });
      });
    }
    """#
}
