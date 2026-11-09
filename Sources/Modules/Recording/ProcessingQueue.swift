// MasterFabric Cut — Recording module
// Author: Gürkan Fikret Günak · masterfabric.co
import Foundation
import Combine

public enum MediaJobKind: String, Sendable {
    case batchExport
    case silenceRemoval
    case portraitReframe
    case transcription
}

public enum MediaJobStatus: Equatable, Sendable {
    case queued
    case running(progress: Double)
    case succeeded(URL)
    case failed(String)
    case cancelled
}

public struct MediaQueueJob: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var source: URL
    public var kind: MediaJobKind
    public var label: String
    public var status: MediaJobStatus
    public var retryCount: Int

    public init(id: UUID = UUID(), source: URL, kind: MediaJobKind, label: String,
                status: MediaJobStatus = .queued, retryCount: Int = 0) {
        self.id = id; self.source = source; self.kind = kind; self.label = label
        self.status = status; self.retryCount = retryCount
    }

    public var isFinished: Bool {
        switch status {
        case .succeeded, .failed, .cancelled: return true
        default: return false
        }
    }
}

/// Serial media processing queue with progress, cancellation, and per-job retry.
@MainActor
public final class ProcessingQueue: ObservableObject {
    public static let shared = ProcessingQueue()

    @Published public private(set) var jobs: [MediaQueueJob] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var overallProgress: Double = 0

    private var workTask: Task<Void, Never>?
    private var cancelRequested = false
    /// Per-job cancel flags so a single item can be aborted without clearing the whole queue.
    private var cancelledIDs = Set<UUID>()
    /// The active job runner checks this between stages.
    public private(set) var activeJobID: UUID?

    public var queuedCount: Int { jobs.filter { if case .queued = $0.status { return true }; return false }.count }
    public var failedCount: Int { jobs.filter { if case .failed = $0.status { return true }; return false }.count }

    private init() {}

    @discardableResult
    public func enqueue(_ job: MediaQueueJob) -> UUID {
        jobs.append(job)
        recomputeOverall()
        return job.id
    }

    public func enqueueMany(_ items: [MediaQueueJob]) {
        jobs.append(contentsOf: items)
        recomputeOverall()
    }

    public func clearFinished() {
        jobs.removeAll { $0.isFinished }
        recomputeOverall()
    }

    public func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        cancelledIDs.insert(id)
        recomputeOverall()
    }

    public func cancelAll() {
        cancelRequested = true
        workTask?.cancel()
        for i in jobs.indices {
            switch jobs[i].status {
            case .queued, .running:
                jobs[i].status = .cancelled
                cancelledIDs.insert(jobs[i].id)
            default: break
            }
        }
        isRunning = false
        activeJobID = nil
        recomputeOverall()
    }

    public func cancel(id: UUID) {
        cancelledIDs.insert(id)
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            switch jobs[i].status {
            case .queued, .running:
                jobs[i].status = .cancelled
            default: break
            }
        }
        if activeJobID == id { workTask?.cancel() }
        recomputeOverall()
    }

    public func retryFailed() {
        for i in jobs.indices {
            if case .failed = jobs[i].status {
                jobs[i].status = .queued
                jobs[i].retryCount += 1
                cancelledIDs.remove(jobs[i].id)
            }
        }
        recomputeOverall()
        startIfNeeded()
    }

    public func retry(id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = .queued
        jobs[i].retryCount += 1
        cancelledIDs.remove(id)
        recomputeOverall()
        startIfNeeded()
    }

    public func isCancelled(_ id: UUID) -> Bool {
        cancelRequested || cancelledIDs.contains(id) || Task.isCancelled
    }

    public func updateProgress(id: UUID, _ value: Double) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = .running(progress: min(1, max(0, value)))
        recomputeOverall()
    }

    public func markSucceeded(id: UUID, url: URL) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = .succeeded(url)
        recomputeOverall()
    }

    public func markFailed(id: UUID, message: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if case .cancelled = jobs[i].status { return }
        jobs[i].status = cancelledIDs.contains(id) ? .cancelled : .failed(message)
        recomputeOverall()
    }

    /// Runs jobs serially via `handler`. The handler must respect `isCancelled` and call progress helpers.
    public func start(handler: @escaping @MainActor (MediaQueueJob) async throws -> URL) {
        guard !isRunning else { return }
        cancelRequested = false
        isRunning = true
        workTask = Task { @MainActor in
            defer {
                self.isRunning = false
                self.activeJobID = nil
                self.recomputeOverall()
            }
            while let next = self.nextQueued() {
                if self.cancelRequested { break }
                self.activeJobID = next.id
                if let i = self.jobs.firstIndex(where: { $0.id == next.id }) {
                    self.jobs[i].status = .running(progress: 0)
                }
                do {
                    try Task.checkCancellation()
                    if self.isCancelled(next.id) {
                        self.markFailed(id: next.id, message: "Cancelled")
                        continue
                    }
                    let url = try await handler(next)
                    if self.isCancelled(next.id) {
                        self.jobs[self.jobs.firstIndex(where: { $0.id == next.id })!].status = .cancelled
                    } else {
                        self.markSucceeded(id: next.id, url: url)
                    }
                } catch is CancellationError {
                    self.cancel(id: next.id)
                } catch {
                    if self.isCancelled(next.id) {
                        self.cancel(id: next.id)
                    } else {
                        self.markFailed(id: next.id, message: ErrorPresenter.message(for: error))
                    }
                }
            }
        }
    }

    public func startIfNeeded(handler: (@MainActor (MediaQueueJob) async throws -> URL)? = nil) {
        // External callers that already installed a persistent runner use BatchMediaStudioModel.
        _ = handler
    }

    private func nextQueued() -> MediaQueueJob? {
        jobs.first { if case .queued = $0.status { return true }; return false }
    }

    private func recomputeOverall() {
        guard !jobs.isEmpty else { overallProgress = 0; return }
        var sum = 0.0
        for j in jobs {
            switch j.status {
            case .queued: sum += 0
            case .running(let p): sum += p
            case .succeeded, .cancelled: sum += 1
            case .failed: sum += 1
            }
        }
        overallProgress = sum / Double(jobs.count)
    }
}
