import AKitFoundation
import AppKit
import Observation

/// Developer shortcut (⌘⇧R): rebuild AKit from the source folder it was built from and
/// start the new build. The Update button does the same with `make install` when this copy is
/// the installed one. If the build fails, the running app stays open and shows why.
@MainActor
@Observable
final class SelfRebuild {
    enum State: Equatable {
        case idle
        case building
        case failed(String)
    }

    /// What a build makes: `make build` (a Debug app in the source folder's build/) or
    /// `make install` (the app in ~/Applications and the akit command).
    enum Target: Equatable {
        case build, install
    }

    private(set) var state: State = .idle
    /// The target of the last build, for the progress note and the error alert.
    private(set) var target: Target = .build

    /// The repository this binary was compiled from (known at compile time).
    /// nil when it no longer has a Makefile, e.g. the app was copied elsewhere.
    nonisolated static let sourceRoot: URL? = {
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

    /// Where `make install` puts the app.
    private static var installedApp: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/AKit.app")
    }

    /// The target that replaces this copy: `make install` for the installed app, else `make build`.
    static var updateTarget: Target {
        Bundle.main.bundleURL.standardizedFileURL.path == installedApp.standardizedFileURL.path ? .install : .build
    }

    func dismissError() {
        if case .failed = state { state = .idle }
    }

    func rebuildAndRelaunch(_ target: Target = .build) async {
        guard let root = Self.sourceRoot, state != .building else { return }
        self.target = target
        state = .building
        let env = HarnessEnvironment.current
        var childEnv = env.variables
        childEnv["PATH"] = env.pathForChildProcesses // xcodegen lives in Homebrew
        // xcodegen stops with "Couldn't find current username" without these.
        childEnv["USER"] = childEnv["USER"] ?? NSUserName()
        childEnv["LOGNAME"] = childEnv["LOGNAME"] ?? NSUserName()
        // The build stamp runs `git status`: without this its index.lock can make an agent's
        // commit in the same folder fail.
        childEnv["GIT_OPTIONAL_LOCKS"] = "0"
        let command = target == .install ? "install" : "build"
        // A release build of the app and of the akit command takes longer than a Debug build.
        let minutes = target == .install ? 30 : 15
        let result = await ProcessRunner.run(URL(filePath: "/usr/bin/make"), arguments: [command], directory: root,
                                             environment: childEnv, timeout: TimeInterval(minutes * 60))
        guard let result, result.succeeded else {
            let output = result?.output.split(whereSeparator: \.isNewline).suffix(20).joined(separator: "\n") ?? ""
            var reason = result?.timedOut == true ? "The build took longer than \(minutes) minutes." : "make \(command) failed."
            // make install copies the app before it builds the akit command.
            if target == .install { reason += " The new app may be in ~/Applications already: quit AKit and open it again to check." }
            state = .failed(output.isEmpty ? reason : "\(reason)\n\n\(output)")
            if Self.requestedAtLaunch { FileHandle.standardError.write(Data("rebuild: \(reason)\n\(output)\n".utf8)) }
            return
        }
        // The new instance must not start while note and map edits wait for their commit (U2); an
        // open map hands over its last change first (N5).
        await KnowledgeModel.within(seconds: 5) { await KnowledgeModel.flushBeforeQuit() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        do {
            let app = target == .install ? Self.installedApp : Self.builtApp(in: root)
            try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            // From the run loop, not from this main-actor job: terminate waits in a nested event loop
            // for the quit flush (AppDelegate), which needs the main actor; called here, it hangs.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        } catch {
            state = .failed("Built, but the new version couldn't be started: \(error.localizedDescription)")
        }
    }
}
