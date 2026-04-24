import Foundation
import SQLite3
import XCTest

final class SQLiteMailroomStoreMigrationTests: XCTestCase {
    func testNewStoreRecordsCurrentSchemaVersion() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("mailroom.sqlite3")

        _ = try SQLiteMailroomStore(databasePath: databaseURL.path)

        XCTAssertEqual(try userVersion(at: databaseURL), SQLiteMailroomStore.currentSchemaVersion)
    }

    func testLegacyUserVersionZeroDatabaseMigratesToCurrentSchema() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("mailroom.sqlite3")

        try withSQLiteDatabase(at: databaseURL) { database in
            try execute(
                """
                CREATE TABLE codex_turns (
                    id TEXT PRIMARY KEY,
                    mail_thread_token TEXT,
                    codex_thread_id TEXT NOT NULL,
                    origin TEXT NOT NULL,
                    status TEXT NOT NULL,
                    prompt_preview TEXT,
                    last_notified_state TEXT,
                    last_notification_message_id TEXT,
                    started_at REAL NOT NULL,
                    completed_at REAL,
                    updated_at REAL NOT NULL
                );
                """,
                in: database
            )
            try execute("PRAGMA user_version = 0;", in: database)
        }

        _ = try SQLiteMailroomStore(databasePath: databaseURL.path)

        XCTAssertEqual(try userVersion(at: databaseURL), SQLiteMailroomStore.currentSchemaVersion)
        XCTAssertTrue(try columns(in: "codex_turns", at: databaseURL).contains("last_notified_approval_id"))
    }

    func testNewerSchemaVersionFailsClosed() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("mailroom.sqlite3")
        let newerVersion = SQLiteMailroomStore.currentSchemaVersion + 1

        try withSQLiteDatabase(at: databaseURL) { database in
            try execute("PRAGMA user_version = \(newerVersion);", in: database)
        }

        XCTAssertThrowsError(try SQLiteMailroomStore(databasePath: databaseURL.path)) { error in
            guard case SQLiteMailroomStoreError.unsupportedSchemaVersion(let existing, let supported) = error else {
                return XCTFail("Expected unsupported schema version, got \(error)")
            }
            XCTAssertEqual(existing, newerVersion)
            XCTAssertEqual(supported, SQLiteMailroomStore.currentSchemaVersion)
        }
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PatchCourierSQLiteMigrationTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func userVersion(at databaseURL: URL) throws -> Int {
        try withSQLiteDatabase(at: databaseURL) { database in
            let statement = try prepare("PRAGMA user_version;", in: database)
            defer { sqlite3_finalize(statement) }

            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw TestSQLiteError.statementFailed(message(from: database))
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func columns(in table: String, at databaseURL: URL) throws -> Set<String> {
        try withSQLiteDatabase(at: databaseURL) { database in
            let statement = try prepare("PRAGMA table_info(\(table));", in: database)
            defer { sqlite3_finalize(statement) }

            var columns: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawName = sqlite3_column_text(statement, 1) else { continue }
                columns.insert(String(cString: rawName))
            }
            return columns
        }
    }

    private func withSQLiteDatabase<T>(at databaseURL: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            let failureMessage = message(from: database)
            sqlite3_close(database)
            throw TestSQLiteError.openFailed(failureMessage)
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private func prepare(_ sql: String, in database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TestSQLiteError.statementFailed(message(from: database))
        }
        return statement
    }

    private func execute(_ sql: String, in database: OpaquePointer?) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let failureMessage = errorMessage.map { String(cString: $0) } ?? message(from: database)
            sqlite3_free(errorMessage)
            throw TestSQLiteError.statementFailed(failureMessage)
        }
    }

    private func message(from database: OpaquePointer?) -> String {
        guard let database else {
            return "Unknown SQLite error."
        }
        return String(cString: sqlite3_errmsg(database))
    }
}

private enum TestSQLiteError: Error {
    case openFailed(String)
    case statementFailed(String)
}
