import Combine
import CryptoKit
import Foundation
import ImageIO
import Photos
import RiverDiaryCore
import UIKit
import UniformTypeIdentifiers
import Vision

struct IPhonePhotoAIInput: Sendable {
    let assetToken: String
    let capturedAt: Date
    let localSummary: String
    let localCategory: String
    let jpegData: Data
}

@MainActor
final class IPhonePhotoAnalyzer: ObservableObject {
    private static let enabledKey = "river.photos.localAnalysis.enabled"
    private static let processedKey = "river.photos.localAnalysis.processedHashes.v1"

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var isScanning = false
    @Published private(set) var status = "照片识别未开启"
    @Published private(set) var errorMessage: String?

    private let database: RiverLocalDatabase
    private let imageManager = PHImageManager.default()
    private let thumbnailCache = NSCache<NSString, UIImage>()

    init(database: RiverLocalDatabase) {
        self.database = database
        thumbnailCache.countLimit = 12
        thumbnailCache.totalCostLimit = 14 * 1_024 * 1_024
    }

    /// Resolves a hashed, local photo token to a small thumbnail only while
    /// the user's current Photos permission permits it. No asset identifier
    /// or image data is written into a River event or sent to a service.
    func localThumbnail(for token: String, capturedAt: Date, maximumPixelSize: CGFloat = 520) async -> UIImage? {
        guard isEnabled else { return nil }
        let cacheKey = token as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) { return cached }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { return nil }
        let start = capturedAt.addingTimeInterval(-3)
        let end = capturedAt.addingTimeInterval(3)
        guard let asset = fetchAssets(from: start, to: end, limit: 12).first(where: {
            Self.sha256(Data($0.localIdentifier.utf8)) == token
        }) else { return nil }

