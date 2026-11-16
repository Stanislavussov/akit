# Flow routing vectors

Golden cases for flow routing (docs/design/flows.md F19). Swift's `FlowRouting.next`
(`AKitFlowsTests`) and, later, the Pi runner's `flow-core.ts` (`node --test`) must give the
same answer for each file.

Each `*.json` holds:

- `flow`: a flow file as JSON (the same keys as the YAML, `akit-flow-format` included);
- `state`: `{step, visits}`, the step that just ended and how often each step has started;
- `outcome` (`done`, `failed`, `blocked`) and `reason` (may be empty);
- `expect`: `{next, visits}` for the next step, or `{stop, step?, visits}` with `stop` one of
  `done`, `visit-cap`, `no-route`, `unknown-step`.

Lookup: `outcome:reason`, then `outcome:*`; a `done` without a route goes to the next step in
the column (the end after the last); the target `end` stops with `done`; a target that has
already started `maxLoops` times stops with `visit-cap`.
