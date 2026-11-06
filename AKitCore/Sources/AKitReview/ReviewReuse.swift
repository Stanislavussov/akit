import AKitFoundation
import Foundation

/// What a new run of a merge request reviewed before takes from the earlier run instead of asking
/// GitLab's MCP server again (2026-11-06, the user's request: no GitLab call for what can't change).
///
/// - The same head (git tells it after fetching the merge request's head) and the earlier run sent
///   nothing: no fetch pass, every answer of the earlier fetch pass is copied.
/// - Otherwise the fetch pass reads only the merge request, its versions, threads and drafts; the
///   work items, the signed-in user, earlier merge requests and links come from the earlier run.
/// - The impact pass: when every boundary of this run was searched for by the earlier one, its
///   uses and GitLab's answers are copied, and AKit checks them again as its own.
public enum ReviewReuse {
    /// `run.json` `gatherReused`: the run whose answers Gather took, and whether it took them all.
    public struct Gather: Codable, Sendable, Hashable {
        public var run: String
        /// true: no fetch pass ran (same head); false: the fetch pass read only what can change.
        public var whole: Bool
        /// The earlier run had the signed-in user, so this fetch pass doesn't read it.
        public var hasUser: Bool
        /// The earlier answers hold every work item the earlier run named, so this fetch pass
        /// doesn't read the tracker; nil in a whole copy.
        public var hasWorkItems: Bool? = nil
        /// Links the earlier fetch pass read: this one reads only the others.
        public var linksRead: [String]
        /// When GitLab gave the answers taken whole: the snapshot keeps this time, so a chain of
        /// runs never makes old answers look new.
        public var answered: Date? = nil
    }

    /// Answers taken whole are at most this old: a person may have published or changed drafts and
    /// threads in GitLab since, which no head shows.
    public static let maxWholeAge: TimeInterval = 24 * 60 * 60

    /// The newest earlier gathered run of the same merge request with the same tracker and the
    /// work items this run names: its fetch answers hold what this run would read.
    static func earlierGather(folder: URL, spec: ReviewRunSpec, home: URL) -> (id: String, folder: URL, spec: ReviewRunSpec)? {
        guard spec.local == nil else { return nil }
        let paths = ReviewPaths(home: home)
        for run in ReviewRuns.list(home: home) where run.id != folder.lastPathComponent && run.spec.created < spec.created {
            let other = run.spec
            guard other.local == nil, other.mergeRequest.url == spec.mergeRequest.url, other.headSHA != nil,
                  other.tracker == spec.tracker,
                  // Gather adds the item the branch names (a merge request's branch doesn't change); the ones
                  // given by hand must be among the earlier run's.
                  spec.workItems.allSatisfy(other.workItems.contains) else { continue }
            let earlier = paths.run(run.id)
            guard FileManager.default.fileExists(atPath: earlier.appending(path: "gitlab/snapshot.json").path),
                  !ReviewMCPData.calls(in: earlier, pass: "fetch").isEmpty else { continue }
            return (run.id, earlier, other)
        }
        return nil
    }

    /// Whether any run of this merge request wrote to GitLab (Send Drafts…) after `date`: drafts and
    /// threads answered before it are old. Any run, not only the source: a run that took its answers
    /// whole carries an older run's answers, and that older run may have sent since.
    static func sent(since date: Date, spec: ReviewRunSpec, home: URL) -> Bool {
        let paths = ReviewPaths(home: home)
        return ReviewRuns.list(home: home).contains { run in
            guard run.spec.local == nil, run.spec.mergeRequest.url == spec.mergeRequest.url else { return false }
            let log = paths.run(run.id).appending(path: "send/log.jsonl")
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            let modified = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            return modified >= date
        }
    }