        let targetSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        let manager = imageManager
        let image: UIImage? = await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, info in
                if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                continuation.resume(returning: image)
            }
        }
        if let image {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(maximumPixelSize * maximumPixelSize * 4)
            thumbnailCache.setObject(image, forKey: cacheKey, cost: cost)
        }
        return image
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        errorMessage = nil
        guard enabled else {
            status = "照片识别已暂停"
            return
        }

        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let result = current == .notDetermined ? await requestAuthorization() : current
        guard result == .authorized || result == .limited else {
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            status = result == .denied ? "照片权限未开启" : "照片权限受系统限制"
            return
        }
        await refreshRecentPhotos()
    }

    func refreshRecentPhotos(days: Int = 7) async {
        guard isEnabled else { return }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            status = "照片权限暂不可用"
            return
        }
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        errorMessage = nil

        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -max(1, days), to: end) ?? end.addingTimeInterval(-7 * 86_400)
        let assets = fetchAssets(from: start, to: end, limit: 160)
        var processed = Set(UserDefaults.standard.stringArray(forKey: Self.processedKey) ?? [])
        var insertedEvents: [RiverEvent] = []
        var added = 0
        var unavailable = 0

        for asset in assets {
            guard !Task.isCancelled, isEnabled, let capturedAt = asset.creationDate else { break }
            let tokenHash = Self.sha256(Data(asset.localIdentifier.utf8))
            let versionToken = Self.sha256(Data("\(asset.localIdentifier)|\(asset.modificationDate?.timeIntervalSince1970 ?? 0)".utf8))
            guard !processed.contains(versionToken) else { continue }
            guard let sourceData = await requestImageData(for: asset),
                  let analysis = await Self.classifyAndThumbnail(sourceData) else {
                unavailable += 1
                continue
            }
            let summary = Self.summary(for: analysis.labels)
            guard !summary.isEmpty else {
                processed.insert(versionToken)
                continue
            }

            let location = asset.location
            let payload = RiverEventPayload(
                latitude: location?.coordinate.latitude,
                longitude: location?.coordinate.longitude,
                horizontalAccuracy: location?.horizontalAccuracy,
                mediaSummary: summary,
                mediaCategory: Self.category(for: analysis.labels),
                mediaGroupID: tokenHash,
                photoCount: 1
            )
            do {
                let encoded = try JSONEncoder().encode(payload)
                let key = "photo-vision|\(versionToken)|\(Int(capturedAt.timeIntervalSince1970))"
                _ = try database.append(
                    id: RiverStableIdentifier.uuid(namespace: database.deviceID.rawValue, key: key),
                    source: "photos_vision",
                    kind: "media.photoObservation",
                    payload: payload,
                    observedAt: capturedAt,
                    sourceHash: Self.sha256(encoded),
                    refreshTimelineAfterAppend: false,
                    notifyLocalStateChange: false,
                    invalidateArtifactsAfterAppend: false,
                    onInserted: { insertedEvents.append($0) }
                )
                processed.insert(versionToken)
                added = insertedEvents.count
                await Task.yield()
            } catch {
                errorMessage = "照片线索保存失败：\(error.localizedDescription)"
                break
            }
        }

        UserDefaults.standard.set(Array(processed.suffix(2_000)), forKey: Self.processedKey)
        if added > 0 {
            do { try database.invalidateArtifactsForBatch(insertedEvents) }
            catch { errorMessage = "照片线索已保存，但结果刷新稍后重试：\(error.localizedDescription)" }
            database.refreshTimeline()
            NotificationCenter.default.post(name: .riverLocalNodeStateDidChange, object: database.deviceID.rawValue)
        }
        status = added > 0
            ? "已在本机整理 \(added) 张照片线索\(unavailable > 0 ? "；\(unavailable) 张尚未下载到设备" : "")"
            : unavailable > 0 ? "照片已授权；有 \(unavailable) 张仅在 iCloud 中" : "最近照片已检查，没有新增线索"
    }

    func recentAIInputs(from start: Date, to end: Date, limit: Int = 4) async -> [IPhonePhotoAIInput] {
        guard isEnabled,
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else { return [] }
        let assets = fetchAssets(from: start, to: end, limit: 160)
        guard !assets.isEmpty else { return [] }
        let sampleLimit = min(max(0, limit), assets.count)
        let sampleIndices: [Int]
        if sampleLimit == assets.count {
            sampleIndices = Array(assets.indices)
        } else {
            sampleIndices = (0..<sampleLimit).map { index in
                min(assets.count - 1, Int((Double(index) + 0.5) * Double(assets.count) / Double(sampleLimit)))
            }
        }
        var output: [IPhonePhotoAIInput] = []
        for index in sampleIndices {
            let asset = assets[index]
            guard let capturedAt = asset.creationDate,
                  let sourceData = await requestImageData(for: asset),
                  let analysis = await Self.classifyAndThumbnail(sourceData) else { continue }
            output.append(IPhonePhotoAIInput(assetToken: Self.sha256(Data(asset.localIdentifier.utf8)),
                                             capturedAt: capturedAt,
                                             localSummary: Self.summary(for: analysis.labels),
                                             localCategory: Self.category(for: analysis.labels),
                                             jpegData: analysis.jpegData))
        }
        return output
    }

    private func fetchAssets(from start: Date, to end: Date, limit: Int) -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@ AND mediaType == %d",
                                        start as NSDate, end as NSDate, PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: options)
        return (0..<result.count).map { result.object(at: $0) }
    }

    private func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
        }
    }

    private func requestImageData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                continuation.resume(returning: data)
            }
        }
    }

    private nonisolated static func classifyAndThumbnail(_ data: Data) async -> (labels: [String], jpegData: Data)? {
        await Task.detached(priority: .background) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 896
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let request = VNClassifyImageRequest()
            do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
            let labels = (request.results ?? [])
                .filter { $0.confidence >= 0.12 }
                .prefix(5)
                .map(\.identifier)
            guard !labels.isEmpty else { return nil }

            let mutableData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.62] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return (labels, mutableData as Data)
        }.value
    }

    private nonisolated static func summary(for labels: [String]) -> String {
        labels.prefix(4).map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: "、")
    }

    private nonisolated static func category(for labels: [String]) -> String {
        let text = labels.joined(separator: " ").lowercased()
        if ["food", "dish", "meal", "cuisine", "plate", "sushi", "pizza", "sandwich", "fruit"]
            .contains(where: text.contains) { return "food" }
        if ["landmark", "monument", "park", "mountain", "beach", "building", "temple", "castle"]
            .contains(where: text.contains) { return "landmark" }
        return "scene"
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
