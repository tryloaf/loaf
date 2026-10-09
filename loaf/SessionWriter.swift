import Foundation

nonisolated struct SessionWrite: Sendable {
    let snapshot: BrowserSnapshot
    func encoded() throws -> Data { try JSONEncoder().encode(snapshot) }
}

nonisolated final class SessionWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    func reserve() -> Int {
        lock.lock()
        defer { lock.unlock() }
        revision += 1
        return revision
    }
    func isCurrent(_ candidate: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate == revision
    }
    @discardableResult func commit(_ data: Data, to file: URL, revision candidate: Int) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard candidate == revision else { return false }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }
}
