import Foundation

/// Small generic fixed-capacity ring buffer (Spec §4.1). Value type: copying
/// PipelineState copies its rings, which is what keeps PipelineStep pure.
/// Backed by a fixed-size `[Element?]` + head index for cheap FIFO overwrite.
public struct RingBuffer<Element: Sendable & Equatable>: Sendable, Equatable {
    public private(set) var capacity: Int
    public private(set) var count: Int
    public private(set) var storage: [Element?]
    /// Index of the next write slot.
    private var head: Int = 0

    public init(capacity: Int) {
        let cap = max(1, capacity)
        self.capacity = cap
        self.count = 0
        self.storage = Array(repeating: nil, count: cap)
    }

    /// Appends, overwriting the oldest element when full.
    public mutating func push(_ e: Element) {
        storage[head] = e
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    /// Elements in insertion order, oldest first.
    public var elements: [Element] {
        guard count > 0 else { return [] }
        let start = (head - count + capacity) % capacity
        return (0..<count).compactMap { storage[(start + $0) % capacity] }
    }

    public mutating func removeAll(where predicate: (Element) -> Bool) {
        let kept = elements.filter { !predicate($0) }
        var rebuilt = RingBuffer(capacity: capacity)
        for element in kept {
            rebuilt.push(element)
        }
        self = rebuilt
    }

    public var isEmpty: Bool {
        count == 0
    }
}
