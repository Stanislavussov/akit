import Foundation

/// Check commands a step can pick (F14): the project's test, lint and build commands, found in
/// its build files. Only commands that pass F19's rules (`FlowCheck.isSafeCommand`).
public enum FlowProjectCommands {
    public static func known(in project: URL?) -> [String] {
        guard let project else { return [] }
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: project.appending(path: name).path) }
        func text(_ name: String) -> String { (try? String(contentsOf: project.appending(path: name), encoding: .utf8)) ?? "" }
        var commands: [String] = []
        if has("Makefile") {
            let targets = text("Makefile").split(separator: "\n").compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix(".") else { return nil }
                let name = line[..<colon]
                return name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) && !name.isEmpty ? String(name) : nil
            }
            commands += ["test", "lint", "check", "build", "typecheck"].filter(targets.contains).map { "make \($0)" }
        }
        if has("package.json"),
           let json = try? JSONSerialization.jsonObject(with: Data(text("package.json").utf8)) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any] {
            commands += ["test", "lint", "typecheck", "build"].filter { scripts[$0] != nil }.map { $0 == "test" ? "npm test" : "npm run \($0)" }
        }
        if has("Package.swift") { commands += ["swift build", "swift test"] }
        if has("Cargo.toml") { commands += ["cargo test", "cargo clippy"] }
        if has("go.mod") { commands += ["go test ./...", "go vet ./..."] }
        if has("pyproject.toml") { commands += ["pytest"] }
        return commands.filter(FlowCheck.isSafeCommand)
    }
}
