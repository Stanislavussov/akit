// The scenario gates of the flow runner (F26): plan against agreed scenarios, tester claims, red
// before the code, tests unchanged after the tester.
import assert from "node:assert/strict";
import { test } from "node:test";
import { planScenariosGate, redFirstGate, testClaimsGate, testsUnchangedGate } from "../../../AKitCore/Sources/AKitRender/Resources/flows/flow-core.ts";

test("technical work (no work item, no scenarios) has no plan gate", () => {
	assert.equal(planScenariosGate({ work_item: "", scenarios: [] }, ["SC-ORD-001"]), undefined);
});

test("the plan must cover every agreed scenario of its work item and no other", () => {
	assert.equal(planScenariosGate({ work_item: "123456", scenarios: ["SC-ORD-001", "SC-ORD-002"] }, ["SC-ORD-001", "SC-ORD-002"])?.exit, 0);
	const missing = planScenariosGate({ work_item: "123456", scenarios: ["SC-ORD-001"] }, ["SC-ORD-001", "SC-ORD-002"]);
	assert.equal(missing?.exit, 1);
	assert.match(missing?.tail.join("\n") ?? "", /leaves out: SC-ORD-002/);
	const extra = planScenariosGate({ work_item: "123456", scenarios: ["SC-ORD-001", "SC-ORD-009"] }, ["SC-ORD-001"]);
	assert.match(extra?.tail.join("\n") ?? "", /not agreed for ADO 123456: SC-ORD-009/);
});

test("a work item with no agreed scenario stops the plan; a read error is red too", () => {
	assert.match(planScenariosGate({ work_item: "123456", scenarios: [] }, [])?.tail[0] ?? "", /No agreed scenario names ADO 123456/);
	assert.equal(planScenariosGate({ work_item: "123456", scenarios: [] }, { error: "akit: not found" })?.exit, 1);
});

test("each plan scenario needs a claimed test in a file the tester changed, with its name", () => {
	const files: Record<string, string> = { "src/cancel.test.ts": `describe("cancel", () => { it("keeps a shipped order", () => {}); });` };
	const read = (p: string) => files[p];
	const changed = new Set(["src/cancel.test.ts"]);
	const good = [{ scenario: "SC-ORD-002", path: "src/cancel.test.ts", name: "cancel › keeps a shipped order" }];
	assert.equal(testClaimsGate(["SC-ORD-002"], good, changed, read).exit, 0);
	const tail = testClaimsGate(["SC-ORD-002", "SC-ORD-003"], [
		{ scenario: "SC-ORD-002", path: "src/cancel.test.ts", name: "cancel › refunds" },
		{ scenario: "SC-ORD-009", path: "src/other.test.ts", name: "x" },
	], changed, read).tail.join("\n");
	assert.match(tail, /no test in your handoff's tests: SC-ORD-003/);
	assert.match(tail, /has no “refunds”/);
	assert.match(tail, /SC-ORD-009 is not a scenario of the plan/);
	assert.match(tail, /src\/other.test.ts .* is not among the files this step changed/);
});

test("the plan's check must be red after the tester, and must have run", () => {
	assert.equal(redFirstGate("npm test", 1, []).exit, 0);
	assert.match(redFirstGate("npm test", 0, []).tail[0], /passes before the code/);
	assert.equal(redFirstGate("npm test", 127, []).exit, 1);
	assert.equal(redFirstGate("npm test", null, []).exit, 1);
	assert.match(redFirstGate("", 1, []).tail[0], /no check command/);
});

test("a tester's test changed after it is red", () => {
	const hashes = { "a.test.ts": "h1", "b.test.ts": "h2" };
	assert.equal(testsUnchangedGate(hashes, (p) => hashes[p as keyof typeof hashes]).exit, 0);
	const gate = testsUnchangedGate(hashes, (p) => (p === "a.test.ts" ? "h1" : undefined));
	assert.equal(gate.exit, 1);
	assert.match(gate.tail[0], /changed after it: b.test.ts/);
});
