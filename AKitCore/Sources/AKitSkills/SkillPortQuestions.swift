import Foundation

/// Port to Pi's questions (`docs/design/skill-port.md`, "Questions"): choice points found in the
/// skill before the port, each with options and a recommended default. An answer is a rules text
/// (`SkillPortRules`), so answers, presets and the user's own rules go through one engine. The
/// technology choice points come from the alternatives catalog (data); the Claude Code → Pi ones
/// are a table of detectors here: a new choice point is one more entry in either.
public struct SkillPortQuestion: Codable, Sendable, Hashable, Identifiable {
    public struct Option: Codable, Sendable, Hashable, Identifiable {
        public let id: String
        public let title: String
        /// What the option means for the port, as a rules text (empty: the built-in behavior).
        public let rules: String

        public init(id: String, title: String, rules: String = "") {
            self.id = id
            self.title = title
            self.rules = rules
        }
    }

    public let id: String
    public let question: String
    public let options: [Option]
    /// The recommended option's id.
    public let recommended: String
    /// What in the skill raised the question (a catalog member, "AskUserQuestion", "model").
    public let evidence: [String]
    /// The catalog family (or the model's family name) the question is about; questions merge by it.
    public var family: String?

    public init(id: String, question: String, options: [Option], recommended: String, evidence: [String], family: String? = nil) {
        self.family = family
        self.id = id
        self.question = question
        self.options = options
        self.recommended = recommended
        self.evidence = evidence
    }
}

public enum SkillPortQuestions {
    /// One choice point: what in the texts raises it, and its question for that evidence.
    struct Detector: Sendable {
        let id: String
        /// The tokens found (empty: no question).
        let detect: @Sendable (_ texts: [String]) -> [String]
        let make: @Sendable (_ evidence: [String], _ skill: String) -> SkillPortQuestion
    }

    static func found(_ pattern: String, in texts: [String]) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return texts.contains { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }

