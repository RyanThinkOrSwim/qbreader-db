import Foundation
import SQLite3

// MARK: - Models

public struct QBTossup: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let mongoId: String
    public let question: String            // HTML (<b>, <u>, <i>, power mark "(*)")
    public let questionSanitized: String   // plain text
    public let answer: String              // HTML; required part is in <b><u>
    public let answerSanitized: String
    public let category: String
    public let subcategory: String
    public let alternateSubcategory: String?
    public let difficulty: Int?
    public let year: Int
    public let setName: String
    public let packetName: String
    public let number: Int
}

public struct QBBonusPart: Hashable, Sendable {
    public let index: Int
    public let part: String
    public let partSanitized: String
    public let answer: String
    public let answerSanitized: String
    public let value: Int
    public let difficultyModifier: String?  // "e" | "m" | "h" | nil
}

public struct QBBonus: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let mongoId: String
    public let leadin: String
    public let leadinSanitized: String
    public let parts: [QBBonusPart]
    public let category: String
    public let subcategory: String
    public let alternateSubcategory: String?
    public let difficulty: Int?
    public let year: Int
    public let setName: String
    public let packetName: String
    public let number: Int
}

public struct QBSet: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let year: Int
    public let difficulty: Int?
    public let standard: Bool
}

/// Filters mirror QBReader's query options. Empty arrays mean "any".
public struct QBFilter: Sendable {
    public var difficulties: [Int] = []
    public var categories: [String] = []
    public var subcategories: [String] = []
    public var alternateSubcategories: [String] = []
    public var minYear: Int? = nil
    public var maxYear: Int? = nil
    public var standardOnly: Bool = false
    public init() {}
}

// MARK: - Store

/// Read-only access to qbreader.sqlite using the system SQLite (FTS5 included on iOS 13+).
/// One connection per store; the class serializes access internally, so it is safe to share.
public final class QBReaderStore: @unchecked Sendable {

