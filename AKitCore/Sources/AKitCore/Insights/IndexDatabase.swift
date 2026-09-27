import Foundation
import SQLite3

/// A value read from or bound to SQLite.
enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    var int: Int? {
        switch self {
        case .int(let value): Int(value)
        case .double(let value): Int(value)
        default: nil
        }
    }

    var double: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

/// Swift values that bind to a statement parameter.
protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension SQLValue: SQLBindable { var sqlValue: SQLValue { self } }
extension Int: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { var sqlValue: SQLValue { .int(self) } }
extension UInt64: SQLBindable { var sqlValue: SQLValue { .int(Int64(bitPattern: self)) } }
extension Double: SQLBindable { var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    var sqlValue: SQLValue { map(\.sqlValue) ?? .null }
}

/// The local session index (`~/.akit/index/index.sqlite`) over the system SQLite.
/// WAL, so a reader never waits for the importer. Not Sendable: one task opens it,
/// uses it and lets it go.
final class IndexDatabase {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let url: URL
    private let handle: OpaquePointer
    /// Prepared statements by SQL text; the importer runs the same few thousands of times.
    private var statements: [String: OpaquePointer] = [:]

    init(url: URL) throws {
        self.url = url
        // Owner-only folder, so the -wal and -shm files SQLite creates next to the index are private too.
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(folder.path, 0o700)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(db)
            throw Failure(message: "Can't open \(url.path): \(message)")
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        // The index holds facts about the user's sessions: owner-only, like other ~/.akit files.
        chmod(url.path, 0o600)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    /// One or more statements without parameters or results.
    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? lastError
            sqlite3_free(message)
            throw Failure(message: text)
        }
    }

    /// Runs one statement; returns the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ values: any SQLBindable...) throws -> Int {
        try run(sql, values)
    }

    @discardableResult
    func run(_ sql: String, _ values: [any SQLBindable]) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_reset(statement) }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW { code = sqlite3_step(statement) }
        guard code == SQLITE_DONE else { throw Failure(message: lastError) }
        return Int(sqlite3_changes(handle))
    }

    /// Every row of a query, columns in order.
    func rows(_ sql: String, _ values: any SQLBindable...) throws -> [[SQLValue]] {
        try rows(sql, values)
    }

    func rows(_ sql: String, _ values: [any SQLBindable]) throws -> [[SQLValue]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_reset(statement) }
        var result: [[SQLValue]] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { column(statement, $0) })
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw Failure(message: lastError) }
        return result
    }

    /// First column of the first row, or nil.
    func value(_ sql: String, _ values: any SQLBindable...) throws -> SQLValue? {
        let statement = try prepare(sql, values)
        defer { sqlite3_reset(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return column(statement, 0)
        case SQLITE_DONE: return nil
        default: throw Failure(message: lastError)
        }
    }

    /// `BEGIN IMMEDIATE` … `COMMIT`; rolls back when `body` throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get throws { try value("PRAGMA user_version")?.int ?? 0 }
    }

    var lastInsertedRow: Int64 { sqlite3_last_insert_rowid(handle) }

    // MARK: - Statements

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    /// SQLite copies bound text before `sqlite3_bind_text` returns.
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private func prepare(_ sql: String, _ values: [any SQLBindable]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
                throw Failure(message: "\(lastError) in: \(sql)")
            }
            statements[sql] = prepared
            statement = prepared
        }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let code: Int32 = switch value.sqlValue {
            case .null: sqlite3_bind_null(statement, position)
            case .int(let number): sqlite3_bind_int64(statement, position, number)
            case .double(let number): sqlite3_bind_double(statement, position, number)
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
            }
            guard code == SQLITE_OK else { throw Failure(message: lastError) }
        }
        return statement
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT: sqlite3_column_text(statement, index).map { .text(String(cString: $0)) } ?? .null
        default: .null
        }
    }
}