    /// Whether one saved answer must be read again in a partial copy: anything of this merge
    /// request that a push or a comment changes (the merge request, its versions, diffs, threads,
    /// drafts), a failed call (it is tried again, its gap doesn't live on), and the model's own
    /// prose (`akit_submit_context`) without a link.
    static func isFresh(_ call: ReviewMCPCall, spec: ReviewRunSpec) -> Bool {
        let iid = spec.mergeRequest.iid
        if call.tool == "akit_submit_context" { return call.link == nil }
        if call.isError { return true }
        let data = ReviewMCPData.read([call], iid: iid, project: spec.mergeRequest.projectPath)
        return data.mergeRequest != nil || !data.versions.isEmpty || !data.diffs.isEmpty || !data.discussions.isEmpty || !data.drafts.isEmpty
    }

    /// Copies the earlier fetch pass's answers into this run (`all`: every one; else only those
    /// that can't change). Returns how many it copied.
    @discardableResult
    static func copyFetchCalls(from earlier: URL, to folder: URL, spec: ReviewRunSpec, all: Bool) throws -> Int {
        let target = folder.appending(path: "mcp/calls")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var copied = 0
        for file in FileWalk.children(of: earlier.appending(path: "mcp/calls")) where file.pathExtension == "json" {
            guard let call = ReviewJSON.read(ReviewMCPCall.self, from: file), call.pass == "fetch" else { continue }
            if !all && isFresh(call, spec: spec) { continue }
            // Its own name, after this run's answers (digits sort before letters): a new answer is
            // never overwritten and is read first.
            let name = file.lastPathComponent.hasPrefix("fetch-reused-") ? file.lastPathComponent
                : "fetch-reused-" + file.lastPathComponent.dropFirst("fetch-".count)
            let destination = target.appending(path: name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file, to: destination)
            copied += 1
        }
        return copied
    }

    /// What Gather takes from an earlier run. nil: nothing to take, the fetch pass reads everything.
    /// The copy is `copy(_:to:spec:home:)`: before Gather's sorting when whole, after the fetch pass
    /// otherwise (the pass starts with an empty `mcp/calls`).
    static func plan(folder: URL, spec: ReviewRunSpec, home: URL, now: Date = .now) -> Gather? {
        guard let earlier = earlierGather(folder: folder, spec: spec, home: home) else { return nil }
        let links = spec.links ?? []
        let earlierLinks = (earlier.spec.links ?? []).filter { !(earlier.spec.linksUnread ?? []).contains($0) }
        let head = spec.repository?.plan?.head
        let snapshot = ReviewJSON.read(ReviewSnapshot.self, from: earlier.folder.appending(path: "gitlab/snapshot.json"))
        let answered = snapshot?.gathered
        let recent = answered.map { now.timeIntervalSince($0) < maxWholeAge } ?? false
        // Full review: GitLab's answers are read again (the user may have changed drafts in GitLab).
        let whole = spec.fullReview != true && recent && head != nil && head == earlier.spec.headSHA
            && !sent(since: answered ?? .distantPast, spec: spec, home: home) && links.allSatisfy(earlierLinks.contains)
        if whole {
            return Gather(run: earlier.id, whole: true, hasUser: !(snapshot?.user ?? "").isEmpty, linksRead: earlierLinks, answered: answered)
        }
        // What a partial copy keeps: the user and the work items only when they are really there.
        let kept = ReviewMCPData.calls(in: earlier.folder, pass: "fetch").filter { !isFresh($0, spec: spec) }.filter(spec.access.answeredByBase)
        let data = ReviewMCPData.read(kept, iid: spec.mergeRequest.iid, project: spec.mergeRequest.projectPath)
        let items = Set(data.workItems.map(\.id))
        return Gather(run: earlier.id, whole: false, hasUser: data.user != nil, hasWorkItems: earlier.spec.workItems.allSatisfy(items.contains),
                      linksRead: earlierLinks)
    }

