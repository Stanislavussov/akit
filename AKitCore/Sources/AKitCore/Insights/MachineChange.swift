import Foundation

/// Switching this Mac between work and personal. It lives with Insights because it reads the
/// own keys from the session index and the usage summaries this Mac published in the brain.
extension MachineProfile {
    /// Saves a new role for this Mac and says what that means. The home record follows
    /// the Mac: from the brain it is copied into the local store (a copy: the brain's one is
    /// history, maybe pushed already), inside the local store it is renamed, so
    /// `akit apply --home` still knows which files it wrote.
    /// The id, pseudonym and hardware hash carry over from the old profile (the caller builds a
    /// new one from kind and name); `kindSince` moves when the kind changes. `ownKeys` nil: read from the index.
    public static func change(to newProfile: MachineProfile, brain brainRoot: URL, home: URL,
                              hostName: String = ProcessInfo.processInfo.hostName,
                              hardware: String? = currentHardwareHash(), ownKeys: OwnKeys? = nil,
                              now: Date = Date()) throws -> [String] {
        let old = load(home: home)
        var profile = newProfile
        profile.clearProblem()
        if old.problem == nil {
            profile.id = profile.id ?? old.id
            profile.pseudonym = profile.pseudonym ?? old.pseudonym
            profile.hardwareHash = profile.hardwareHash ?? old.hardwareHash
            profile.idSince = profile.idSince ?? old.idSince
            profile.kindSince = old.kind == profile.kind ? profile.kindSince ?? old.kindSince : now
        } else {
            // What the broken file said is unknown: count the summary days from today on.
            profile.kindSince = now
        }
        _ = profile.identify(hardware: hardware, own: ownKeys ?? UsageSummary.ownKeys(home: home), now: now)
        // A broken file says nothing about where records were kept; assume the brain, as before the file.
        let oldStore = old.problem == nil ? ProjectStore.current(brain: brainRoot, home: home, machine: old) : .brain(brainRoot)
        let oldHome = ProjectRecords.homeID(hostName: hostName, machineName: old.homeName)
        try profile.save(home: home)
        let newHome = ProjectRecords.homeID(hostName: hostName, machineName: profile.homeName)
        let local = ProjectStore.local(home: home)

        guard profile.isWork else {
            var notes = ["Personal Mac: from now on project ids, answers and locks are committed in the brain and reach its remote on the next sync."]
            if old.isWork { notes.append("Records kept on this Mac stay in \(local.root.path); AKit no longer reads them.") }
            return notes
        }
        var notes = ["Work Mac: answers and locks of projects stay in \(local.root.path); the brain gets nothing about them."]
        let fm = FileManager.default
        let from = oldStore.folder(id: oldHome), to = local.folder(id: newHome)
        if from != to, fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if oldStore.isLocal {
                    try fm.moveItem(at: from, to: to)
                    notes.append("Renamed this Mac's home record from \(oldHome) to \(newHome).")
                } else {
                    try fm.copyItem(at: from, to: to)
                    notes.append("Copied this Mac's home record (projects/\(oldHome)) to the local folder.")
                }
            } catch {
                notes.append("Couldn't move this Mac's home record to \(to.path): \(error.localizedDescription). akit apply --home will treat its files as not written by AKit.")
            }
        }
        if !oldStore.isLocal {
            let earlier = BrainRemove.savedAnswers(in: .brain(brainRoot)).map(\.id)
            if !earlier.isEmpty {
                notes.append("""
                    The brain still has records saved before (by any Mac): \(earlier.joined(separator: ", ")). \
                    AKit reads them here when this Mac has none of its own, but never writes them. \
                    Remove work ones before the next sync: git -C \(brainRoot.path) rm -r projects/<id>, then commit. \
                    Ones already pushed stay in the remote's history.
                    """)
            }
        }
        if let id = profile.id {
            let published = UsageSummary.projectFiles(of: id, in: .brain(brainRoot))
            if !published.isEmpty {
                notes.append("""
                    The brain has usage summaries this Mac published while personal; they name projects: \
                    \(published.joined(separator: ", ")). Remove work ones before the next sync: \
                    git -C \(brainRoot.path) rm <file>, then commit. Ones already pushed stay in the remote's history.
                    """)
            }
        }
        if !hasOwnGitIdentity(brainRoot) {
            notes.append("""
                Skill and layer commits made on this Mac carry your global git name and email, which may be your work \
                ones. Give the brain its own: git -C \(brainRoot.path) config user.email <personal email> \
                (and user.name).
                """)
        }
        return notes
    }

    /// The brain repo sets `user.email` in its own `.git/config`.
    static func hasOwnGitIdentity(_ brainRoot: URL) -> Bool {
        guard let text = try? String(contentsOf: brainRoot.appending(path: ".git/config"), encoding: .utf8) else { return true }
        var inUser = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inUser = line.lowercased() == "[user]" }
            else if inUser, line.lowercased().hasPrefix("email") { return true }
        }
        return false
    }
}
