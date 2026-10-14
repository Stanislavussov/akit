import Foundation

/// Rewrite with Skill… on the Instructions screen: one model call rewrites an instruction file
/// by a skill's guidance (a writing skill, say) and a short request; the answer comes back as a
/// diff for the user to accept. This part is pure: the text sent and the checks on the answer.
/// AKit's core block never goes out and can't be changed: it is replaced by a marker line that
/// the answer must keep, once per block, and put back in place.
public enum InstructionRewrite {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// Stands for one AKit core block in the text sent.
    public static let marker = "<!-- akit: core block, kept by AKit -->"

    /// The JSON answer Claude Code checks (Pi gets the same rule in the prompt).
    public static let schema = #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#

    public struct Prepared: Sendable {
        public let system: String
        public let input: String
        /// The blocks taken out, in order, as the file has them.
        let blocks: [String]
        let crlf: Bool
    }

    /// The text to send. `skill`: the skill's SKILL.md; `request`: what the user wants changed.
    public static func prepare(file text: String, skillName: String, skill: String, request: String) -> Prepared {
        var blocks: [String] = []
        var lines: [String] = []
        let sections = InstructionText.sections(text)
        var blockLines: [Range<Int>] = []
        for section in sections where section.isAKitBlock {
            let count = InstructionText.lines(section.text).count
            blockLines.append((section.line - 1)..<(section.line - 1 + count))
            blocks.append(section.text)
        }
        for (index, line) in InstructionText.lines(text).enumerated() {
            if let range = blockLines.first(where: { $0.contains(index) }) {
                if index == range.lowerBound { lines.append(marker) }
                continue
            }
            lines.append(line.hasSuffix("\r") ? String(line.dropLast()) : line)
        }
        let system = """
            You rewrite an instruction file for a coding agent (an AGENTS.md or CLAUDE.md that the agent reads at the start of every session).
            Follow the skill below for how to write. Do what the user's request asks; keep the meaning of every rule unless the request says otherwise; don't add rules of your own.
            Keep Markdown structure: ## headings mark sections.
            Keep every line \(marker) exactly as it is, in its place: it stands for text you don't see.
            Answer with JSON only: {"text": "<the whole new file>"}.

            # Skill: \(skillName)

            \(skill)
            """
        let input = "Request: \(request.isEmpty ? "Make it clearer and shorter; keep every rule." : request)\n\nFile:\n\(lines.joined(separator: "\n"))"
        return Prepared(system: system, input: input, blocks: blocks, crlf: text.contains("\r\n"))
    }

    /// The new file from the model's answer: the blocks put back, the file's line endings, a
    /// final newline. Refused when the answer isn't the JSON asked for or lost a marker.
    public static func result(_ answer: String, prepared: Prepared) throws(Failure) -> String {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any],
              let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "The answer isn't the JSON asked for ({\"text\": …}). Try again, or with another model.")
        }
        var lines = InstructionText.lines(text.replacingOccurrences(of: "\r\n", with: "\n"))
        let found = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == marker }
        guard found.count == prepared.blocks.count else {
            throw Failure(message: "The answer changed or dropped AKit's core block (\(found.count) of \(prepared.blocks.count) kept). Nothing is written; try again.")
        }
        for (index, block) in zip(found, prepared.blocks).reversed() {
            var own = InstructionText.lines(block).map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            if own.last == "" { own.removeLast() }
            lines.replaceSubrange(index...index, with: own)
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let joined = lines.joined(separator: "\n") + "\n"
        return prepared.crlf ? joined.replacingOccurrences(of: "\n", with: "\r\n") : joined
    }
}
