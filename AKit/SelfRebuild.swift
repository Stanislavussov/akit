import AKitCore
import AppKit
import Observation

/// Developer shortcut (⌘⇧R): rebuild AKit from the source folder it was built from and
/// start the new build. If the build fails, the running app stays open and shows why.
@MainActor
@Observable
final class SelfRebuild {
    enum State: Equatable {
        case idle
        case building
        case failed(String)
    }

    private(set) var state: State = .idle

    /// The repository this binary was compiled from (known at compile time).
    /// nil when it no longer has a Makefile, e.g. the app was copied elsewhere.
    static let sourceRoot: URL? = {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appending(path: "Makefile").path) ? root : nil
    }()

    var isAvailable: Bool { Self.sourceRoot != nil }

    /// `AKit --rebuild`: do the same as ⌘⇧R right after launch (for scripts and checks).
    static let requestedAtLaunch = ProcessInfo.processInfo.arguments.contains("--rebuild")

    /// Where `make build` puts the app (DERIVED = build in the Makefile).
    private static func builtApp(in root: URL) -> URL {
        root.appending(path: "build/Build/Products/Debug/AKit.app")
    }

    func dismissError() {
        if case .failed = state { state = .idle }
    }

    func rebuildAndRelaunch() async {
        guard let root = Self.sourceRoot, state != .building else { return }
        state = .building
        let env = HarnessEnvironment.current
        var childEnv = env.variables
        childEnv["PATH"] = env.pathForChildProcesses // xcodegen lives in Homebrew
        // xcodegen stops with "Couldn't find current username" without these.
        childEnv["USER"] = childEnv["USER"] ?? NSUserName()
        childEnv["LOGNAME"] = childEnv["LOGNAME"] ?? NSUserName()
        let result = await ProcessRunner.run(URL(filePath: "/usr/bin/make"), arguments: ["build"], directory: root,
                                             environment: childEnv, timeout: 900)
        guard let result, result.succeeded else {
            let output = result?.output.split(whereSeparator: \.isNewline).suffix(20).joined(separator: "\n") ?? ""
            let reason = result?.timedOut == true ? "The build took longer than 15 minutes." : "make build failed."
            state = .failed(output.isEmpty ? reason : "\(reason)\n\n\(output)")
            if Self.requestedAtLaunch { FileHandle.standardError.write(Data("rebuild: \(reason)\n\(output)\n".utf8)) }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        do {
            try await NSWorkspace.shared.openApplication(at: Self.builtApp(in: root), configuration: configuration)
            NSApp.terminate(nil)
        } catch {
            state = .failed("Built, but the new version couldn't be started: \(error.localizedDescription)")
        }
    }
}
