import Foundation

/// Tests declared in a Swift test file: Swift Testing `@Test func name(` inside a type,
/// and XCTest `func testName(` in an `XCTestCase` class.
public struct TestName: Codable, Sendable, Hashable, Comparable {
    /// The enclosing type; nil for a Swift Testing test at file level.
    public var suite: String?
    public var name: String
    /// An XCTest method, not a Swift Testing function.
    public var xctest: Bool

    public init(suite: String?, name: String, xctest: Bool = false) {
        self.suite = suite
        self.name = name
        self.xctest = xctest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        suite = try container.decodeIfPresent(String.self, forKey: .suite)
        name = try container.decode(String.self, forKey: .name)
        xctest = try container.decodeIfPresent(Bool.self, forKey: .xctest) ?? false
    }

    /// "Suite/name", as `swift test` lists it without the module.
    public var id: String { suite.map { "\($0)/\(name)" } ?? name }

    /// A `swift test --filter` regular expression for this one test. Swift Testing ids end
    /// in the parameter list (`Module.Suite/name()`), XCTest ids don't (`Module.Class/testName`).
    public var filter: String {
        let name = NSRegularExpression.escapedPattern(for: self.name)
        guard let suite else { return "\\.\(name)\\(" }
        let prefix = "(^|[./])\(NSRegularExpression.escapedPattern(for: suite))/\(name)"
        return xctest ? prefix + "$" : prefix + "\\("
    }

    public static func < (a: TestName, b: TestName) -> Bool { a.id < b.id }
}

enum TestNames {
    /// Reads declarations line by line with a stack of the types being declared. Good enough
    /// for test files; not a Swift parser (multi-line strings with braces can confuse it).
    static func parse(_ source: String) -> [TestName] {
        var tests: [TestName] = []
        var types: [(name: String, depth: Int, xctest: Bool)] = []
        /// XCTest classes seen so far, so their extensions later in the file count too.
        var xctestClasses = Set<String>()
        var depth = 0
        var pendingTest = false
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            // String contents out first (they may hold braces or `//`), then the comment.
            let code = String(rawLine).replacing(/"(?:[^"\\]|\\.)*"/, with: "\"\"")
            let line = code.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if let match = line.firstMatch(of: /\b(?:struct|class|enum|actor|extension)\s+([A-Za-z_][A-Za-z0-9_.]*)([^{]*)/) {
                let name = String(match.1).split(separator: ".").last.map(String.init) ?? String(match.1)
                let inherits = String(match.2)
                let xctest = inherits.contains("XCTestCase") || (line.contains("extension") && xctestClasses.contains(name))
                if xctest { xctestClasses.insert(name) }
                types.append((name, depth, xctest))
            }
            if line.contains("@Test") { pendingTest = true }
            if let match = line.firstMatch(of: /\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/) {
                let name = String(match.1)
                let suite = types.last.flatMap { $0.depth < depth ? $0.name : nil }
                if pendingTest {
                    tests.append(TestName(suite: suite, name: name))
                } else if name.hasPrefix("test"), let type = types.last, type.xctest, type.depth < depth {
                    tests.append(TestName(suite: type.name, name: name, xctest: true))
                }
                pendingTest = false
            }
            for character in line {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    while let last = types.last, last.depth >= depth { types.removeLast() }
                }
            }
        }
        var seen = Set<TestName>()
        return tests.filter { seen.insert($0).inserted }
    }

    /// Test sources: Swift files in a test folder (`Tests/`, `AKitLabTests/`…). A name alone
    /// isn't enough: `Sources/X/SwiftTests.swift` is code the agent may change.
    static func isTestFile(_ path: String) -> Bool {
        path.hasSuffix(".swift") && path.split(separator: "/").dropLast().contains { $0.hasSuffix("Tests") || $0 == "Tests" }
    }
}
