import AKitFoundation
import Foundation

/// The sample base (K26): a separate base, by default of the world `sample`, with made-up content
/// that shows every feature built so far. `akit kb seed` and Add Sample Base… write it;
/// `akit kb seed --remove` and Remove Sample Base… move it to the Trash. `tools/demo-home.sh`
/// builds its demo base from the same content (`kb seed --world work`), so screenshots,
/// acceptances and the in-app sample show the same data.
///
/// Every step that adds a feature adds an example of it to `files` in the same commit, raises
/// `version`, and extends the seed test.
///
/// `.akit-seed.json` at the base root (committed) marks a base as a sample one: the seed version
/// and the files the seed wrote. Only such a base is updated or removed here. The seed's
/// proposals (`proposals`, 5.1) are written into `inbox/` after the commit and stay untracked, as
/// an agent's proposals do (P3): they are not in the marker, and a seed run writes only the
/// missing ones. A map proposal's draft (`mapDrafts`, 5.4) is written beside it.
public enum KnowledgeSeed {
    public typealias Failure = KnowledgeBase.Failure

    /// The seed's version: raised whenever `files` changes.
    public static let version = 11
    /// The world of the sample base unless one is named.
    public static let world = "sample"
    public static let markerName = ".akit-seed.json"
    /// Every seed commit starts with this.
    public static let commitPrefix = "Seed:"

    public struct Marker: Codable, Equatable, Sendable {
        public let seedVersion: Int
        public let files: [String]
    }

    public struct File: Sendable, Equatable {
        /// Base-relative.
        public let path: String
        public let text: String
    }

    public enum Status: String, Encodable, Sendable { case created, updated, unchanged }

    public struct Outcome: Sendable, Equatable {
        public let base: KnowledgeBase
        public let status: Status
        public let files: [String]
    }

