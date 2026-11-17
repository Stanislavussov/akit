// make check-pi: the installed Pi against the runner's minimum and tested versions (flows.md F20).
import { compareVersions, MIN_PI, TESTED_PI } from "../../AKitCore/Sources/AKitRender/Resources/flows/flow-core.ts";
import { detectPi, missingFlags, OPTIONAL_FLAGS, PI } from "../../AKitCore/Sources/AKitRender/Resources/flows/pi-adapter.ts";

const info = await detectPi();
if (!info.version) {
	console.error(`${PI} --version gave no version; is Pi installed?`);
	process.exit(1);
}
console.log(`Pi ${info.version} (minPi ${MIN_PI}, testedPi ${TESTED_PI})`);
const missing = missingFlags(info);
for (const flag of OPTIONAL_FLAGS) if (!info.features[flag]) console.log(`fallback: ${flag} not found`);
if (compareVersions(info.version, MIN_PI) < 0 || missing.length) {
	console.error(`Not supported: ${missing.length ? `missing ${missing.join(", ")}` : `older than ${MIN_PI}`}`);
	process.exit(1);
}
if (compareVersions(info.version, TESTED_PI) > 0) console.log(`warning: newer than testedPi ${TESTED_PI}; run the tests on it and raise TESTED_PI`);
