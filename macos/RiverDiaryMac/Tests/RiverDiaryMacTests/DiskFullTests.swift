import XCTest
@testable import RiverDiaryMac

/// T05：真实磁盘写满（而不是权限拒绝）时，旧状态必须原样保留。
///
/// 用一块 8 MB 的临时磁盘镜像制造 ENOSPC；镜像无法创建/挂载时跳过，
/// 不让环境问题变成测试失败。
@MainActor
final class DiskFullTests: XCTestCase {
    func testRealDiskFullKeepsPreviousState() throws {
        let hdiutil = "/usr/bin/hdiutil"
        guard FileManager.default.isExecutableFile(atPath: hdiutil) else {
            throw XCTSkip("hdiutil unavailable")
        }

        let base = NSTemporaryDirectory() + "river-enospc-\(UUID().uuidString)"
        let imagePath = base + ".dmg"
        let mountPath = base + "-mnt"
        try FileManager.default.createDirectory(atPath: mountPath, withIntermediateDirectories: true)
        defer {
            _ = run(hdiutil, ["detach", mountPath, "-force"])
            try? FileManager.default.removeItem(atPath: mountPath)
            try? FileManager.default.removeItem(atPath: imagePath)
        }

        guard run(hdiutil, ["create", "-size", "8m", "-fs", "APFS", "-volname", "RiverENOSPC", "-ov", imagePath]) == 0,
              run(hdiutil, ["attach", "-nobrowse", "-mountpoint", mountPath, imagePath]) == 0 else {
            throw XCTSkip("could not attach a temporary disk image")
        }

        let support = mountPath + "/RiverDiaryMac"
        try FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        let store = DiaryStore(supportDirectory: URL(fileURLWithPath: support))
        let entry = DiaryEntry(pageID: "local-2026-10-20", date: "2026-10-20")
        try store.saveWriting(entry: entry, text: "第一版", mood: nil)

        let stateURL = URL(fileURLWithPath: support).appendingPathComponent("journal.state")
        let before = try Data(contentsOf: stateURL)

        // 先把卷写满：继续写入直到失败。
        let fillerURL = URL(fileURLWithPath: mountPath).appendingPathComponent("filler.bin")
        FileManager.default.createFile(atPath: fillerURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fillerURL)
        let chunk = Data(repeating: 0x41, count: 64 * 1024)
        while (try? handle.write(contentsOf: chunk)) != nil {}
        try? handle.close()

        let free = try XCTUnwrap(volumeAvailableCapacity(mountPath))
        XCTAssertLessThan(free, 2 * 1024 * 1024, "the test volume should be almost full")

        // 大文本 + 已满的卷：原子写拿不到空间，必须失败且不动旧文件。
        let big = String(repeating: "长", count: 200_000)
        XCTAssertThrowsError(try store.saveWriting(entry: entry, text: big, mood: nil))
        XCTAssertEqual(try Data(contentsOf: stateURL), before,
                       "a disk-full failure must not rewrite the previous state")
    }

    private func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func volumeAvailableCapacity(_ path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity
    }
}
