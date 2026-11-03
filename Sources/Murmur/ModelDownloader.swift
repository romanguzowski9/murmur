import Foundation
import MurmurCore

/// Downloads the Whisper models Murmur uses (whisper.cpp's ggml files, from its Hugging Face repository) into
/// Murmur's Models folder, one after another, reporting progress. A partial download never takes a model's name.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    static let source = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
    /// Approximate sizes, for the menu before anything is downloaded.
    static let sizes = ["ggml-large-v3-turbo.bin": 1_624_555_275, "ggml-base.bin": 147_951_465]

    private(set) var isRunning = false
    /// 0…1 over all files.
    private(set) var progress = 0.0
    var onProgress: ((Double) -> Void)?
    var onFinished: ((Error?) -> Void)?

    private var queue: [String] = []
    private var current: String?
    private var doneBytes: Int64 = 0
    private var totalBytes: Int64 = 1
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    static func missing(_ models: [String]) -> [String] {
        models.filter { !FileManager.default.fileExists(atPath: ConfigStore.modelsDirectory.appendingPathComponent($0).path) }
    }

    static func describe(_ models: [String]) -> String {
        let bytes = models.reduce(0) { $0 + (sizes[$1] ?? 0) }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    func start(_ models: [String]) {
        guard !isRunning, !models.isEmpty else { return }
        try? FileManager.default.createDirectory(at: ConfigStore.modelsDirectory, withIntermediateDirectories: true)
        isRunning = true
        queue = models
        doneBytes = 0
        totalBytes = Int64(models.reduce(0) { $0 + (Self.sizes[$1] ?? 100_000_000) })
        next()
    }

    func cancel() {
        session.getAllTasks { $0.forEach { $0.cancel() } }
        finish(NSError(domain: "Murmur", code: NSUserCancelledError, userInfo: [NSLocalizedDescriptionKey: "Cancelled"]))
    }

    private func next() {
        guard let name = queue.first, let url = URL(string: Self.source + name) else { return finish(nil) }
        queue.removeFirst()
        current = name
        session.downloadTask(with: url).resume()
    }

    private func finish(_ error: Error?) {
        guard isRunning else { return }
        isRunning = false
        queue = []
        current = nil
        onFinished?(error)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress = min(1, Double(doneBytes + totalBytesWritten) / Double(totalBytes))
        onProgress?(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = current else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            return finish(NSError(domain: "Murmur", code: status,
                                  userInfo: [NSLocalizedDescriptionKey: "\(name): the server answered \(status)"]))
        }
        let target = ConfigStore.modelsDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: location, to: target)
        } catch {
            return finish(error)
        }
        doneBytes += downloadTask.countOfBytesReceived
        next()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }
}
