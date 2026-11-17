// The golden vectors (fixtures/flow-vectors) through flow-core.ts: the same answers as Swift's FlowRouting.next.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { compareVersions, type Flow, formatProblem, isSafeCommand, nextStep, type Outcome, parseOutcome, runId } from "../../../AKitCore/Sources/AKitRender/Resources/flows/flow-core.ts";

const vectors = join(import.meta.dirname, "..", "..", "..", "fixtures", "flow-vectors");
const files = readdirSync(vectors).filter((f) => f.endsWith(".json")).sort();

test("there are golden vectors", () => assert.ok(files.length >= 10));

for (const file of files) {
	test(`vector ${file}`, () => {
		const v = JSON.parse(readFileSync(join(vectors, file), "utf8")) as {
			flow: Flow; state: { step: string; visits: Record<string, number> }; outcome: Outcome; reason: string; expect: unknown;
		};
		const got = JSON.parse(JSON.stringify(nextStep(v.flow, v.state, v.outcome, v.reason)));
		assert.deepEqual(got, v.expect);
	});
}

test("versions compare by number", () => {
	assert.equal(compareVersions("1.0.4", "1.10.0"), -1);
	assert.equal(compareVersions("1.5.2", "1.0.4"), 1);
	assert.equal(compareVersions("v1.0.4", "1.0.4"), 0);
});

test("a newer flow format asks for Apply", () => {
	const flow = { "akit-flow-format": 2, name: "f", steps: [{ id: "a", agent: "x", model: "m" }] };
	assert.match(formatProblem(flow) ?? "", /run Apply in AKit/);
	assert.equal(formatProblem({ ...flow, "akit-flow-format": 1 }), undefined);
});

test("run id is YYYYMMDD-HHMM-xxxx", () => {
	assert.equal(runId(new Date(2026, 10, 16, 14, 32), "a3f9ff"), "20261116-1432-a3f9");
});

test("the fallback outcome comes from the last outcome line, else none", () => {
	assert.deepEqual(parseOutcome("x\noutcome: done\noutcome: failed:notes"), { outcome: "failed", reason: "notes" });
	assert.equal(parseOutcome("no line"), undefined);
});

test("check commands follow AKit's rule", () => {
	assert.ok(isSafeCommand("make test"));
	assert.ok(isSafeCommand("npm run lint --silent"));
	assert.ok(!isSafeCommand("make test && rm -rf /"));
	assert.ok(!isSafeCommand("echo $HOME"));
	assert.ok(!isSafeCommand(`make ${"x".repeat(120)}`));
});
