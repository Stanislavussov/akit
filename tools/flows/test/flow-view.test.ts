// flow-view.ts: the row, the overlay lines and the shortcut keys.
import assert from "node:assert/strict";
import { test } from "node:test";
import { BUILTIN_KEYS, newView, overlayLines, pickShortcuts, rowLine, shortArgs, viewEvent } from "../../../AKitCore/Sources/AKitRender/Resources/flows/flow-view.ts";

const flow = { "akit-flow-format": 1, name: "feature", steps: [
	{ id: "Plan", agent: "planner", model: "anthropic/opus" }, { id: "Code", agent: "implementer", model: "openai/gpt" }, { id: "Checks", agent: "checker", model: "x/y" },
] };

test("the row shows state, model, tokens, deviations and the keys", () => {
	const view = newView(flow, "r1");
	view.steps[0].state = "done";
	view.steps[0].tokens = 800;
	view.steps[1].state = "running";
	view.steps[1].tokens = 12_345;
	view.deviations = 1;
	assert.equal(rowLine(view, ["alt+1", "alt+2", "alt+3"]), "1 Plan ✓ opus 800  2 Code ● gpt 12k  3 Checks ○   ⚠ 1   alt+1…3 view");
});

test("the overlay shows tool calls with short redacted args and assistant text, never tool output", () => {
	const view = newView(flow, "r1");
	const step = view.steps[1];
	step.state = "running";
	viewEvent(step, { type: "tool_execution_start", toolCallId: "c1", toolName: "bash", args: { command: "API_TOKEN=abc make test" } });
	viewEvent(step, { type: "tool_execution_end", toolCallId: "c1", toolName: "bash", result: { content: [{ type: "text", text: "SECRET OUTPUT" }] }, isError: true });
	viewEvent(step, { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "tests fail" }], usage: { input: 10, output: 5 } } });
	const lines = overlayLines(view, 2);
	assert.ok(lines.includes("✗ bash API_TOKEN=*** make test"));
	assert.ok(lines.includes("tests fail"));
	assert.ok(!lines.join("\n").includes("SECRET OUTPUT"));
	assert.equal(step.tokens, 15);
	assert.equal(lines.at(-1), "Esc closes");
	assert.equal(shortArgs("read", { path: "src/a.ts", offset: 2 }), "src/a.ts");
});

test("shortcuts are alt+N keys Pi 1.0.4 and the user's bindings don't use", () => {
	assert.deepEqual(pickShortcuts(3, []), ["alt+1", "alt+2", "alt+3"]);
	assert.deepEqual(pickShortcuts(3, ["Alt+2"]), ["alt+1", "alt+3"], "a clash means no shortcut");
	for (const key of pickShortcuts(9, [])) assert.ok(!BUILTIN_KEYS.has(key));
});