    public enum StoreError: Error { case open(String), prepare(String) }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "QBReaderStore")

    public init(url: URL) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw StoreError.open(msg)
        }
        sqlite3_exec(db, "PRAGMA query_only = 1; PRAGMA cache_size = -8000; PRAGMA mmap_size = 268435456;", nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    // MARK: Metadata

    public func meta(_ key: String) -> String? {
        queue.sync { try? query("SELECT value FROM meta WHERE key = ?", [key]) { $0.text(0) }.first }
    }

    public func categories() -> [(category: String, subcategories: [String])] {
        queue.sync {
            let rows = (try? query("SELECT DISTINCT category, subcategory FROM tossups ORDER BY category, subcategory") {
                ($0.text(0), $0.text(1))
            }) ?? []
            return Dictionary(grouping: rows, by: \.0)
                .map { ($0.key, $0.value.map(\.1)) }
                .sorted { $0.0 < $1.0 }
        }
    }

    public func sets() -> [QBSet] {
        queue.sync {
            (try? query("SELECT id, name, year, difficulty, standard FROM sets ORDER BY year DESC, name") {
                QBSet(id: $0.int64(0), name: $0.text(1), year: $0.int(2), difficulty: $0.optInt(3), standard: $0.int(4) != 0)
            }) ?? []
        }
    }

    // MARK: Tossups

    public func randomTossups(_ filter: QBFilter = QBFilter(), count: Int = 1) -> [QBTossup] {
        queue.sync {
            let (whereSQL, args) = Self.whereClause(filter, table: "t")
            return (try? query(Self.tossupSelect + whereSQL + " ORDER BY random() LIMIT ?", args + [count], Self.tossup)) ?? []
        }
    }

    /// Full-text search over question and answer text. `answerOnly` restricts to the answer line.
    public func searchTossups(_ text: String, answerOnly: Bool = false,
                              filter: QBFilter = QBFilter(), limit: Int = 50, offset: Int = 0) -> [QBTossup] {
        guard let match = Self.ftsQuery(text, column: answerOnly ? "answer" : nil) else { return [] }
        return queue.sync {
            let (whereSQL, args) = Self.whereClause(filter, table: "t", leading: "AND")
            let sql = Self.tossupSelect + " JOIN tossups_fts f ON f.rowid = t.id WHERE tossups_fts MATCH ? "
                + whereSQL + " ORDER BY f.rank LIMIT ? OFFSET ?"
            return (try? query(sql, [match] + args + [limit, offset], Self.tossup)) ?? []
        }
    }

    public func tossups(inPacket packetId: Int64) -> [QBTossup] {
        queue.sync {
            (try? query(Self.tossupSelect + " WHERE t.packet_id = ? ORDER BY t.number", [packetId], Self.tossup)) ?? []
        }
    }

    // MARK: Bonuses

    public func randomBonuses(_ filter: QBFilter = QBFilter(), count: Int = 1) -> [QBBonus] {
        queue.sync {
            let (whereSQL, args) = Self.whereClause(filter, table: "b")
            let heads = (try? query(Self.bonusSelect + whereSQL + " ORDER BY random() LIMIT ?", args + [count], Self.bonusHead)) ?? []
            return heads.map(attachParts)
        }
    }

    public func searchBonuses(_ text: String, answerOnly: Bool = false,
                              filter: QBFilter = QBFilter(), limit: Int = 50, offset: Int = 0) -> [QBBonus] {
        guard let match = Self.ftsQuery(text, column: answerOnly ? "answers" : nil) else { return [] }
        return queue.sync {
            let (whereSQL, args) = Self.whereClause(filter, table: "b", leading: "AND")
            let sql = Self.bonusSelect + " JOIN bonuses_fts f ON f.rowid = b.id WHERE bonuses_fts MATCH ? "
                + whereSQL + " ORDER BY f.rank LIMIT ? OFFSET ?"
            let heads = (try? query(sql, [match] + args + [limit, offset], Self.bonusHead)) ?? []
            return heads.map(attachParts)
        }
    }

    // MARK: - SQL helpers

    private static let tossupSelect = """
        SELECT t.id, t.mongo_id, t.question, t.question_sanitized, t.answer, t.answer_sanitized,
               t.category, t.subcategory, t.alternate_subcategory, t.difficulty, t.year,
               s.name, p.name, t.number
        FROM tossups t JOIN sets s ON s.id = t.set_id JOIN packets p ON p.id = t.packet_id
        """

    private static let bonusSelect = """
        SELECT b.id, b.mongo_id, b.leadin, b.leadin_sanitized,
               b.category, b.subcategory, b.alternate_subcategory, b.difficulty, b.year,
               s.name, p.name, b.number
        FROM bonuses b JOIN sets s ON s.id = b.set_id JOIN packets p ON p.id = b.packet_id
        """

    private static func tossup(_ r: Row) -> QBTossup {
        QBTossup(id: r.int64(0), mongoId: r.text(1), question: r.text(2), questionSanitized: r.text(3),
                 answer: r.text(4), answerSanitized: r.text(5), category: r.text(6), subcategory: r.text(7),
                 alternateSubcategory: r.optText(8), difficulty: r.optInt(9), year: r.int(10),
                 setName: r.text(11), packetName: r.text(12), number: r.int(13))
    }

    private static func bonusHead(_ r: Row) -> QBBonus {
        QBBonus(id: r.int64(0), mongoId: r.text(1), leadin: r.text(2), leadinSanitized: r.text(3), parts: [],
                category: r.text(4), subcategory: r.text(5), alternateSubcategory: r.optText(6),
                difficulty: r.optInt(7), year: r.int(8), setName: r.text(9), packetName: r.text(10), number: r.int(11))
    }

    private func attachParts(_ b: QBBonus) -> QBBonus {
        let parts = (try? query("""
            SELECT part_index, part, part_sanitized, answer, answer_sanitized, value, difficulty_modifier
            FROM bonus_parts WHERE bonus_id = ? ORDER BY part_index
            """, [b.id]) {
            QBBonusPart(index: $0.int(0), part: $0.text(1), partSanitized: $0.text(2), answer: $0.text(3),
                        answerSanitized: $0.text(4), value: $0.int(5), difficultyModifier: $0.optText(6))
        }) ?? []
        return QBBonus(id: b.id, mongoId: b.mongoId, leadin: b.leadin, leadinSanitized: b.leadinSanitized, parts: parts,
                       category: b.category, subcategory: b.subcategory, alternateSubcategory: b.alternateSubcategory,
                       difficulty: b.difficulty, year: b.year, setName: b.setName, packetName: b.packetName, number: b.number)
    }

    private static func whereClause(_ f: QBFilter, table t: String, leading: String = "WHERE") -> (String, [Any]) {
        var parts: [String] = []
        var args: [Any] = []
        func inList(_ col: String, _ values: [Any]) {
            guard !values.isEmpty else { return }
            parts.append("\(t).\(col) IN (" + Array(repeating: "?", count: values.count).joined(separator: ",") + ")")
            args += values
        }
        inList("difficulty", f.difficulties)
        inList("category", f.categories)
        inList("subcategory", f.subcategories)
        inList("alternate_subcategory", f.alternateSubcategories)
        if let y = f.minYear { parts.append("\(t).year >= ?"); args.append(y) }
        if let y = f.maxYear { parts.append("\(t).year <= ?"); args.append(y) }
        if f.standardOnly { parts.append("\(t).standard = 1") }
        return parts.isEmpty ? ("", []) : (" \(leading) " + parts.joined(separator: " AND "), args)
    }

    /// Turns free user input into a safe FTS5 query: every word is quoted, the
    /// last one is a prefix match ("schoen" finds "Schoenberg").
    static func ftsQuery(_ text: String, column: String? = nil) -> String? {
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return nil }
        let terms = words.enumerated().map { i, w in
            "\"\(w)\"" + (i == words.count - 1 ? "*" : "")
        }.joined(separator: " ")
        return column.map { "\($0) : (\(terms))" } ?? terms
    }

    // MARK: - Minimal SQLite wrapper

    struct Row {
        let stmt: OpaquePointer?
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
        func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func optInt(_ i: Int32) -> Int? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : int(i) }
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        func optText(_ i: Int32) -> String? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : text(i) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func query<T>(_ sql: String, _ args: [Any] = [], _ map: (Row) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(Row(stmt: stmt))) }
        return out
    }
}
