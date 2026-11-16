import Foundation

/// What the engine needs from the network layer (faked in tests).
public protocol PushTransporting {
    func capabilities(_ endpoint: PushEndpoint, accept: [PushVersion]) async throws -> Capabilities
    func post(_ endpoint: PushEndpoint, batch: EncodedBatch, version: PushVersion) async throws -> Ack
}

extension PushTransport: PushTransporting {}
