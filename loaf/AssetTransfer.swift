import Foundation

nonisolated struct AssetBody {
    let limit: Int
    private(set) var data = Data()
    mutating func accept(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            throw AssetHTTPError(status: http.statusCode, host: response.url?.host ?? "server")
        }
        guard response.expectedContentLength <= limit else { throw CocoaError(.fileReadTooLarge) }
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
    }
    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= limit - data.count else { throw CocoaError(.fileReadTooLarge) }
        data.append(chunk)
    }
}

nonisolated final class AssetTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var body: AssetBody
    private var result: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionDataTask?
    private var redirects = 0
    init(limit: Int) { body = AssetBody(limit: limit) }
    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Data, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            task.cancel()
            continuation.resume(with: result)
            return false
        }
        self.task = task
        self.continuation = continuation
        lock.unlock()
        task.resume()
        return true
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let callback = continuation
        let task = task
        continuation = nil
        self.task = nil
        lock.unlock()
        if case .failure = result { task?.cancel() }
        callback?.resume(with: result)
    }
    func cancel() { finish(.failure(CancellationError())) }
    func accept(_ response: URLResponse) -> Bool {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return false
        }
        do {
            try body.accept(response)
            lock.unlock()
            return true
        } catch {
            lock.unlock()
            finish(.failure(error))
            return false
        }
    }
    func append(_ chunk: Data) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        do {
            try body.append(chunk)
            lock.unlock()
        } catch {
            lock.unlock()
            finish(.failure(error))
        }
    }
    func complete(_ error: Error?) {
        lock.lock()
        let data = body.data
        lock.unlock()
        finish(error.map { .failure($0) } ?? .success(data))
    }
    func allowRedirect(_ request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        redirects += 1
        return result == nil && redirects <= 5 && request.url?.scheme == "https" && request.url?.user == nil
            && request.url?.password == nil
    }
}

nonisolated final class AssetTransfers: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: AssetTransfer] = [:]
    func register(_ transfer: AssetTransfer, task: URLSessionDataTask) {
        lock.lock()
        transfers[task.taskIdentifier] = transfer
        lock.unlock()
    }
    func remove(_ id: Int) {
        lock.lock()
        transfers.removeValue(forKey: id)
        lock.unlock()
    }
    private func transfer(_ id: Int) -> AssetTransfer? {
        lock.lock()
        defer { lock.unlock() }
        return transfers[id]
    }
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(transfer(dataTask.taskIdentifier)?.accept(response) == true ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer(dataTask.taskIdentifier)?.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        transfer(task.taskIdentifier)?.complete(error)
        remove(task.taskIdentifier)
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(transfer(task.taskIdentifier)?.allowRedirect(request) == true ? request : nil)
    }
}

nonisolated struct AssetHTTPError: LocalizedError {
    let status: Int
    let host: String
    var errorDescription: String? {
        if status == 204 || status == 404 { return "\(host) did not provide a compatible package (HTTP \(status))." }
        return "\(host) returned HTTP \(status). Try again after checking your connection."
    }
}
