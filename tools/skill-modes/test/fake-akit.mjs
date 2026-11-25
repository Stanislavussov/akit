#!/usr/bin/env node
// A fake `akit` for the skill modes extension's tests: logs each call (arguments and stdin) to
// $FAKE_AKIT_CALLS and answers by $FAKE_AKIT_MODE: good (the JSON in $FAKE_AKIT_ANSWER), slow
// (never in time), bad (not JSON), wrong (JSON of another shape), fail (exit 3).
import { appendFileSync, readFileSync } from "node:fs";

let stdin = "";
process.stdin.on("data", (chunk) => (stdin += chunk));
process.stdin.on("end", () => {
	appendFileSync(process.env.FAKE_AKIT_CALLS, JSON.stringify({ args: process.argv.slice(2), stdin: JSON.parse(stdin || "{}") }) + "\n");
	switch (process.env.FAKE_AKIT_MODE) {
		case "slow":
			setTimeout(() => process.stdout.write(readFileSync(process.env.FAKE_AKIT_ANSWER, "utf8")), 10_000);
			break;
		case "bad":
			process.stdout.write("not json");
			break;
		case "wrong":
			process.stdout.write(JSON.stringify({ version: 2 }));
			break;
		case "fail":
			process.stderr.write("akit: broken\nmore\n");
			process.exit(3);
			break;
		default:
			process.stdout.write(readFileSync(process.env.FAKE_AKIT_ANSWER, "utf8"));
	}
});