    /// Copies what `plan` took; a whole copy replaces every saved answer of this run.
    static func copy(_ reused: Gather, to folder: URL, spec: ReviewRunSpec, home: URL) throws {
        let earlier = ReviewPaths(home: home).run(reused.run)
        if reused.whole {
            // What the fetch pass would do first: no answer or block of an earlier Gather of this folder stays.
            try? FileManager.default.removeItem(at: folder.appending(path: "mcp/calls"))
            try? FileManager.default.removeItem(at: folder.appending(path: "mcp/blocked.jsonl"))
            let blocked = earlier.appending(path: "mcp/blocked.jsonl")
            if FileManager.default.fileExists(atPath: blocked.path) {
                try FileManager.default.createDirectory(at: folder.appending(path: "mcp"), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: blocked, to: folder.appending(path: "mcp/blocked.jsonl"))
            }
        }
        try copyFetchCalls(from: earlier, to: folder, spec: spec, all: reused.whole)
    }

    // MARK: - Impact

    /// The newest earlier run of this merge request whose impact pass searched for every boundary
    /// of this one (same kind and name, removed or not).
    static func earlierImpact(folder: URL, spec: ReviewRunSpec, boundaries: [ReviewBoundary], home: URL) -> (id: String, folder: URL, boundaries: [ReviewBoundary])? {
        guard spec.local == nil, !boundaries.isEmpty else { return nil }
        let paths = ReviewPaths(home: home)
        for run in ReviewRuns.list(home: home) where run.id != folder.lastPathComponent && run.spec.created < spec.created {
            guard run.spec.local == nil, run.spec.mergeRequest.url == spec.mergeRequest.url else { continue }
            let earlier = paths.run(run.id)
            guard let log = ReviewJSON.read(ReviewPassLog.self, from: earlier.appending(path: "passes.json")),
                  log.passes.contains(where: { $0.name == "impact" && $0.succeeded }),
                  let searched = ReviewJSON.read([ReviewBoundary].self, from: earlier.appending(path: "boundaries.json")),
                  FileManager.default.fileExists(atPath: earlier.appending(path: "passes/consumers.json").path) else { continue }
            let known = Set(searched.map(key))
            guard boundaries.allSatisfy({ known.contains(key($0)) }) else { return nil }
            return (run.id, earlier, searched)
        }
        return nil
    }

    static func key(_ boundary: ReviewBoundary) -> String {
        "\(boundary.kind.rawValue)\n\(boundary.name.lowercased())\n\(boundary.isRemoved)"
    }

    /// Copies the earlier impact pass's answers and its submitted uses, each use moved to this
    /// run's id of the same boundary (kind, name, removed), for `ReviewConsumers.check`.
    static func copyImpact(from earlier: URL, earlierBoundaries: [ReviewBoundary], boundaries: [ReviewBoundary], to folder: URL) throws {
        let target = folder.appending(path: "mcp/calls")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for file in FileWalk.children(of: earlier.appending(path: "mcp/calls")) where file.lastPathComponent.hasPrefix("impact-") {
            let destination = target.appending(path: file.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file, to: destination)
        }
        guard var object = FileWalk.jsonObject(earlier.appending(path: "passes/consumers.json")) else { return }
        let current = Dictionary(boundaries.map { (key($0), $0.id) }, uniquingKeysWith: { first, _ in first })
        func id(_ given: String) -> String? {
            let given = given.trimmingCharacters(in: .whitespacesAndNewlines)
            // The earlier pass named a use by its boundary's id, or by its name when it named the boundary itself.
            let earlier = earlierBoundaries.first { $0.id == given } ?? earlierBoundaries.first { $0.name.lowercased() == given.lowercased() }
            return earlier.flatMap { current[key($0)] }
        }
        object["consumers"] = (object["consumers"] as? [[String: Any]] ?? []).compactMap { item -> [String: Any]? in
            var item = item
            guard let given = item["boundary"] as? String, let mapped = id(given) else { return nil }
            item["boundary"] = mapped
            return item
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: folder.appending(path: "passes"), withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: "passes/consumers.json"))
    }
}
