import Foundation
import SQLite3

public enum HistoryError: Error, Equatable {
    case sqlite(code: Int32, message: String)
    case unsupportedSchema(version: Int)
    case invalidPressureLevel(Int32)
}

/// A minimal wrapper around the SQLite C API. Values are only numbers, never text, so no
/// statement has to manage the lifetime of bound strings.
final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(fileURL: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(fileURL.path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let error = makeError(code: result)
            sqlite3_close_v2(handle)
            throw error
        }
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw makeError(code: result) }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw makeError(code: result) }
        return SQLiteStatement(connection: self, statement: statement)
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func makeError(code: Int32) -> HistoryError {
        let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
        return .sqlite(code: code, message: message)
    }
}

final class SQLiteStatement {
    private let connection: SQLiteConnection
    private let statement: OpaquePointer

    init(connection: SQLiteConnection, statement: OpaquePointer) {
        self.connection = connection
        self.statement = statement
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func bind(_ value: Double?, at index: Int32) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bind(_ value: UInt64, at index: Int32) {
        sqlite3_bind_int64(statement, index, Int64(clamping: value))
    }

    /// Runs a statement that returns no rows and leaves it ready to be reused.
    func run() throws {
        defer { sqlite3_reset(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw connection.makeError(code: result) }
    }

    /// Runs a query, mapping each row, and leaves the statement ready to be reused.
    func rows<Row>(_ makeRow: (SQLiteStatement) throws -> Row) throws -> [Row] {
        defer { sqlite3_reset(statement) }
        var rows: [Row] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW: rows.append(try makeRow(self))
            case SQLITE_DONE: return rows
            default: throw connection.makeError(code: result)
            }
        }
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func optionalDouble(at index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : double(at: index)
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func unsignedInt(at index: Int32) -> UInt64 {
        UInt64(clamping: int64(at: index))
    }
}
