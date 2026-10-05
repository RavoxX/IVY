import Foundation

/// Allows one asynchronous selection read at a time. Invalidating a read prevents
/// its late result from showing a button, without queuing another read behind it.
public struct WritingSelectionPollGate {
    public struct Token: Equatable {
        fileprivate let id: UUID
        fileprivate let generation: UUID
    }
    private var generation = UUID()
    private var active: Token?

    public init() {}

    public mutating func begin() -> Token? {
        guard active == nil else { return nil }
        let token = Token(id: UUID(), generation: generation)
        active = token
        return token
    }

    public mutating func invalidate() { generation = UUID() }

    public mutating func finish(_ token: Token) -> Bool {
        guard active == token else { return false }
        active = nil
        return token.generation == generation
    }
}