    /// The marker of a sample base; nil for any other folder.
    public static func marker(of base: KnowledgeBase) -> Marker? {
        guard let data = FileWalk.head(of: base.root.appending(path: markerName), limit: 1 << 20) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    /// The sample bases of this Mac.
    public static func bases(home: URL) -> [KnowledgeBase] { KnowledgeBase.all(home: home).filter { marker(of: $0) != nil } }

    // MARK: - Seed

    /// Writes the sample base of `world` (the folder by the K25 rules: `bases.json`, else
    /// `~/.akit/local/knowledge/<world>`). A new world gets a new base and one seed commit. A
    /// sample base of an older seed is brought to this version (one commit) only when it has no
    /// changes of the user, committed or not; else it is refused ("Remove it first"). An empty
    /// base (only its first commit, no areas, as Settings → Knowledge → Choose… makes it) is
    /// seeded; any other base is refused.
    @discardableResult
    public static func seed(world: String = world, env: HarnessEnvironment, brainRoot: URL? = nil,
                            trash: (URL) throws -> URL? = Trash.move) async throws(Failure) -> Outcome {
        let home = env.homeDirectory
        let root = KnowledgeBase.root(world: world, home: home)
        let paths = files.map(\.path) + [markerName]
        var base = KnowledgeBase(root: root, world: world)
        var stale: [String] = []
        var status = Status.created
        if KnowledgeBase.isBase(root) {
            guard let old = marker(of: base) else {
                // A base just created for the world (Settings → Knowledge → Choose…) is still empty: seed it.
                let unchanged = (try? await refuseUserChanges(base, env: env, home: home)) != nil
                let fresh = unchanged && base.areas().isEmpty
                guard fresh else {
                    throw Failure(message: "\(FileWalk.tilde(root, home: home)) is a knowledge base of yours, not a sample one (it has no \(markerName)), so AKit doesn't seed it. Name another world with --world NAME.")
                }
                return try await write(base, status: .created, stale: [], env: env, trash: trash)
            }
            if old.seedVersion == version, isCurrent(base) {
                return Outcome(base: base, status: .unchanged, files: paths)
            }
            if old.seedVersion > version {
                throw Failure(message: "The sample base \(FileWalk.tilde(root, home: home)) is of a newer seed (v\(old.seedVersion)) than this akit knows (v\(version)). Update akit.")
            }
            try await refuseUserChanges(base, env: env, home: home)
            stale = old.files.filter { !paths.contains($0) && KnowledgeGit.isInside($0) }
            status = .updated
        } else {
            base = try await KnowledgeBase.create(world: world, env: env, brainRoot: brainRoot)
        }
        return try await write(base, status: status, stale: stale, env: env, trash: trash)
    }

    /// Writes every seed file and the marker, trashes the `stale` files of an older seed, and
    /// commits them all in one commit.
    private static func write(_ base: KnowledgeBase, status: Status, stale: [String], env: HarnessEnvironment,
                              trash: (URL) throws -> URL?) async throws(Failure) -> Outcome {
        let paths = files.map(\.path) + [markerName]
        let fm = FileManager.default
        do {
            for file in files {
                let url = base.root.appending(path: file.path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(file.text.utf8).write(to: url, options: .atomic)
            }
            for path in stale where fm.fileExists(atPath: base.root.appending(path: path).path) {
                _ = try trash(base.root.appending(path: path))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let marker = try encoder.encode(Marker(seedVersion: version, files: files.map(\.path))) + Data("\n".utf8)
            try marker.write(to: base.root.appending(path: markerName), options: .atomic)
        } catch {
            throw Failure(message: "Couldn't write the sample base in \(base.root.path): \(error.localizedDescription)")
        }
        // A base made before inbox/ was tracked gets its .gitkeep with the seed (P3).
        let keep = base.root.appending(path: KnowledgeInbox.keepFile)
        let addsKeep = !fm.fileExists(atPath: keep.path)
        if addsKeep {
            do {
                try fm.createDirectory(at: base.inboxFolder, withIntermediateDirectories: true)
                try Data().write(to: keep)
            } catch {
                throw Failure(message: "Couldn't write \(KnowledgeInbox.keepFile) in \(base.root.path): \(error.localizedDescription)")
            }
        }
        try await base.commit(paths + stale + (addsKeep ? [KnowledgeInbox.keepFile] : []), message: "\(commitPrefix) sample base v\(version)", env: env)
        writeProposals(base)
        return Outcome(base: base, status: status, files: paths)
    }

    /// Writes each seed proposal that isn't in `inbox/` yet, untracked (never committed), with its
    /// stored check marks when it has some.
    static func writeProposals(_ base: KnowledgeBase) {
        for proposal in proposals {
            let url = base.root.appending(path: proposal.path)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.createDirectory(at: base.inboxFolder, withIntermediateDirectories: true)
            if let draft = mapDrafts[proposal.id] {
                try? Data(draft.utf8).write(to: base.root.appending(path: KnowledgeInbox.draftPath(of: proposal.id)), options: .withoutOverwriting)
            }
            try? Data(proposal.text.utf8).write(to: url, options: .withoutOverwriting)
            // The check model's marks (5.2), made up: no model is called.
            if let marks = checkMarks[proposal.id], base.check(of: proposal) == nil {
                _ = try? base.saveCheck(marks, of: proposal, model: "Pi · opencode-go/gpt-6-luna · low",
                                        now: ISO8601DateFormatter().date(from: "2026-10-24T09:10:00Z") ?? .now)
            }
        }
    }

    /// Every seed file is on disk with the seed's text.
    static func isCurrent(_ base: KnowledgeBase) -> Bool {
        files.allSatisfy { file in
            (try? String(contentsOf: base.root.appending(path: file.path), encoding: .utf8)) == file.text
        }
    }

    /// Refuses a sample base the user changed: a commit not made by the seed or by `create`, or
    /// an uncommitted change (an in-app edit waiting in the queue too).
    static func refuseUserChanges(_ base: KnowledgeBase, env: HarnessEnvironment, home: URL) async throws(Failure) {
        let git = KnowledgeGit(base: base.root, env: env)
        let subjects: [String], status: String
        do {
            subjects = try await git.run(["log", "--format=%s"]).split(separator: "\n").map(String.init)
            status = try await git.run(["status", "--porcelain"])
        } catch {
            throw Failure(message: error.message)
        }
        let own = subjects.filter { !$0.hasPrefix(commitPrefix) && $0 != KnowledgeBase.createMessage }
        // Proposals waiting in inbox/ are untracked by design (P3), not changes of the user.
        let changed = status.split(separator: "\n").filter { !$0.hasPrefix("?? inbox/") }
        if !own.isEmpty || !changed.isEmpty {
            throw Failure(message: "The sample base \(FileWalk.tilde(base.root, home: home)) has changes of yours (\(own.isEmpty ? "not committed yet" : "\(own.count) commit\(own.count == 1 ? "" : "s")")), so AKit doesn't overwrite it. Remove it first: akit kb seed --remove.")
        }
    }

    // MARK: - Remove

    /// Moves a sample base's whole folder to the Trash and removes its world from `bases.json`
    /// when set there. Refused for a base without `.akit-seed.json`. Returns where it went.
    @discardableResult
    public static func remove(_ base: KnowledgeBase, home: URL, trash: (URL) throws -> URL? = Trash.move) throws(Failure) -> URL? {
        guard KnowledgeBase.isBase(base.root) else {
            throw Failure(message: "No knowledge base at \(FileWalk.tilde(base.root, home: home)).")
        }
        guard marker(of: base) != nil else {
            throw Failure(message: "\(FileWalk.tilde(base.root, home: home)) is not a sample base (it has no \(markerName)), so AKit doesn't remove it. Remove notes or areas with akit kb rm.")
        }
        let lock: FileLock?
        do { lock = try FileLock.acquire(base.root.appending(path: KnowledgeBase.queueLockName), timeout: 2) } catch {
            throw Failure(message: "Couldn't lock the base: \(error.localizedDescription); nothing was removed.")
        }
        guard let lock else { throw Failure(message: "Another AKit is committing in the base; nothing was removed. Try again in a moment.") }
        let place: URL?
        do { place = try trash(base.root) } catch {
            lock.release()
            throw Failure(message: "Couldn't move \(base.root.path) to the Trash: \(error.localizedDescription)")
        }
        lock.release()
        if let world = base.world, var set = try? KnowledgeBase.Folders.load(home: home), let path = set.url(of: world, home: home),
           KnowledgeBase(root: path) == base {
            set.bases[world] = nil
            try set.save(home: home)
        }
        return place
    }

    // MARK: - Content

    /// The made-up content: two unrelated areas (payments, logistics) with `area.yaml`, a note of
    /// every default kind of `kb.yaml` with its fields and `##` sections, `[[links]]` within an
    /// area and across areas, a flow note in each area, a map in each area (2.1), and the area
    /// lint-examples with one finding of each lint rule (4.1). Later steps add theirs here.
    public static let files: [File] = [
        // Area settings (1.3): payments has no projects, logistics has a remote and a glob.
        File(path: "areas/payments/area.yaml", text: """
            title: Payments
            description: Orders, billing and invoices.

            """),
        File(path: "areas/logistics/area.yaml", text: """
            title: Logistics
            description: Stock, picking and shipping.
            projects: [git@example.com:shop/warehouse.git, ~/Projects/shipping-*]

            """),
        // service: repo, path, files and sections; its repo is $HOME/Projects/orders-api in the demo home.
        File(path: "areas/payments/orders-api.md", text: """
            ---
            description: Takes orders from the shop and publishes order.created for billing.
            kind: service
            repo: git@example.com:shop/orders-api.git
            path: ~/Projects/orders-api
            files: [src/events/order-created.ts]
            ---
            # orders-api

            Takes orders from the shop and publishes `order.created` for [[billing]].

            ## Events

            - order created: sent once the order is saved; see [[order-to-billing]].
            - retry: a failed publish is retried three times, then the order waits in the outbox.

            ## Owners

            The checkout team.

            """),
        File(path: "areas/payments/billing.md", text: """
            ---
            description: Bills each order once, from the order.created event.
            kind: service
            repo: git@example.com:shop/billing.git
            owner: checkout-team
            ---
            # billing

            Bills each order once.

            ## Invoices

            An invoice is made from `order.created` and sent by email the same day.

            """),
        // flow, in a subfolder of its area.
        File(path: "areas/payments/flows/order-to-billing.md", text: """
            ---
            description: How an order becomes an invoice, from orders-api to billing.
            kind: flow
            ---
            # order-to-billing

            [[orders-api]] publishes the `order.created` event; [[billing]] reads it and makes the invoice.
            A duplicate event is ignored by its order id.

            """),
        // team: members (a list) and channel.
        File(path: "areas/payments/checkout-team.md", text: """
            ---
            description: The team that owns orders-api, billing and orders-db.
            kind: team
            members: [Ann Lee, Bo Chen]
            channel: checkout-help
            ---
            # checkout-team

            Owns [[orders-api]], [[billing]] and [[orders-db]].

            ## On call

            One person a week; the channel knows who.

            """),
        // database: repo and owner.
        File(path: "areas/payments/orders-db.md", text: """
            ---
            description: The database of orders-api - orders, their lines and the outbox.
            kind: database
            repo: git@example.com:shop/orders-db.git
            owner: checkout-team
            ---
            # orders-db

            The database of [[orders-api]]: orders, their lines and the outbox.

            ## Tables

            - orders: one row per order, with its total.
            - outbox: events that wait for [[order-events]].

            """),
        // queue: owner, and a link into another area (logistics/warehouse).
        File(path: "areas/payments/order-events.md", text: """
            ---
            description: The order.created topic, who writes it and who reads it.
            kind: queue
            owner: checkout-team
            ---
            # order-events

            The topic `order.created` goes through. [[orders-api]] writes it; [[billing]] and
            [[logistics/warehouse]] read it.

            """),
        // Search (3.2a): warehouse and shipping have sections about other things, so a word of
        // orders is rare enough in the base for BM25 to score a real match below the miss cutoff.
        File(path: "areas/logistics/warehouse.md", text: """
            ---
            description: Keeps the stock and reserves items for paid orders.
            kind: service
            repo: git@example.com:shop/warehouse.git
            ---
            # warehouse

            Keeps the stock and reserves items for paid orders.

            ## Stock

            Counted every night; a shelf below its minimum asks the supplier for more.

            ## Locations

            Two halls, north and south. Heavy items stay on the ground floor.

            ## Returns

            A returned item is checked, then put back on its shelf or thrown away.

            """),
        File(path: "areas/logistics/shipping.md", text: """
            ---
            description: Books the courier and tracks each parcel.
            kind: service
            ---
            # shipping

            Books the courier and tracks each parcel.

            ## Tracking

            Each parcel gets a tracking number; the status page asks the courier every hour.

            ## Labels

            Labels are printed in the south hall, one per parcel, with the address and a barcode.

            """),
        File(path: "areas/logistics/flows/pick-and-ship.md", text: """
            ---
            description: How a paid order is picked in the warehouse and shipped.
            kind: flow
            owner: logistics
            ---
            # pick-and-ship

            [[warehouse]] picks the items, then [[shipping]] books the courier.

            """),
        // external: url and owner.
        File(path: "areas/logistics/courier-api.md", text: """
            ---
            description: The courier's booking API that shipping calls.
            kind: external
            url: https://courier.example.com/api
            owner: logistics
            ---
            # courier-api

            The courier's booking API that [[shipping]] calls.

            ## Limits

            100 bookings a minute; more get an error and are tried again later.

            """),
        // Maps (2.1), 0.17.6-shaped: an arrow labelled "events" with a flow link and jumps between
        // the two areas' maps both ways (the unbound arrow is on lint-examples' map).
        File(path: "areas/payments/maps/overview.excalidraw", text: overviewMap),
        File(path: "areas/logistics/maps/routes.excalidraw", text: routesMap),
        // Lint (4.1): one finding of each rule, on purpose, in an area of its own; the rest of the
        // seed has none when the made-up repos are cloned (tools/demo-home.sh makes orders-api,
        // billing, orders-db and lint-examples in ~/Projects). missing-file needs the local copy of
        // lint-examples; without it, that note's repo is an unknown one instead. Its repo is one of
        // its own: a repo: of orders-api here would make lint-examples the focus of orders-api.
        File(path: "areas/lint-examples/area.yaml", text: """
            title: Lint examples
            description: One finding of each lint rule, on purpose. Open the Lint tab to see them.

            """),
        // broken-link, and ambiguous-link: [[status]] fits old/status and new/status.
        File(path: "areas/lint-examples/links.md", text: """
            ---
            description: A broken link and an ambiguous one, on purpose.
            ---
            # links

            A link to [[no-such-note]], which points nowhere, and one to [[status]], which fits two notes.

            """),
        File(path: "areas/lint-examples/old/status.md", text: """
            ---
            description: The old status page, one of two notes named status.
            ---
            # status

            The old status page.

            """),
        File(path: "areas/lint-examples/new/status.md", text: """
            ---
            description: The new status page, one of two notes named status.
            ---
            # status

            The new status page.

            """),
        // unknown-repo.
        File(path: "areas/lint-examples/unknown-repo.md", text: """
            ---
            description: A repo that no project of this Mac has, on purpose.
            kind: service
            repo: git@example.com:shop/no-such-repo.git
            ---
            # unknown-repo

            Its repo is no project this Mac knows.

            """),
        // missing-file: the local copy of lint-examples has no src/.
        File(path: "areas/lint-examples/missing-file.md", text: """
            ---
            description: A files entry the local copy lacks, on purpose.
            kind: service
            repo: git@example.com:shop/lint-examples.git
            files: [src/status-page.ts]
            ---
            # missing-file

            A file that the local copy of lint-examples doesn't have.

            """),
        // missing-home-path; a folder note (K27): a folder without git, like a local wiki.
        File(path: "areas/lint-examples/home-path.md", text: """
            ---
            description: A path folder that does not exist, on purpose.
            kind: folder
            path: ~/akit-lint-examples/wiki
            owner: checkout-team
            ---
            # home-path

            A path: folder that doesn't exist.

            """),
        // unknown-kind (a hint, K24).
        File(path: "areas/lint-examples/gadget.md", text: """
            ---
            description: A kind that kb.yaml does not list, on purpose.
            kind: gadget
            ---
            # gadget

            A kind that kb.yaml doesn't list.

            """),
        // missing-description: a note without the one line agents read first.
        File(path: "areas/lint-examples/no-description.md", text: """
            # no-description

            A note without a description: agents have to open it to find out what it is about.

            """),
        // block-without-note, unbound-arrow and unrelated-area (a hint, R-SEP); then map-parse.
        File(path: "areas/lint-examples/maps/examples.excalidraw", text: lintMap),
        File(path: "areas/lint-examples/maps/broken.excalidraw", text: """
            {"type": "excalidraw", "version": 2, "elements": [

            """),
        // The notebook (docs/design/notebook.md): two tabs, in their order; a day log with tasks,
        // a [[link]] to a note and a web link, and an image in notebook/assets/.
        File(path: "notebook/.tabs.json", text: """
            {
              "tabs" : [
                "Inbox",
                "Plans"
              ]
            }

            """),
        File(path: "notebook/Inbox.md", text: """
            ## 2026-10-25

            - [x] Answer the question about refunds in [[billing]]
            - [ ] Check why order-created events arrive twice
            - [ ] Read the retry policy: https://example.com/retries

            ![](assets/2026-10-25-deploy.svg)

            ## 2026-10-24

            - [x] Move the checkout team's meeting to Thursday
            - [x] Draw the order flow map

            """),
        File(path: "notebook/Plans.md", text: """
            # Plans

            ## This week

            - [ ] Split [[orders-api]] events by version
            - [ ] Ask logistics about the new warehouse

            ![](drawings/2026-10-24-retry.excalidraw.svg)

            ## Later

            | What | Who |
            | --- | --- |
            | Faster refunds | billing |
            | Track parcels live | shipping |

            """),
        // The work log (docs/design/worklog.md): two days, kinds, a break, a link.
        File(path: "worklog/2026-10-24.md", text: """
            - 09:05 #reply Answered logistics about the warehouse
            - 09:30 #agent Pi drew the order flow map
            - 11:10 #meeting Checkout team planning
            - 12:00 #break
            - 13:00 #task Order flow map: names and arrows
            - 15:20 #research Retry policy https://example.com/retries

            """),
        File(path: "worklog/2026-10-25.md", text: """
            - 08:50 #reply Refunds question in billing
            - 09:20 #bug order-created arrives twice
            - 10:40 #agent Review of COL-123 with Pi
            - 11:30 #review COL-124: two comments sent
            - 12:15 #break
            - 13:00 #bug order-created: duplicate key in the outbox
            - 16:30 #task Release notes

            """),
        // A drawing (NB10): its Excalidraw scene and the picture the tab shows.
        File(path: "notebook/drawings/2026-10-24-retry.excalidraw", text: retryDrawing),
        File(path: "notebook/drawings/2026-10-24-retry.excalidraw.svg", text: """
            <svg xmlns="http://www.w3.org/2000/svg" width="472" height="112" viewBox="0 0 472 112" font-family="Helvetica, Arial, sans-serif" font-size="16">
              <rect width="472" height="112" fill="#ffffff"/>
              <rect x="16" y="16" width="180" height="80" rx="4" fill="none" stroke="#1e1e1e" stroke-width="2"/>
              <text x="106" y="61" text-anchor="middle" fill="#1e1e1e">publish event</text>
              <rect x="276" y="16" width="180" height="80" rx="4" fill="none" stroke="#1e1e1e" stroke-width="2"/>
              <text x="366" y="61" text-anchor="middle" fill="#1e1e1e">retry 3 times</text>
              <line x1="197" y1="56" x2="268" y2="56" stroke="#1e1e1e" stroke-width="2"/>
              <path d="M266 50 L276 56 L266 62" fill="none" stroke="#1e1e1e" stroke-width="2"/>
              <text x="236" y="46" text-anchor="middle" fill="#1e1e1e" font-size="13">fails</text>
            </svg>

            """),
        File(path: "notebook/assets/2026-10-25-deploy.svg", text: """
            <svg xmlns="http://www.w3.org/2000/svg" width="520" height="120" viewBox="0 0 520 120" font-family="Helvetica, Arial, sans-serif" font-size="15">
              <rect x="10" y="30" width="140" height="60" rx="8" fill="#e7f0fd" stroke="#1971c2" stroke-width="2"/>
              <text x="80" y="65" text-anchor="middle" fill="#1d1d1f">orders-api</text>
              <rect x="370" y="30" width="140" height="60" rx="8" fill="#fdf0e7" stroke="#c2621a" stroke-width="2"/>
              <text x="440" y="65" text-anchor="middle" fill="#1d1d1f">billing</text>
              <line x1="150" y1="60" x2="362" y2="60" stroke="#495057" stroke-width="2"/>
              <path d="M362 54 L372 60 L362 66 Z" fill="#495057"/>
              <text x="260" y="50" text-anchor="middle" fill="#495057">order created (twice?)</text>
            </svg>

            """),
    ]

    /// The sample notebook's drawing: two blocks and an arrow, as AKit's canvas writes a scene.
    static let retryDrawing: String = {
        let publish = NewMap.Box(id: "publish", x: 0, y: 0), retry = NewMap.Box(id: "retry", x: 260, y: 0)
        return NewMap.scene(elements: NewMap.block(publish, label: "publish event", link: nil, arrows: ["fails"])
            + NewMap.block(retry, label: "retry 3 times", link: nil, arrows: ["fails"])
            + NewMap.arrow("fails", from: publish, to: retry, label: "fails", link: nil))
    }()

    /// The stored check of a seed proposal (5.2), as `kb check` would keep it.
    public static let checkMarks: [String: [KnowledgeCheck.Mark]] = [
        "2026-10-24-payments-billing": [
            .init(kind: .duplicate, note: "payments/flows/order-to-billing",
                  message: "order-to-billing already says what happens to the order; the Refunds section may only need the credit note."),
        ],
    ]

    /// The proposals waiting in the sample base's `inbox/` (5.1): a note proposal that adds a
    /// section to billing and sets a property, an arrow proposal for the logistics map, and a map
    /// drawn by an agent with excalidraw-cli (5.4), whose labels name payments' notes.
    public static let proposals: [KnowledgeProposal] = [
        KnowledgeProposal(id: "2026-10-24-payments-billing", kind: .note, target: "payments/billing",
                          reason: "Refunds were missing from the billing note.", created: "2026-10-24T09:00:00Z", author: "pi",
                          set: [.init(key: "sla", value: "next day")], body: """
            ## Refunds

            A refund makes a credit note for its invoice; the order stays as it was (see [[order-to-billing]]).

            """),
        KnowledgeProposal(id: "2026-10-24-arrow-billing-warehouse", kind: .arrow, target: "logistics/maps/routes",
                          reason: "The warehouse ships only paid orders.", created: "2026-10-24T09:05:00Z", author: "pi",
                          arrow: .init(from: "payments/billing", kind: "paid orders", to: "logistics/warehouse", map: "logistics/maps/routes")),
        KnowledgeProposal(id: "2026-10-24-payments-maps-order-flow", kind: .map, target: "payments/maps/order-flow",
                          reason: "Drawn from the code: orders-api sends its events to billing.", created: "2026-10-24T09:20:00Z", author: "pi",
                          body: "Blocks: orders-api, billing\nArrows: orders-api -events-> billing\n"),
    ]

    /// The drafts beside the seed's map proposals (`inbox/<id>.excalidraw`): the raw JSON draft
    /// `@swiftlysingh/excalidraw-cli` 1.5.0 wrote in spike 2.0 (its labels are free text, its
    /// blocks have no links), as `Fixtures/cli-draft.excalidraw` has it.
    public static let mapDrafts: [String: String] = ["2026-10-24-payments-maps-order-flow": cliDraft]

    static let cliDraft = #"""
        {
          "type": "excalidraw",
          "version": 2,
          "source": "https://github.com/swiftlysingh/excalidraw-cli",
          "elements": [
            {
              "id": "blk-orders",
              "type": "rectangle",
              "x": 62,
              "y": 62,
              "width": 140,
              "height": 60,
              "angle": 0,
              "strokeColor": "#1e1e1e",
              "backgroundColor": "transparent",
              "fillStyle": "solid",
              "strokeWidth": 2,
              "strokeStyle": "solid",
              "roughness": 1,
              "opacity": 100,
              "groupIds": [],
              "frameId": null,
              "index": "aa",
              "roundness": {
                "type": 3
              },
              "seed": 899707659,
              "version": 1,
              "versionNonce": 156847763,
              "isDeleted": false,
              "boundElements": [
                {
                  "id": "JIKhfxTmJq",
                  "type": "arrow"
                }
              ],
              "updated": 1792868594397,
              "link": null,
              "locked": false
            },
            {
              "id": "x_vUj3bWT_hVZrF6I5_rh",
              "type": "text",
              "x": 72,
              "y": 79.5,
              "width": 120,
              "height": 25,
              "angle": 0,
              "strokeColor": "#1e1e1e",
              "backgroundColor": "transparent",
              "fillStyle": "solid",
              "strokeWidth": 2,
              "strokeStyle": "solid",
              "roughness": 1,
              "opacity": 100,
              "groupIds": [],
              "frameId": null,
              "index": "ab",
              "roundness": null,
              "seed": 1254040401,
              "version": 1,
              "versionNonce": 1087908608,
              "isDeleted": false,
              "boundElements": null,
              "updated": 1792868594397,
              "link": null,
              "locked": false,
              "text": "orders-api",
              "fontSize": 20,
              "fontFamily": 5,
              "textAlign": "center",
              "verticalAlign": "middle",
              "containerId": null,
              "originalText": "orders-api",
              "autoResize": true,
              "lineHeight": 1.25
            },
            {
              "id": "blk-billing",
              "type": "rectangle",
              "x": 77,
              "y": 282,
              "width": 110,
              "height": 60,
              "angle": 0,
              "strokeColor": "#1e1e1e",
              "backgroundColor": "transparent",
              "fillStyle": "solid",
              "strokeWidth": 2,
              "strokeStyle": "solid",
              "roughness": 1,
              "opacity": 100,
              "groupIds": [],
              "frameId": null,
              "index": "ac",
              "roundness": {
                "type": 3
              },
              "seed": 1291096397,
              "version": 1,
              "versionNonce": 537101864,
              "isDeleted": false,
              "boundElements": [
                {
                  "id": "JIKhfxTmJq",
                  "type": "arrow"
                }
              ],
              "updated": 1792868594397,
              "link": null,
              "locked": false
            },
            {
              "id": "iK21udhzNSzNSEH1W3nr-",
              "type": "text",
              "x": 90,
              "y": 299.5,
              "width": 84,
              "height": 25,
              "angle": 0,
              "strokeColor": "#1e1e1e",
              "backgroundColor": "transparent",
              "fillStyle": "solid",
              "strokeWidth": 2,
              "strokeStyle": "solid",
              "roughness": 1,
              "opacity": 100,
              "groupIds": [],
              "frameId": null,
              "index": "ad",
              "roundness": null,
              "seed": 1138106397,
              "version": 1,
              "versionNonce": 177342787,
              "isDeleted": false,
              "boundElements": null,
              "updated": 1792868594397,
              "link": null,
              "locked": false,
              "text": "billing",
              "fontSize": 20,
              "fontFamily": 5,
              "textAlign": "center",
              "verticalAlign": "middle",
              "containerId": null,
              "originalText": "billing",
              "autoResize": true,
              "lineHeight": 1.25
            },
            {
              "id": "JIKhfxTmJq",
              "type": "arrow",
              "x": 132,
              "y": 122,
              "width": 0,
              "height": 160,
              "angle": 0,
              "strokeColor": "#1e1e1e",
              "backgroundColor": "transparent",
              "fillStyle": "solid",
              "strokeWidth": 2,
              "strokeStyle": "solid",
              "roughness": 1,
              "opacity": 100,
              "groupIds": [],
              "frameId": null,
              "index": "ae",
              "roundness": {
                "type": 2
              },
              "seed": 1221410067,
              "version": 1,
              "versionNonce": 1881358234,
              "isDeleted": false,
              "boundElements": [
                {
                  "id": "text-JIKhfxTmJq",
                  "type": "text"
                }
              ],
              "updated": 1792868594397,
              "link": null,
              "locked": false,
              "points": [
                [
                  0,
                  0
                ],
                [
                  0,
                  160
                ]
              ],
              "lastCommittedPoint": null,
              "startBinding": {
                "elementId": "blk-orders",
                "mode": "orbit",
                "fixedPoint": [
                  0.5,
                  1
                ]
              },
              "endBinding": {
                "elementId": "blk-billing",
                "mode": "orbit",
                "fixedPoint": [
                  0.5,
                  0
                ]
              },
              "startArrowhead": null,
              "endArrowhead": "arrow",
              "elbowed": false
            },
            {
              "id": "text-JIKhfxTmJq",
              "type": "text",
              "x": 96,
              "y": 189.5,
              "width": 72,
              "height": 25,
              "angle": 0,
              "strokeColor": "#1e1e1e",
              "backgroundColor": "transparent",
              "fillStyle": "solid",
              "strokeWidth": 2,
              "strokeStyle": "solid",
              "roughness": 1,
              "opacity": 100,
              "groupIds": [],
              "frameId": null,
              "index": "af",
              "roundness": null,
              "seed": 899262178,
              "version": 1,
              "versionNonce": 1310891759,
              "isDeleted": false,
              "boundElements": null,
              "updated": 1792868594397,
              "link": null,
              "locked": false,
              "text": "events",
              "fontSize": 20,
              "fontFamily": 5,
              "textAlign": "center",
              "verticalAlign": "middle",
              "containerId": "JIKhfxTmJq",
              "originalText": "events",
              "autoResize": true,
              "lineHeight": 1.25
            }
          ],
          "appState": {
            "gridSize": 20,
            "gridStep": 5,
            "gridModeEnabled": false,
            "viewBackgroundColor": "#ffffff",
            "lockedMultiSelections": {}
          },
          "files": {}
        }
        """#

    /// payments/maps/overview: orders-api → billing "events" (flow order-to-billing), and a block
    /// that jumps to logistics/maps/routes.
    static let overviewMap: String = {
        let orders = NewMap.Box(id: "blk-orders", x: 0, y: 0), billing = NewMap.Box(id: "blk-billing", x: 420, y: 0)
        let routes = NewMap.Box(id: "blk-routes", x: 420, y: 200)
        return NewMap.scene(elements: NewMap.block(orders, label: "orders-api", link: "[[orders-api]]", arrows: ["arr-events"])
            + NewMap.block(billing, label: "billing", link: "[[billing]]", arrows: ["arr-events"])
            + NewMap.arrow("arr-events", from: orders, to: billing, label: "events", link: "[[order-to-billing]]")
            + NewMap.block(routes, label: "logistics routes", link: "[[logistics/maps/routes]]"))
    }()

    /// logistics/maps/routes: warehouse → shipping "ships to" (flow pick-and-ship) and a block that
    /// jumps back to payments/maps/overview.
    static let routesMap: String = {
        let warehouse = NewMap.Box(id: "blk-warehouse", x: 0, y: 0), shipping = NewMap.Box(id: "blk-shipping", x: 420, y: 0)
        let overview = NewMap.Box(id: "blk-overview", x: 420, y: 200)
        return NewMap.scene(elements: NewMap.block(warehouse, label: "warehouse", link: "[[warehouse]]", arrows: ["arr-ships"])
            + NewMap.block(shipping, label: "shipping", link: "[[shipping]]", arrows: ["arr-ships"])
            + NewMap.arrow("arr-ships", from: warehouse, to: shipping, label: "ships to", link: "[[pick-and-ship]]")
            + NewMap.block(overview, label: "payments overview", link: "[[payments/maps/overview]]"))
    }()

    /// lint-examples/maps/examples: a block with a label and no link, a block for a note of
    /// logistics (an area no map of lint-examples jumps to or from), and an arrow bound at
    /// neither end (the unbound arrow of 2.1).
    static let lintMap: String = {
        let draft = NewMap.Box(id: "blk-draft", x: 0, y: 0), courier = NewMap.Box(id: "blk-courier", x: 420, y: 0)
        return NewMap.scene(elements: NewMap.block(draft, label: "draft", link: nil)
            + NewMap.block(courier, label: "courier-api", link: "[[logistics/courier-api]]")
            + NewMap.arrow("arr-loose", start: (0.5, 220), end: (200.5, 220)))
    }()
}