    static func tokens(_ pattern: String, in texts: [String]) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result = Set<String>()
        for text in texts {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: text) { result.insert(String(text[range])) }
            }
        }
        return result.sorted()
    }

    static let detectors: [Detector] = [
        Detector(id: "subagents", detect: { texts in
            tokens(#"subagent_type\s*[=:]\s*["']?(?:[\w-]+:)?([a-z][\w-]*)"#, in: texts) + (found(#"\bAgent\("#, in: texts) ? ["Agent("] : [])
        }) { found, _ in
            SkillPortQuestion(id: "subagents", question: "The skill starts subagents (\(found.joined(separator: ", "))). How should Pi run them?",
                              options: [.init(id: "inline", title: "Switch role inline with references/<role>.md"),
                                        .init(id: "pi-p", title: "Real subagent: pi -p via bash",
                                              rules: "note: Run each subagent as a real Pi process: bash `pi -p \"<the role prompt from references/<role>.md> + the task\"`, then read its answer. Not an inline role switch.")],
                              recommended: "inline", evidence: found)
        },
        Detector(id: "questions", detect: { texts in found("AskUserQuestion", in: texts) ? ["AskUserQuestion"] : [] }) { found, _ in
            SkillPortQuestion(id: "questions", question: "The skill asks the user with AskUserQuestion. What should Pi do?",
                              options: [.init(id: "text", title: "Ask a numbered text question, then stop the turn"),
                                        .init(id: "keep", title: "Keep it: my Pi has a questionnaire extension",
                                              rules: "allow: AskUserQuestion\nnote: Keep AskUserQuestion calls as they are: the user's Pi has a questionnaire extension.")],
                              recommended: "text", evidence: found)
        },
        Detector(id: "state", detect: { texts in
            ["TodoWrite", "TaskCreate", "state_write", "state_read", "notepad_", ".omc/"].filter { token in texts.contains { $0.contains(token) } }
        }) { found, skill in
            SkillPortQuestion(id: "state", question: "The skill keeps state or task lists (\(found.joined(separator: ", "))). Where should the files go?",
                              options: [.init(id: "skill-folder", title: ".pi/state/\(skill)/",
                                              rules: "re:\\.pi/state/(?!\(NSRegularExpression.escapedPattern(for: skill))/) => .pi/state/\(skill)/\nnote: Keep every state, checklist and notes file under .pi/state/\(skill)/."),
                                        .init(id: "flat", title: ".pi/state/", rules: "note: Keep state, checklist and notes files directly under .pi/state/.")],
                              recommended: "skill-folder", evidence: found)
        },
        Detector(id: "handoffs", detect: { texts in tokens(#"Skill\(\s*["']([^"']+)["']"#, in: texts) }) { found, _ in
            SkillPortQuestion(id: "handoffs", question: "The skill hands off to other skills (\(found.joined(separator: ", "))). What should Pi do?",
                              options: [.init(id: "tell-user", title: "Tell the user to run /skill:x"),
                                        .init(id: "drop", title: "Drop the handoffs",
                                              rules: "note: Drop handoffs to other skills (Skill(\"x\") calls and \"next run /skill:x\" steps): the skill ends at its own last step.")],
                              recommended: "tell-user", evidence: found)
        },
        Detector(id: "model-hints", detect: { texts in tokens(#"model\s*[=:]\s*["']?(opus|sonnet|haiku)\b"#, in: texts) }) { found, _ in
            SkillPortQuestion(id: "model-hints", question: "The skill names Claude models (\(found.joined(separator: ", "))). Keep them?",
                              options: [.init(id: "drop", title: "Drop them"),
                                        .init(id: "text", title: "Keep as plain advice",
                                              rules: "note: Keep model hints as plain advice in prose (\"a strong model suits this step\"), never as a model= parameter.")],
                              recommended: "drop", evidence: found)
        },
    ]

    /// The ids the detectors ask about.
    public static var builtInIDs: [String] { detectors.map(\.id) }

    /// The answer that asks for a change in the user's own words: `other:<text>`, which the
    /// model turns into rules.
    public static let otherPrefix = "other:"

    /// The choice points of a skill's texts (originals): one per catalog family the skill uses,
    /// then the Claude Code → Pi detectors, in table order.
    public static func analyze(_ texts: [String: String], skill: String, catalog: SkillPortCatalog = .bundled) -> [SkillPortQuestion] {
        let values = texts.keys.sorted().map { texts[$0]! }
        let families = catalog.found(in: values).map { found -> SkillPortQuestion in
            let family = found.family, members = found.members
            var options = [SkillPortQuestion.Option(id: "keep", title: "Keep \(members.map(\.title).joined(separator: " and "))")]
            for from in members {
                for to in family.members where !members.contains(to) {
                    options.append(.init(id: "\(from.id)-to-\(to.id)", title: "Switch \(from.title) to \(to.title)",
                                         rules: catalog.rules(family: family, from: from, to: to)))
                }
            }
            return SkillPortQuestion(id: family.id,
                                     question: "The skill uses \(members.map(\.title).joined(separator: ", ")) as its \(family.title). Keep it or switch?",
                                     options: options, recommended: "keep", evidence: members.map(\.id), family: family.id)
        }
        return families + detectors.compactMap { detector in
            let evidence = detector.detect(values)
            return evidence.isEmpty ? nil : detector.make(evidence, skill)
        }
    }

    /// The model's questions added to `known`: one whose id or family is asked already is left out.
    public static func merge(_ known: [SkillPortQuestion], _ more: [SkillPortQuestion]) -> [SkillPortQuestion] {
        var ids = Set(known.map(\.id))
        var families = Set(known.compactMap(\.family))
        return known + more.filter { question in
            guard !ids.contains(question.id), question.family.map({ !families.contains($0) }) ?? true else { return false }
            ids.insert(question.id)
            if let family = question.family { families.insert(family) }
            return true
        }
    }

    /// The rules the answers imply; a question without an answer takes its recommended option
    /// (listed in `defaulted`). An answer to no question, or naming no option, is an error.
    /// An `other:<text>` answer becomes a free change in `others` ("<question>: <text>"), which
    /// the model turns into rules (`SkillPortModel.rules(forChanges:)`). Each option's rules are
    /// labeled with "<id>: <option title>" for the report's groups.
    public static func rules(_ questions: [SkillPortQuestion], answers: [String: String]) throws
        -> (rules: SkillPortRules, chosen: [String: String], defaulted: [String], others: [String]) {
        for id in answers.keys where !questions.contains(where: { $0.id == id }) {
            throw SkillPortRules.Failure(message: "No question \(id) for this skill (questions: \(questions.map(\.id).joined(separator: ", "))).")
        }
        var rules = SkillPortRules()
        var chosen: [String: String] = [:]
        var defaulted: [String] = []
        var others: [String] = []
        for question in questions {
            let pick = answers[question.id] ?? question.recommended
            if answers[question.id] == nil { defaulted.append(question.id) }
            if pick.hasPrefix(otherPrefix) {
                let text = pick.dropFirst(otherPrefix.count).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { throw SkillPortRules.Failure(message: "\(question.id)=other: needs the change in words.") }
                others.append("\(question.question) → \(text)")
                chosen[question.id] = pick
                continue
            }
            guard let option = question.options.first(where: { $0.id == pick }) else {
                throw SkillPortRules.Failure(message: "\(question.id) has no option \(pick) (\(question.options.map(\.id).joined(separator: ", "))).")
            }
            rules = rules.merged(with: try SkillPortRules.parse(option.rules).labeled("\(question.id): \(option.title)"))
            chosen[question.id] = pick
        }
        rules.answers = chosen
        return (rules, chosen, defaulted, others)
    }
}
