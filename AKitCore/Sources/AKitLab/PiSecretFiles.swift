import AKitFoundation
import Foundation

/// Hides what Pi read from files that usually hold secrets (`.env`, `auth.json`, Pi's
/// `mcp.json`…, `SecretFilter.isSecretFile`) in its json stream, as the session viewers do: a
/// tool call that reads one gets its result, partial results and tool-result messages replaced by
/// `SecretFilter.hiddenOutput`, and a call that writes one has its content redacted
/// (`SecretFilter.redactedInput`). Calls are known by `toolCallId`; a stream without ids hides
/// the next result of the same tool. One instance per stream, fed the lines in order.
public final class PiSecretFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var secretCalls = Set<String>()
    /// Tools whose last call without an id read a secret file: their results without an id are
    /// hidden until a call of the same tool without an id reads something else.
    private var unnamed = Set<String>()

    public init() {}

    /// The line with secret-file content hidden; unchanged when there is none (or it isn't JSON).
    public func line(_ line: String) -> String {
        guard line.hasPrefix("{"), line.contains("tool") || line.contains("Tool"),
              let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return line }
        let (hidden, changed) = lock.withLock { () -> (Any, Bool) in
            register(event)
            return hide(event, type: event["type"] as? String)
        }
        guard changed, let data = try? JSONSerialization.data(withJSONObject: hidden, options: [.sortedKeys, .withoutEscapingSlashes]) else { return line }
        return String(decoding: data, as: UTF8.self)
    }

    /// Notes the calls that read or write a secret file: a tool call part of an assistant
    /// message (`id`, `arguments`) or a `tool_execution_start` (`toolCallId`, `args`).
    private func register(_ value: Any) {
        if let list = value as? [Any] { list.forEach(register); return }
        guard let object = value as? [String: Any] else { return }
        if object["type"] as? String == "toolCall", let id = object["id"] as? String, SecretFilter.readsSecretFile(object["arguments"]) {
            secretCalls.insert(id)
        }
        if object["type"] as? String == "tool_execution_start", SecretFilter.readsSecretFile(object["args"]) {
            if let id = object["toolCallId"] as? String { secretCalls.insert(id) } else { unnamed.insert(object["toolName"] as? String ?? "") }
        } else if object["type"] as? String == "tool_execution_start", object["toolCallId"] == nil {
            unnamed.remove(object["toolName"] as? String ?? "")
        }
        for item in object.values { register(item) }
    }

    /// The value with the results of secret calls hidden and their inputs redacted.
    private func hide(_ value: Any, type: String?) -> (Any, Bool) {
        if let list = value as? [Any] {
            var changed = false
            let hidden = list.map { item -> Any in
                let (new, itemChanged) = hide(item, type: nil)
                changed = changed || itemChanged
                return new
            }
            return (hidden, changed)
        }
        guard var object = value as? [String: Any] else { return (value, false) }
        let call = (object["toolCallId"] as? String) ?? (object["type"] as? String == "toolCall" ? object["id"] as? String : nil)
        var secret = call.map(secretCalls.contains) ?? false
        // No call id: a result of a tool whose last call without an id read a secret file.
        if call == nil, let name = object["toolName"] as? String, unnamed.contains(name),
           type == "tool_execution_end" || type == "tool_execution_update" || object["role"] as? String == "toolResult" {
            secret = true
        }
        let input = object["type"] as? String == "toolCall" || type == "tool_execution_start"
        if secret, input {
            // The call itself: its arguments, with a secret file's content redacted.
            for key in ["args", "arguments"] where object[key] != nil {
                if let redacted = SecretFilter.redactedInput(object[key]) { object[key] = redacted }
            }
            return (object, true)
        }
        if secret {
            // A result in any shape (an end, an update, a toolResult message, an entry of
            // turn_end.toolResults or agent_end.messages): only who and what, and a marker. Its
            // content, details (a truncated copy) and structured content (the full output's path) go.
            var kept = object.filter { ["role", "toolCallId", "toolName", "isError", "timestamp", "type"].contains($0.key) }
            let marker: [[String: Any]] = [["type": "text", "text": SecretFilter.hiddenOutput]]
            if object["result"] != nil { kept["result"] = ["content": marker] }
            if object["partialResult"] != nil { kept["partialResult"] = ["content": marker] }
            if object["content"] != nil || (object["result"] == nil && object["partialResult"] == nil) { kept["content"] = marker }
            return (kept, true)
        }
        var changed = false
        for (key, item) in object {
            let (new, itemChanged) = hide(item, type: nil)
            if itemChanged {
                object[key] = new
                changed = true
            }
        }
        return (object, changed)
    }
}
