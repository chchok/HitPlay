import Foundation

/// 订阅下载大小上限：
/// 合法引擎包现实上限约 7MB（CatVodOpen 生态 esbuild 单文件产物），上限 64MB 已
/// 远超合法包体；.md5 指针文件更小（1MB）。Content-Length 预检 + 流式累计
/// 双保险：服务端虚报/不报长度时也在超限的瞬间中止，绝不把整包拉进内存。
enum BoundedDownloader {
    /// 引擎包/TVBox 配置下载上限。
    static let maxPackageBytes = 64 * 1024 * 1024
    /// .md5 指纹指针文件上限。
    static let maxPointerBytes = 1024 * 1024

    static func sizeDescription(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func fetch(
        _ url: URL,
        session: URLSession,
        maxBytes: Int,
        timeout: TimeInterval = 30
    ) async throws -> Data {
        let request = URLRequest(url: url, timeoutInterval: timeout)
        let download = ChunkedDownload(maxBytes: maxBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.start(configuration: session.configuration, request: request, continuation: continuation)
            }
        } onCancel: {
            download.cancel()
        }
    }
}

/// URLSession 按网络数据块交付，避免每个字节一次异步循环和 Data.append。
/// 串行 delegate queue 负责缓冲；锁仅保护取消和 continuation 的一次性完成。
private final class ChunkedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    private var data = Data()

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func start(configuration: URLSessionConfiguration, request: URLRequest,
               continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() { finish(.failure(CancellationError())) }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !isFinished else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(CatSourceError.badResponse("下载失败 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")))
            return
        }
        let declared = http.expectedContentLength
        guard declared < 0 || declared <= Int64(maxBytes) else {
            completionHandler(.cancel)
            finish(.failure(CatSourceError.badResponse(
                "订阅内容超过大小上限（声明 \(BoundedDownloader.sizeDescription(Int(declared))) > 上限 \(BoundedDownloader.sizeDescription(maxBytes))），已拒绝下载")))
            return
        }
        data.reserveCapacity(Swift.min(maxBytes, declared >= 0 ? Int(declared) : 4 * 1024 * 1024))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !isFinished else { return }
        guard chunk.count <= maxBytes - data.count else {
            finish(.failure(CatSourceError.badResponse(
                "订阅内容超过大小上限（>\(BoundedDownloader.sizeDescription(maxBytes))），下载已中止")))
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(.failure(error))
            } else {
                finish(.failure(CatSourceError.badResponse("下载中断：\(error.localizedDescription)")))
            }
        } else {
            finish(.success(data))
        }
    }
}
