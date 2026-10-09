import Foundation

struct HistorySelection {
    private(set) var ids = Set<UUID>()
    private(set) var anchor: UUID?
    mutating func select(_ id: UUID, ordered: [UUID], command: Bool = false, shift: Bool = false) {
        guard ordered.contains(id) else { return }
        if shift, let anchor, let first = ordered.firstIndex(of: anchor), let last = ordered.firstIndex(of: id) {
            let range = Set(ordered[min(first, last)...max(first, last)])
            ids = command ? ids.union(range) : range
        } else if command {
            if !ids.insert(id).inserted { ids.remove(id) }
            anchor = id
        } else {
            ids = [id]
            anchor = id
        }
    }
    mutating func expand(_ visits: Set<UUID>, for representative: UUID) {
        if ids.contains(representative) { ids.formUnion(visits) } else { ids.subtract(visits) }
    }
    mutating func retain(_ ordered: [UUID]) {
        ids.formIntersection(ordered)
        if let anchor, !ordered.contains(anchor) { self.anchor = nil }
    }
    mutating func all(_ ordered: [UUID]) {
        ids = Set(ordered)
        anchor = ordered.first
    }
    mutating func clear() {
        ids = []
        anchor = nil
    }
}
