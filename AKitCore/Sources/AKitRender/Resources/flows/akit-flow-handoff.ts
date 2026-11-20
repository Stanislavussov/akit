// akit-flow-handoff.ts: written by AKit (docs/design/flows.md F4). Loaded into each flow step's
// child Pi with -e. Gives the model the tool `flow_handoff`; its parameters are the model's part
// of the handoff, checked by Pi against the schema. The tool writes them to the file named in
// AKIT_FLOW_HANDOFF; the runner adds run, step, session, next, tokens and deviations itself.

import { renameSync, writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Plain JSON Schema: Pi validates it as it does a TypeBox schema. */
export const HANDOFF_PARAMETERS = {
	type: "object",
	properties: {
		goal: { type: "string", description: "What this step was for, in one line." },
		done: { type: "array", items: { type: "string" }, description: "What the step did, one item per line." },
		files: {
			type: "array",
			description: "Files the step changed.",
			items: {
				type: "object",
				properties: { path: { type: "string" }, change: { type: "string", description: "added, changed or removed" } },
				required: ["path", "change"],
			},
		},
		open_questions: { type: "array", items: { type: "string" } },
		notes: { type: "string", description: "What the next step must know." },
		plan: {
			type: "object",
			description: "Planner steps only: the plan as ordered steps and one plain command that proves it (runs only the tests the change touches).",
			properties: {
				steps: { type: "array", items: { type: "string" } },
				check: { type: "string", description: "One plain command, such as python3 -m unittest test_stats; empty when there is none." },
			},
			required: ["steps", "check"],
			additionalProperties: false,
		},
		outcome: { type: "string", enum: ["done", "failed", "blocked"] },
		reason: { type: "string", description: "Why the step failed or is blocked; one word such as tests or unclear. Empty when done." },
	},
	required: ["goal", "done", "files", "open_questions", "notes", "outcome", "reason"],
	additionalProperties: false,
} as const;

export default function akitFlowHandoff(pi: ExtensionAPI): void {
	pi.registerTool({
		name: "flow_handoff",
		label: "Flow handoff",
		description: "End this flow step: hand over what you did and the outcome (done, failed or blocked). Call it once, as the last thing you do.",
		parameters: HANDOFF_PARAMETERS,
		async execute(_id, params) {
			const path = process.env.AKIT_FLOW_HANDOFF;
			if (!path) return { content: [{ type: "text", text: "Not in a flow step: nothing recorded." }], details: undefined };
			const tmp = `${path}.tmp-${process.pid}`;
			writeFileSync(tmp, `${JSON.stringify(params, null, 2)}\n`);
			renameSync(tmp, path);
			return { content: [{ type: "text", text: "Handoff recorded. Stop now." }], details: undefined };
		},
	});
}
