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
    /// Tools whose call without an id read a secret file, oldest first.
    private var unnamed: [String] = []

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
            if let id = object["toolCallId"] as? String { secretCalls.insert(id) } else { unnamed.append(object["toolName"] as? String ?? "") }
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
        var changed = false
        let call = (object["toolCallId"] as? String) ?? (object["type"] as? String == "toolCall" ? object["id"] as? String : nil)
        var secret = call.map(secretCalls.contains) ?? false
        // No call id: the next end of the tool that read a secret file.
        if call == nil, type == "tool_execution_end", let name = object["toolName"] as? String, let index = unnamed.firstIndex(of: name) {
            unnamed.remove(at: index)
            secret = true
        }
        if call == nil, type == "tool_execution_update", let name = object["toolName"] as? String, unnamed.contains(name) { secret = true }
        if secret {
            for key in ["result", "partialResult", "content", "output"] where object[key] != nil {
                object[key] = ["content": [["type": "text", "text": SecretFilter.hiddenOutput]]]
                if key == "content" { object[key] = [["type": "text", "text": SecretFilter.hiddenOutput]] }
                changed = true
            }
            for key in ["args", "arguments"] where object[key] != nil {
                if let redacted = SecretFilter.redactedInput(object[key]) { object[key] = redacted }
                changed = true
            }
        }
        for (key, item) in object where !(secret && ["result", "partialResult", "content", "output", "args", "arguments"].contains(key)) {
            let (new, itemChanged) = hide(item, type: nil)
            if itemChanged {
                object[key] = new
                changed = true
            }
        }
        return (object, changed)
    }
}
