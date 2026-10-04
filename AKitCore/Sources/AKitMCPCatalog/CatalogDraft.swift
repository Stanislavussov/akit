import AKitMCP
import Foundation

/// Turns a catalog option into the Add Server form.
public enum CatalogDraft {
    /// The form for one option. Required parameters are always in it; an optional one is in it
    /// when `included` names it. Secret values stay empty: the user types them into the form.
    public static func draft(of option: CatalogOption, name: String, including included: Set<CatalogParameter.ID> = []) -> MCPDraft {
        let chosen = parameters(of: option, including: included)
        func values(_ place: CatalogParameter.Place) -> [MCPDraft.Value] {
            chosen.filter { $0.place == place }.map { parameter in
                MCPDraft.Value(key: parameter.name,
                               value: parameter.isSecret ? "" : parameter.template ?? parameter.defaultValue ?? "",
                               isSecret: parameter.isSecret)
            }
        }
        switch option.kind {
        case .remote:
            return MCPDraft(name: name, transport: option.transport == .sse ? .sse : .http, url: url(of: option), headers: values(.header))
        case .package:
            let environment = values(.environment)
            // Docker hands a variable to the container only when an `-e NAME` argument names it.
            let flags = option.passesEnvironmentByFlag
                ? environment.filter { $0.key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }
                    .flatMap { ["-e", $0.key] }
                : []
            return MCPDraft(name: name, transport: .stdio, command: option.command,
                            arguments: option.leadingArguments + flags + option.trailingArguments, environment: environment)
        }
    }

    /// One line per parameter of the form, saying what to type there.
    public static func notes(for option: CatalogOption, including included: Set<CatalogParameter.ID> = []) -> [String] {
        var notes = option.cautions
        if option.passesEnvironmentByFlag {
            notes.append("The container gets a variable only through an “-e NAME” argument: when you add or remove a variable, change Arguments too.")
        }
        return notes + parameters(of: option, including: included).map { parameter in
            var line = switch parameter.place {
            case .url: isWholePlaceholder(option.url) ? "URL: type the address of your own server" : "{\(parameter.name)} in the URL"
            case .header: "Header \(parameter.name)"
            case .environment: parameter.name
            }
            if let template = parameter.template {
                // `Bearer {token}` → `Bearer <token>`: what the whole value looks like.
                line += ": type " + template.replacingOccurrences(of: "{", with: "<").replacingOccurrences(of: "}", with: ">")
            }
            if !parameter.choices.isEmpty { line += ": one of " + parameter.choices.joined(separator: ", ") }
            let details = parameter.details.trimmingCharacters(in: .whitespacesAndNewlines)
            if !details.isEmpty { line += ". " + details }
            // A value the catalog put into the form is named, so it can't slip in unseen.
            if parameter.template == nil, let value = prefilled(parameter) { line += " Prefilled by the catalog: \(value)" }
            return line
        }
    }

    /// What a form filled from the catalog still lacks; these block Preview. Empty = complete.
    public static func problems(in draft: MCPDraft) -> [String] {
        var result: [String] = []
        func check(_ text: String, _ place: String) {
            for name in placeholders(in: text) { result.append("Replace {\(name)} in \(place).") }
        }
        if draft.transport == .stdio {
            draft.arguments.forEach { check($0, "Arguments") }
        } else {
            check(draft.url, "the URL")
        }
        for value in draft.activeValues where !value.isSecret {
            let key = value.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if value.value.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append("\(key) needs a value (or remove it).")
            } else {
                check(value.value, key)
            }
        }
        return result
    }

    /// The value the catalog puts into the form for a parameter; nil for secrets and empty fields.
    public static func prefilled(_ parameter: CatalogParameter) -> String? {
        guard !parameter.isSecret, let value = parameter.template ?? parameter.defaultValue, !value.isEmpty else { return nil }
        return value
    }

    /// The URL the form gets: the entry's URL with the catalog's own values put in.
    public static func url(of option: CatalogOption) -> String {
        var url = option.url
        for parameter in option.parameters where parameter.place == .url {
            if let value = parameter.defaultValue { url = url.replacingOccurrences(of: "{\(parameter.name)}", with: value) }
        }
        // Nothing but a placeholder: an empty field, which the form asks for by itself.
        return isWholePlaceholder(url) ? "" : url
    }

    /// A `{word}` for the user to replace, from a hint of any shape (`/path/to/dir`, `--dir`).
    static func placeholder(_ hint: String) -> String {
        let cleaned = String(hint.map { "{}:\"$".contains($0) || $0.isNewline ? "_" : $0 })
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        // `placeholders(in:)` wants a letter; a hint without one (`123`) gets a word.
        return "{\(cleaned.contains { $0.isASCII && $0.isLetter } ? cleaned : "value")}"
    }

    /// The text is one `{name}` and nothing else.
    static func isWholePlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return placeholders(in: trimmed).count == 1 && trimmed.hasPrefix("{") && trimmed.hasSuffix("}")
            && trimmed.dropFirst().dropLast().allSatisfy { $0 != "{" && $0 != "}" }
    }

    /// Names of `{name}` parts. `${VAR}` and `{env:VAR}` are references, not placeholders; neither is JSON.
    static func placeholders(in text: String) -> [String] {
        // At least one letter inside: `{0}` and `{ }` are text, not something to fill in.
        let pattern = try! NSRegularExpression(pattern: #"(?<!\$)\{([^{}:"$]*[A-Za-z][^{}:"$]*)\}"#)
        let range = NSRange(text.startIndex..., in: text)
        var names: [String] = []
        for match in pattern.matches(in: text, range: range) {
            guard let inner = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[inner])
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    private static func parameters(of option: CatalogOption, including included: Set<CatalogParameter.ID>) -> [CatalogParameter] {
        option.parameters.filter { $0.isRequired || $0.place == .url || included.contains($0.id) }
    }
}
