import Foundation

/// Drives P2P synchronization between iOS and watchOS apps over WCSession.
///
/// Connects `WCSessionCoordinator` (transport) to the local database.
/// Uses `SyncMessage` wire protocol for ping/pong cursor negotiation,
/// fetch/batch data exchange, and urgent alert notification.
public actor SyncEngine {

    // MARK: - State

    private let database: DatabaseManager
    private let hlc: HLC
    private let transport: WCSessionCoordinator
    private let samplesStore: SamplesStore
    private let tombstonesStore: SampleTombstonesStore

    private var isSyncing = false
    private var messageLoopTask: Task<Void, Never>?
    private var userInfoLoopTask: Task<Void, Never>?

    private var localPushCursor = SyncCursor()
    private let defaultLimit = 200

    // MARK: - Init

    public init(
        database: DatabaseManager,
        hlc: HLC,
        transport: WCSessionCoordinator
    ) {
        self.database = database
        self.hlc = hlc
        self.transport = transport
        self.samplesStore = SamplesStore(database: database)
        self.tombstonesStore = SampleTombstonesStore(database: database)
    }

    // MARK: - Start / Stop

    /// Starts background message-processing loops. Idempotent.
    public func start() async {
        if messageLoopTask != nil { return }

        try? await transport.activate()
        let transportRef = self.transport

        messageLoopTask = Task { [weak self] in
            for await msg in transportRef.messages {
                guard let self else { break }
                await self.handleIncomingMessage(msg)
            }
        }

        userInfoLoopTask = Task { [weak self] in
            for await userInfo in transportRef.userInfos {
                guard let self else { break }
                await self.handleUserInfo(userInfo)
            }
        }
    }

    /// Stops background loops. Idempotent.
    public func stop() async {
        messageLoopTask?.cancel()
        messageLoopTask = nil
        userInfoLoopTask?.cancel()
        userInfoLoopTask = nil
    }

    // MARK: - Interactive sync

    /// Performs a full interactive sync cycle: sends a ping with our
    /// cursor, receives the peer's pong, fetches/pushes as needed.
    public func triggerInteractiveSync() async throws {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let nodeID = await nodeIDString()

        // 1. Ping
        let ping = SyncMessage.ping(nodeID: nodeID, cursor: localPushCursor)
        let pingDict = try SyncMessageCodec.encode(ping)

        let replyDict: [String: Any]
        do {
            replyDict = try await transport.sendMessage(pingDict)
        } catch WCSessionError.notReachable {
            return
        }

        // 2. Decode pong
        let pong = try SyncMessageCodec.decode(replyDict)
        guard case .pong(let peerNodeID, let peerCursor) = pong else {
            Log.sync.warning("Expected pong, got \(String(describing: pong))")
            return
        }
        Log.sync.info("Received pong from \(peerNodeID)")

        // 3. Check if peer has newer data
        let localCursor = localPushCursor
        var peerHasNewer = false
        for node in peerCursor.knownNodes {
            let peerW = peerCursor.watermark(for: node)
            let localW = localCursor.watermark(for: node)
            let peerStamp = HLCStamped(physical: peerW.physical, logical: peerW.logical, nodeID: node)
            let localStamp = HLCStamped(physical: localW.physical, logical: localW.logical, nodeID: node)
            if peerStamp > localStamp {
                peerHasNewer = true
                break
            }
        }

        if peerHasNewer || localCursor.perNode.isEmpty {
            let fetch = SyncMessage.fetch(nodeID: nodeID, after: localCursor, limit: defaultLimit)
            let fetchDict = try SyncMessageCodec.encode(fetch)
            let batchReply = try await transport.sendMessage(fetchDict)
            let batchMsg = try SyncMessageCodec.decode(batchReply)

            if case .batch(_, let batchCursor, let recordsData) = batchMsg {
                try await applyBatch(recordsData: recordsData, cursor: batchCursor)
            } else {
                Log.sync.warning("Expected batch, got \(String(describing: batchMsg))")
            }
        }

        // 4. Push our data if ahead
        let ourNodeData = await hlc.currentLocal.nodeID
        let ourWatermark = localCursor.watermark(for: ourNodeData)
        let peerWatermark = peerCursor.watermark(for: ourNodeData)

        if ourWatermark.physical > peerWatermark.physical ||
            (ourWatermark.physical == peerWatermark.physical && ourWatermark.logical > peerWatermark.logical) {

            let samples = try await samplesStore.fetchForSync(
                nodeID: ourNodeData,
                afterHLC: peerWatermark.physical,
                lc: peerWatermark.logical,
                limit: defaultLimit
            )

            if !samples.isEmpty {
                let recordsData = try JSONEncoder().encode(samples)
                var pushCursor = localPushCursor
                for row in samples {
                    pushCursor.advance(
                        nodeID: row.nodeID,
                        physical: row.hlcPhysical,
                        logical: row.hlcLogical
                    )
                }
                let batch = SyncMessage.batch(nodeID: nodeID, cursor: pushCursor, recordsData: recordsData)
                let batchDict = try SyncMessageCodec.encode(batch)
                _ = try await transport.sendMessage(batchDict)
                localPushCursor = pushCursor
            }
        }
    }

    // MARK: - Incoming message handlers

    internal func handleIncomingMessage(_ msg: WCSessionCoordinator.IncomingMessage) async {
        let payload = msg.payload
        do {
            let message = try SyncMessageCodec.decode(payload)
            switch message {

            case .ping(let remoteNodeID, _):
                let nodeID = await nodeIDString()
                let pong = SyncMessage.pong(nodeID: nodeID, cursor: localPushCursor)
                let pongDict = try SyncMessageCodec.encode(pong)
                msg.replyHandler(pongDict)
                Log.sync.info("Replied pong to \(remoteNodeID)")

            case .fetch(_, let after, let limit):
                let ourNodeData = await hlc.currentLocal.nodeID
                let watermark = after.watermark(for: ourNodeData)
                let samples = try await samplesStore.fetchForSync(
                    nodeID: ourNodeData,
                    afterHLC: watermark.physical,
                    lc: watermark.logical,
                    limit: limit
                )
                let recordsData = try JSONEncoder().encode(samples)
                let nodeID = await nodeIDString()
                let batch = SyncMessage.batch(nodeID: nodeID, cursor: localPushCursor, recordsData: recordsData)
                let batchDict = try SyncMessageCodec.encode(batch)
                msg.replyHandler(batchDict)
                Log.sync.info("Replied batch (n=\(samples.count))")

            case .batch(_, let batchCursor, let recordsData):
                try await applyBatch(recordsData: recordsData, cursor: batchCursor)

            case .urgent(let remoteNodeID, let latestHLC):
                _ = try? await hlc.observe(latestHLC)
                Log.sync.info("Received urgent signal from \(remoteNodeID)")

            case .pong:
                Log.sync.warning("Unsolicited pong ignored")
            }
        } catch {
            Log.sync.error("Failed to process incoming message: \(error)")
        }
    }

    internal func handleUserInfo(_ userInfo: [String: Any]) async {
        do {
            let message = try SyncMessageCodec.decode(userInfo)
            switch message {
            case .urgent(let remoteNodeID, let latestHLC):
                _ = try? await hlc.observe(latestHLC)
                Log.sync.info("Background urgent signal from \(remoteNodeID)")
            case .batch(_, let batchCursor, let recordsData):
                try await applyBatch(recordsData: recordsData, cursor: batchCursor)
            default:
                Log.sync.warning("Unhandled userInfo message type: \(String(describing: message))")
            }
        } catch {
            Log.sync.error("Failed to process userInfo: \(error)")
        }
    }

    // MARK: - Batch apply

    private func applyBatch(recordsData: Data, cursor: SyncCursor) async throws {
        let samples = try JSONDecoder().decode([SampleRow].self, from: recordsData)

        for row in samples {
            let stamp = HLCStamped(
                physical: row.hlcPhysical,
                logical: row.hlcLogical,
                nodeID: row.nodeID
            )
            _ = try? await hlc.observe(stamp)
        }

        try await database.writer { db in
            try SamplesStore.upsertHLCLatest(samples, in: db)
        }

        for row in samples {
            localPushCursor.advance(
                nodeID: row.nodeID,
                physical: row.hlcPhysical,
                logical: row.hlcLogical
            )
        }

        Log.sync.info("Applied \(samples.count) sample(s) from peer batch")
    }

    // MARK: - Helpers

    private func nodeIDString() async -> String {
        await hlc.currentLocal.nodeID.hlcHexString
    }
}
