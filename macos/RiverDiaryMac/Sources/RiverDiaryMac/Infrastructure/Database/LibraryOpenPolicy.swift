import Foundation

/// 资料生命周期：首次未绑定账号时不创建正式库。
///
/// 打开本机事实库只在三种情形成立：
/// - 已经存在正式库（受控离线使用与撤权后仍可读自己的资料）；
/// - 存在旧版本的本机日记状态（旧安装的救援路径，不能因为还没认领就封死）；
/// - 当前账号已登录（新建库并开始记录）。
///
/// 三者都不满足时只保留路径，等用户登录或显式认领后再建库。
enum LibraryOpenPolicy {
    static func shouldOpenLocalLibrary(
        hasDatabaseFile: Bool,
        hasLegacyLocalState: Bool,
        isSignedIn: Bool
    ) -> Bool {
        hasDatabaseFile || hasLegacyLocalState || isSignedIn
    }
}

/// 启动门禁用的存在性检查；只读文件系统，不创建目录或库文件。
enum LocalLibraryPresence {
    static func databaseFileExists(at url: URL? = V2Store.defaultDatabaseFileURL()) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 旧版本把日记状态写在 `journal.state`（加密）、`user-state.json`（迁移前明文），
    /// 或更早的 `Database/river-diary.db`。任一处存在都说明这是旧安装，不能延迟开库。
    static func legacyStateExists(in directory: URL? = defaultSupportDirectory()) -> Bool {
        guard let directory else { return false }
        let relativePaths = [
            "journal.state",
            "user-state.json",
            "Database/river-diary.db",
        ]
        return relativePaths.contains { relative in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path)
        }
    }

    static func defaultSupportDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RiverDiaryMac", isDirectory: true)
    }
}
