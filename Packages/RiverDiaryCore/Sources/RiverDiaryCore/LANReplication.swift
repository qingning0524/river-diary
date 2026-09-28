import Foundation
import MultipeerConnectivity

/// Exchanges the same immutable, AES-GCM replication objects used by the
/// iCloud directory. LAN never sends database rows or the shared key.
public final class RiverLANReplicator: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    public static let serviceType = "riverdiary-sync"
    private static let maximumObjectBytes = 16 * 1_024 * 1_024
    private static let chunkBytes = 48 * 1_024

    private struct Packet: Codable {
        let protocolVersion: Int
        let sourceDeviceID: String
        let stream: String
        let objectID: String
        let totalLength: Int
        let chunkIndex: Int
        let chunkCount: Int
        let bytes: Data
    }

    private struct IncomingObject {
        let sourceDeviceID: String
        let stream: String
        let objectID: String
        let totalLength: Int
        let chunkCount: Int
        var chunks: [Int: Data]
        var receivedBytes = 0
    }

    private let deviceID: RiverDeviceID
    private let directory: ReplicationDirectory
    private let key: SyncEncryptionKey
    private let queue = DispatchQueue(label: "riverdiary.lan-replication")
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var receiveBuffers: [String: Data] = [:]
    private var incomingObjects: [String: IncomingObject] = [:]
    private var receivedForReconciliation: Set<String> = []
    private var invitedPeers: Set<String> = []
    private var reconciliationScheduled = false
    private var hasStarted = false

    public var onStatusChange: ((String) -> Void)?
    public var onObjectsReceived: (() -> Void)?

    public init(deviceID: RiverDeviceID, directory: ReplicationDirectory, key: SyncEncryptionKey) {
        self.deviceID = deviceID
        self.directory = directory
        self.key = key
        let peer = MCPeerID(displayName: String(deviceID.rawValue.prefix(48)))
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["protocol": "1"], serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.hasStarted else { return }
            self.hasStarted = true
            self.advertiser.startAdvertisingPeer()
            self.browser.startBrowsingForPeers()
            self.report("正在查找同一 River Diary 的局域网设备")
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.hasStarted = false
            self.advertiser.stopAdvertisingPeer()
            self.browser.stopBrowsingForPeers()
            self.session.disconnect()
            self.receiveBuffers.removeAll()
            self.incomingObjects.removeAll()
            self.receivedForReconciliation.removeAll()
            self.invitedPeers.removeAll()
            self.reconciliationScheduled = false
            self.report("局域网复制已停止")
        }
    }

    /// Call after a normal sync publishes newly-created local objects.
    public func broadcast() {
        queue.async { [weak self] in
            guard let self, self.hasStarted else { return }
            for peer in self.session.connectedPeers { self.sendDirectoryObjects(to: peer) }
        }
    }

    private func report(_ value: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(value) }
    }

    private func sendDirectoryObjects(to peer: MCPeerID) {
        do {
            let permittedStreams: Set<String> = ["Events", "Operations", "Artifacts", "Manifest"]
            let objects = try directory.scanFiles().filter { permittedStreams.contains($0.stream) }
            var frames: [Data] = []
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for located in objects {
                let plaintext = try located.object.open(using: key)
                guard Self.kind(located.object.kind, matches: located.stream) else { continue }
                let objectBytes = try encoder.encode(located.object)
                guard objectBytes.count <= Self.maximumObjectBytes else { continue }
                let chunkCount = max(1, (objectBytes.count + Self.chunkBytes - 1) / Self.chunkBytes)
                for index in 0..<chunkCount {
                    let start = index * Self.chunkBytes
                    let end = min(objectBytes.count, start + Self.chunkBytes)
                    let chunk = objectBytes.subdata(in: start..<end)
                    let packet = Packet(
                        protocolVersion: 1,
                        sourceDeviceID: located.deviceID.rawValue,
                        stream: located.stream,
                        objectID: located.object.id,
                        totalLength: objectBytes.count,
                        chunkIndex: index,
                        chunkCount: chunkCount,
                        bytes: chunk
                    )
                    let payload = try encoder.encode(packet)
                    frames.append(Self.framed(payload))
                }
                _ = plaintext // Authentication is checked before forwarding opaque ciphertext.
            }
            frames.append(Data([0, 0, 0, 0]))
            for frame in frames {
                try session.send(frame, toPeers: [peer], with: .reliable)
            }
            report("已向 \(peer.displayName) 发送 \(objects.count) 个加密复制对象")
        } catch {
            report("局域网发送失败：\(error.localizedDescription)")
        }
    }

    private func receive(_ data: Data, from peerName: String) {
        var buffer = receiveBuffers[peerName, default: Data()]
        buffer.append(data)
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if length == 0 {
                buffer.removeFirst(4)
                continue
            }
            guard length <= Self.maximumObjectBytes else {
                report("局域网对象超过大小限制")
                receiveBuffers.removeValue(forKey: peerName)
                return
            }
            let frameLength = 4 + Int(length)
            guard buffer.count >= frameLength else { break }
            let payload = buffer.subdata(in: 4..<frameLength)
            buffer.removeSubrange(0..<frameLength)
            do {
                let packet = try JSONDecoder().decode(Packet.self, from: payload)
                try receive(packet, from: peerName)
            } catch {
                report("拒绝无效的局域网复制数据：\(error.localizedDescription)")
            }
        }
        receiveBuffers[peerName] = buffer
    }

    private func receive(_ packet: Packet, from peerName: String) throws {
        guard packet.protocolVersion == 1,
              packet.sourceDeviceID == peerName,
              Self.kindForStream(packet.stream) != nil,
              !packet.objectID.isEmpty,
              packet.totalLength > 0, packet.totalLength <= Self.maximumObjectBytes,
              packet.chunkCount > 0, packet.chunkCount <= 512,
              packet.chunkIndex >= 0, packet.chunkIndex < packet.chunkCount else {
            throw ReplicationIOError.invalidObjectPath
        }
        let key = "\(peerName)|\(packet.stream)|\(packet.objectID)"
        var incoming = incomingObjects[key] ?? IncomingObject(
            sourceDeviceID: packet.sourceDeviceID,
            stream: packet.stream,
            objectID: packet.objectID,
            totalLength: packet.totalLength,
            chunkCount: packet.chunkCount,
            chunks: [:]
        )
        guard incoming.totalLength == packet.totalLength,
              incoming.chunkCount == packet.chunkCount,
              incoming.chunks[packet.chunkIndex] == nil else {
            if incoming.chunks[packet.chunkIndex] == packet.bytes { return }
            incomingObjects.removeValue(forKey: key)
            throw ReplicationIOError.immutableObjectCollision(packet.objectID)
        }
        incoming.chunks[packet.chunkIndex] = packet.bytes
        incoming.receivedBytes += packet.bytes.count
        guard incoming.receivedBytes <= incoming.totalLength else {
            incomingObjects.removeValue(forKey: key)
            throw ReplicationIOError.invalidObjectPath
        }
        if incoming.chunks.count != incoming.chunkCount {
            incomingObjects[key] = incoming
            return
        }

        var objectBytes = Data()
        for index in 0..<incoming.chunkCount {
            guard let chunk = incoming.chunks[index] else { throw ReplicationIOError.invalidObjectPath }
            objectBytes.append(chunk)
        }
        guard objectBytes.count == incoming.totalLength else { throw ReplicationIOError.invalidObjectPath }
        let object = try JSONDecoder().decode(EncryptedReplicationObject.self, from: objectBytes)
        guard object.id == incoming.objectID,
              Self.kind(object.kind, matches: incoming.stream) else { throw ReplicationIOError.invalidObjectPath }
        _ = try object.open(using: self.key)
        let deviceID = RiverDeviceID(rawValue: incoming.sourceDeviceID)
        let shouldReconcile = receivedForReconciliation.insert(key).inserted
        if let existing = try directory.readObject(id: object.id, stream: incoming.stream, deviceID: deviceID) {
            guard existing == object else { throw ReplicationIOError.immutableObjectCollision(object.id) }
        } else {
            _ = try directory.publish(object, stream: incoming.stream, deviceID: deviceID)
        }
        if shouldReconcile { scheduleReconciliation() }
        incomingObjects.removeValue(forKey: key)
        report("已接收并验证 \(incoming.stream) 中的加密对象")
    }

    private func scheduleReconciliation() {
        guard !reconciliationScheduled else { return }
        reconciliationScheduled = true
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.reconciliationScheduled = false
            DispatchQueue.main.async { [weak self] in self?.onObjectsReceived?() }
        }
    }

    private static func framed(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var result = Data(bytes: &length, count: 4)
        result.append(payload)
        return result
    }

    private static func kindForStream(_ stream: String) -> String? {
        switch stream {
        case "Events": "event_batch"
        case "Operations": "state_operation_batch"
        case "Artifacts": "artifact_revision"
        case "Manifest": "manifest"
        default: nil
        }
    }

    private static func kind(_ kind: String, matches stream: String) -> Bool {
        kindForStream(stream) == kind
    }

    // MARK: MCSessionDelegate

    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        queue.async { [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                self.report("已连接局域网设备 \(name)，开始交换加密对象")
                if let peer = session.connectedPeers.first(where: { $0.displayName == name }) {
                    self.sendDirectoryObjects(to: peer)
                }
            case .notConnected:
                self.report("局域网设备已断开：\(name)")
                self.receiveBuffers.removeValue(forKey: name)
                self.invitedPeers.remove(name)
            case .connecting:
                self.report("正在连接局域网设备 \(name)")
            @unknown default:
                self.report("局域网连接状态未知")
            }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let name = peerID.displayName
        queue.async { [weak self] in self?.receive(data, from: name) }
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    // MARK: MCNearbyServiceAdvertiserDelegate

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        report("局域网广播无法启动：\(error.localizedDescription)")
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        queue.async { [weak self] in
            guard let self, self.hasStarted,
                  context == Data("riverdiary-sync-v1".utf8) else { invitationHandler(false, nil); return }
            invitationHandler(true, self.session)
        }
    }

    // MARK: MCNearbyServiceBrowserDelegate

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        report("局域网设备搜索无法启动：\(error.localizedDescription)")
    }

    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        queue.async { [weak self] in
            guard let self, self.hasStarted,
                  peerID.displayName != self.session.myPeerID.displayName,
                  self.deviceID.rawValue < peerID.displayName,
                  info?["protocol"] == "1",
                  self.invitedPeers.insert(peerID.displayName).inserted,
                  !self.session.connectedPeers.contains(peerID) else { return }
            self.browser.invitePeer(peerID, to: self.session, withContext: Data("riverdiary-sync-v1".utf8), timeout: 12)
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        report("局域网设备离开：\(peerID.displayName)")
    }
}
