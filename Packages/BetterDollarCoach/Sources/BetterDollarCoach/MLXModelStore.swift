import Foundation
import CryptoKit
import Observation

public enum MLXModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(fraction: Double)
    case ready
    case failed(String)
}

/// Downloads, verifies and deletes local models. Files come straight from Hugging Face at a pinned
/// revision into Application Support (excluded from iCloud/iTunes backup).
@MainActor @Observable public final class MLXModelStore {
    public static let shared = MLXModelStore()

    public let rootDirectory: URL
    private var states: [String: MLXModelState] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Identifies the current download per model, so a cancelled task can't overwrite a newer one.
    @ObservationIgnored private var downloadTokens: [String: UUID] = [:]
    @ObservationIgnored private let downloader: FileDownloader

    public init(rootDirectory: URL? = nil, configuration: URLSessionConfiguration = .default) {
        self.rootDirectory = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterDollar/Models", isDirectory: true)
        self.downloader = FileDownloader(configuration: configuration)
    }

    public func directory(for spec: MLXModelSpec) -> URL {
        rootDirectory.appendingPathComponent("\(spec.id)-\(spec.revision.prefix(12))", isDirectory: true)
    }

    private func markerURL(for spec: MLXModelSpec) -> URL { directory(for: spec).appendingPathComponent(".betterdollar-complete") }

    public func isDownloaded(_ spec: MLXModelSpec) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(for: spec).path)
    }

    public func state(for spec: MLXModelSpec) -> MLXModelState {
        if let state = states[spec.id] { return state }
        return isDownloaded(spec) ? .ready : .notDownloaded
    }

    public var downloadedModels: [MLXModelSpec] { MLXModelCatalog.all.filter { state(for: $0) == .ready } }

    public func diskUsageBytes(for spec: MLXModelSpec) -> Int64 {
        let directory = directory(for: spec)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    public func download(_ spec: MLXModelSpec) {
        if case .downloading = state(for: spec) { return }
        guard !isDownloaded(spec) else { states[spec.id] = .ready; return }
        if let free = Self.freeDiskBytes(at: rootDirectory), free < spec.approxBytes + 500_000_000 {
            states[spec.id] = .failed("Not enough free space. \(spec.displayName) needs about \(spec.sizeText) plus some room to spare.")
            return
        }
        states[spec.id] = .downloading(fraction: 0)
        let directory = directory(for: spec), marker = markerURL(for: spec), downloader = downloader
        let token = UUID()
        downloadTokens[spec.id] = token
        tasks[spec.id] = Task { [weak self] in
            var outcome: MLXModelState
            do {
                try await ModelFileFetcher.fetch(spec: spec, into: directory, marker: marker, downloader: downloader) { fraction in
                    Task { @MainActor in
                        guard let self, self.downloadTokens[spec.id] == token, case .downloading = self.states[spec.id] else { return }
                        self.states[spec.id] = .downloading(fraction: fraction)
                    }
                }
                outcome = .ready
            } catch is CancellationError {
                outcome = .notDownloaded
            } catch let error as URLError where error.code == .cancelled {
                outcome = .notDownloaded
            } catch {
                outcome = .failed(Self.message(for: error))
            }
            guard let self, self.downloadTokens[spec.id] == token else { return }
            self.states[spec.id] = outcome
            self.tasks[spec.id] = nil
            self.downloadTokens[spec.id] = nil
        }
    }

    /// Stops a download. Finished files are kept so the next attempt resumes from there.
    public func cancel(_ spec: MLXModelSpec) {
        tasks[spec.id]?.cancel()
        tasks[spec.id] = nil
        downloadTokens[spec.id] = nil
        states[spec.id] = .notDownloaded
    }

    public func delete(_ spec: MLXModelSpec) {
        cancel(spec)
        try? FileManager.default.removeItem(at: directory(for: spec))
        states[spec.id] = nil
    }

    static func message(for error: Error) -> String {
        if let error = error as? CoachError { return error.message }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "The connection dropped. Reconnect and tap Download to resume."
            case .timedOut: return "The download timed out. Tap Download to resume."
            default: return "The download failed (\(error.code.rawValue)). Tap Download to try again."
            }
        }
        return error.localizedDescription
    }

    nonisolated static func freeDiskBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - Fetching

