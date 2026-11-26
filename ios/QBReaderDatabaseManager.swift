import Foundation
import Compression
import CryptoKit
import SQLite3

/// Downloads, verifies, and installs the pre-built QBReader SQLite database.
///
/// Flow: fetch manifest.json -> compare with installed version -> download
/// qbreader.sqlite.xz -> verify compressed SHA-256 -> stream-decompress (LZMA,
/// Apple's Compression framework) -> verify SHA-256 of the result -> check
/// schema version -> atomically swap into Application Support (excluded from backup).
///
/// Requires iOS 15+ (async URLSession). No third-party dependencies.
public actor QBReaderDatabaseManager {

    /// "full" keeps all QBReader HTML (~900 MB on device); "lite" drops HTML from
    /// question bodies, lead-ins and bonus parts but keeps answer HTML (~500 MB).
    public enum Variant: String, Codable, Sendable {
        case full, lite
        var manifestName: String { self == .full ? "manifest.json" : "manifest-lite.json" }
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public let version: String
        public let schemaVersion: Int
        public let variant: Variant?
        public let url: String
        public let compression: String
        public let compressedSize: Int64
        public let compressedSha256: String
        public let size: Int64
        public let sha256: String
    }

    public enum InstallError: Error, LocalizedError {
        case badHTTPStatus(Int)
        case unsupportedCompression(String)
        case unsupportedSchema(Int)
        case checksumMismatch(stage: String)
        case decompressionFailed
        case invalidDatabase

        public var errorDescription: String? {
            switch self {
            case .badHTTPStatus(let code): return "Download failed (HTTP \(code))."
            case .unsupportedCompression(let c): return "Unsupported compression: \(c)."
            case .unsupportedSchema(let v): return "This app version can't read database schema \(v). Please update the app."
            case .checksumMismatch(let stage): return "The downloaded database is corrupted (\(stage) checksum mismatch)."
            case .decompressionFailed: return "Could not decompress the database."
            case .invalidDatabase: return "The downloaded file is not a valid database."
            }
        }
    }

    /// Highest schema this build of the app understands. Bump together with
    /// SCHEMA_VERSION in scripts/build_db.py when the schema changes.
    public static let supportedSchemaVersion = 1

    public static let releaseBaseURL = URL(string: "https://github.com/RyanThinkOrSwim/qbreader-db/releases/latest/download/")!

    public static let shared = QBReaderDatabaseManager(variant: .full)
    public static let lite = QBReaderDatabaseManager(variant: .lite)

    /// Both variants install to the same file, so use one manager at a time;
    /// installing the other variant replaces the current database.
    public init(variant: Variant) {
        self.manifestURL = Self.releaseBaseURL.appendingPathComponent(variant.manifestName)
    }

    private let manifestURL: URL
    private let fileManager = FileManager.default
    private let defaults = UserDefaults.standard
    private let versionKey = "QBReaderDatabase.installedVersion"
    private let variantKey = "QBReaderDatabase.installedVariant"

    public init(manifestURL: URL) {
        self.manifestURL = manifestURL
    }

    // MARK: - Locations

    public var databaseURL: URL {
        get throws { try directory().appendingPathComponent("qbreader.sqlite") }
    }

    public var installedVersion: String? {
        guard let url = try? databaseURL, fileManager.fileExists(atPath: url.path) else { return nil }
        return defaults.string(forKey: versionKey)
    }

    public var installedVariant: Variant? {
        guard installedVersion != nil else { return nil }
        return defaults.string(forKey: variantKey).flatMap(Variant.init(rawValue:)) ?? .full
    }

    private func directory() throws -> URL {
        let dir = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)
            .appendingPathComponent("QBReader", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Public API

    /// Returns the remote manifest if it is newer than what is installed and
    /// readable by this app version, otherwise nil.
    public func availableUpdate() async throws -> Manifest? {
        let manifest = try await fetchManifest()
        guard manifest.schemaVersion <= Self.supportedSchemaVersion else { return nil }
        let sameVariant = (manifest.variant ?? .full) == installedVariant
        return manifest.version == installedVersion && sameVariant ? nil : manifest
    }

    /// Downloads and installs the given manifest's database.
    /// `progress` receives 0...1 for the download phase.
    public func install(_ manifest: Manifest,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard manifest.compression == "lzma" else { throw InstallError.unsupportedCompression(manifest.compression) }
        guard manifest.schemaVersion <= Self.supportedSchemaVersion else {
            throw InstallError.unsupportedSchema(manifest.schemaVersion)
        }

        let remote = URL(string: manifest.url, relativeTo: manifestURL)!.absoluteURL
        let tmpCompressed = try await DownloadRunner.download(remote, expectedBytes: manifest.compressedSize,
                                                              onProgress: progress)
        defer { try? fileManager.removeItem(at: tmpCompressed) }

        guard try Self.sha256(of: tmpCompressed) == manifest.compressedSha256.lowercased() else {
            throw InstallError.checksumMismatch(stage: "download")
        }

        let dir = try directory()
        let staging = dir.appendingPathComponent("qbreader.sqlite.download")
        try? fileManager.removeItem(at: staging)
        let decompressedHash = try Self.decompressLZMA(from: tmpCompressed, to: staging)
        guard decompressedHash == manifest.sha256.lowercased() else {
            try? fileManager.removeItem(at: staging)
            throw InstallError.checksumMismatch(stage: "database")
        }
        guard Self.userVersion(of: staging) == manifest.schemaVersion else {
            try? fileManager.removeItem(at: staging)
            throw InstallError.invalidDatabase
        }

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var stagingURL = staging
        try stagingURL.setResourceValues(values)

        let target = try databaseURL
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: target)
        }
        var targetURL = target
        try targetURL.setResourceValues(values)
        defaults.set(manifest.version, forKey: versionKey)
        defaults.set((manifest.variant ?? .full).rawValue, forKey: variantKey)
    }

    /// Convenience: check and install if needed. Returns true if a new database was installed.
    @discardableResult
    public func updateIfNeeded(progress: (@Sendable (Double) -> Void)? = nil) async throws -> Bool {
        guard let manifest = try await availableUpdate() else { return false }
        try await install(manifest, progress: progress)
        return true
    }

    public func removeDatabase() throws {
        try? fileManager.removeItem(at: try databaseURL)
        defaults.removeObject(forKey: versionKey)
        defaults.removeObject(forKey: variantKey)
    }

    // MARK: - Internals

    private func fetchManifest() async throws -> Manifest {
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.badHTTPStatus(http.statusCode)
        }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Streams an .xz file through Compression's LZMA decoder to disk, hashing
    /// the output as it goes. Peak memory stays at a few MB.
    private static func decompressLZMA(from source: URL, to destination: URL) throws -> String {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }

        var hasher = SHA256()
        var writeError: Error?
        let filter = try OutputFilter(.decompress, using: .lzma, bufferCapacity: 1 << 20) { data in
            guard let data, writeError == nil else { return }
            hasher.update(data: data)
            do { try output.write(contentsOf: data) } catch { writeError = error }
        }
        do {
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try filter.write(chunk)
            }
            try filter.finalize()
        } catch {
            throw InstallError.decompressionFailed
        }
        if let writeError { throw writeError }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func userVersion(of url: URL) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : nil
    }
}

/// URLSessionDownloadTask with byte-level progress (works on iOS 15+).
/// Moves the finished file out of URLSession's temporary location before returning.
private final class DownloadRunner: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expected: Int64
    private let onProgress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?

    private init(expected: Int64, onProgress: (@Sendable (Double) -> Void)?) {
        self.expected = expected
        self.onProgress = onProgress
    }

    static func download(_ url: URL, expectedBytes: Int64,
                         onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let runner = DownloadRunner(expected: expectedBytes, onProgress: onProgress)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 60 * 60
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: runner, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                runner.continuation = cont
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        if total > 0 { onProgress?(min(1, Double(totalBytesWritten) / Double(total))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(QBReaderDatabaseManager.InstallError.badHTTPStatus(http.statusCode)))
            return
        }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xz")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
