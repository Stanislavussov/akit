import Foundation

/// `flow.schema.json`: the JSON Schema of a flow file, made from the model's rules here. The
/// committed copy in `Resources/` must equal `FlowSchema.text` (a test checks; `akit flow schema` prints it).
public enum FlowSchema {
    public static var text: String {
        let strings: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let outcomes = FlowOutcome.allCases.map(\.rawValue).joined(separator: "|")
        let step: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "agent", "model"],
            "properties": [
                "id": ["type": "string", "pattern": "^[A-Za-z0-9][A-Za-z0-9_-]*$"],
                "harness": ["type": "string", "enum": [FlowStep.claudeCode], "description": "Left out: Pi. claude-code: the step runs as claude -p, read only."],
                "agent": ["type": "string", "description": "From the agent list; implementer and reviewer must use different models."],
                "model": ["type": "string"],
                "thinking": ["type": "string"],
                "prompt": ["type": "string", "description": "What the step does; the runner puts it after the task."],
                "skills": strings,
                "tools": strings.merging(["description": "A subset of the flow's tools."]) { $1 },
                "paths": strings.merging(["description": "Paths the step may write; empty means anywhere in the worktree."]) { $1 },
                "bash": ["type": "boolean", "description": "Default: true unless paths is set."],
                "extensions": strings.merging(["description": "The per-step -e list of Pi extensions."]) { $1 },
                "gate": ["type": "boolean", "default": false],
                "checks": [
                    "type": "array", "maxItems": FlowCheck.maxCheckCommands,
                    "items": ["type": "string", "maxLength": FlowCheck.maxCheckLength, "pattern": "^[A-Za-z][A-Za-z0-9 _.:/=%@-]*$"],
                ] as [String: Any],
                "maxLoops": ["type": "integer", "minimum": 1, "default": FlowStep.defaultMaxLoops],
                "routes": [
                    "type": "object",
                    "description": "outcome:reason or outcome:* to the next step's id, or \(FlowRouting.end).",
                    "propertyNames": ["pattern": "^(\(outcomes)):(\\*|[A-Za-z0-9][A-Za-z0-9_.-]*)$"],
                    "additionalProperties": ["type": "string"],
                ] as [String: Any],
            ] as [String: Any],
        ]
        let schema: [String: Any] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": "https://akit.local/flow.schema.json",
            "title": "AKit flow",
            "type": "object",
            "additionalProperties": false,
            "required": ["akit-flow-format", "name", "steps"],
            "properties": [
                "akit-flow-format": ["type": "integer", "const": Flow.currentFormat],
                "name": ["type": "string"],
                "minPi": ["type": "string", "default": Flow.defaultMinPi],
                "tools": strings,
                "steps": ["type": "array", "minItems": 1, "items": step] as [String: Any],
            ] as [String: Any],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