/// A file in a Hugging Face repository at a given revision.
struct RemoteModelFile: Decodable, Sendable, Equatable {
    struct LFS: Decodable, Sendable, Equatable { let oid: String; let size: Int64 }
    let type: String
    let path: String
    let size: Int64
    let lfs: LFS?

    var byteCount: Int64 { lfs?.size ?? size }

    /// Weights, configs, tokenizer and chat template. Skips READMEs, images and other extras.
    var isNeeded: Bool {
        guard type == "file", !path.contains("/") else { return false }
        return path.hasSuffix(".safetensors") || path.hasSuffix(".json") || path.hasSuffix(".jinja")
            || path == "tokenizer.model" || path.hasSuffix(".txt") || path.hasSuffix(".tiktoken")
    }
}

enum ModelFileFetcher {
    static func listing(spec: MLXModelSpec, downloader: FileDownloader) async throws -> [RemoteModelFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(spec.repo)/tree/\(spec.revision)")!
        let data = try await downloader.data(from: url)
        let files = try JSONDecoder().decode([RemoteModelFile].self, from: data).filter(\.isNeeded)
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }), files.contains(where: { $0.path == "config.json" }) else {
            throw CoachError("Model files missing", "\(spec.displayName) is missing its weights on Hugging Face. Try another model.")
        }
        return files
    }

    static func fetch(spec: MLXModelSpec, into directory: URL, marker: URL, downloader: FileDownloader,
                      progress report: @escaping @Sendable (Double) -> Void) async throws {
        let files = try await listing(spec: spec, downloader: downloader)
        let progress = ProgressThrottle(report)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)

        let total = max(1, files.reduce(0) { $0 + $1.byteCount })
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.path)
            if size(of: destination) == file.byteCount {
                completed += file.byteCount
                progress(Double(completed) / Double(total))
                continue
            }
            let remote = URL(string: "https://huggingface.co/\(spec.repo)/resolve/\(spec.revision)/\(file.path)")!
            let base = completed
            try await downloader.download(from: remote, to: destination) { written in
                progress(Double(base + written) / Double(total))
            }
            guard size(of: destination) == file.byteCount else {
                try? FileManager.default.removeItem(at: destination)
                throw CoachError("Download incomplete", "\(file.path) arrived with the wrong size. Tap Download to try again.")
            }
            if let oid = file.lfs?.oid, oid.count == 64, try await sha256(of: destination) != oid {
                try? FileManager.default.removeItem(at: destination)
                throw CoachError("Download damaged", "\(file.path) didn't pass its integrity check. Tap Download to try again.")
            }
            completed += file.byteCount
            progress(Double(completed) / Double(total))
        }
        let manifest = ["repo": spec.repo, "revision": spec.revision, "files": files.map(\.path).joined(separator: ",")]
        try JSONSerialization.data(withJSONObject: manifest).write(to: marker, options: .atomic)
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    @concurrent static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Forwards progress only when it moves by at least 0.2% so the UI isn't flooded.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func callAsFunction(_ fraction: Double) {
        let clamped = min(1, max(0, fraction))
        let shouldReport = lock.withLock {
            guard clamped - last >= 0.002 || clamped == 1 else { return false }
            last = clamped
            return true
        }
        if shouldReport { report(clamped) }
    }
}

/// URLSession download tasks with byte progress. The temporary file is moved into place
/// inside the delegate callback, before URLSession deletes it.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        let destination: URL
        let progress: @Sendable (Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
        var movedError: Error?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        super.init()
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CoachError("Hugging Face unavailable", "Hugging Face answered with error \(http.statusCode). Try again later.")
        }
        return data
    }

    func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { pending[task.taskIdentifier] = Pending(destination: destination, progress: progress, continuation: continuation) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let handler = lock.withLock { pending[downloadTask.taskIdentifier]?.progress }
        handler?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        guard let destination = lock.withLock({ pending[id]?.destination }) else { return }
        var failure: Error?
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = CoachError("Download failed", "Hugging Face answered with error \(http.statusCode) for \(destination.lastPathComponent).")
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }
        lock.withLock { pending[id]?.movedError = failure }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error = error ?? entry.movedError {
            entry.continuation.resume(throwing: error)
        } else {
            entry.continuation.resume()
        }
    }
}
