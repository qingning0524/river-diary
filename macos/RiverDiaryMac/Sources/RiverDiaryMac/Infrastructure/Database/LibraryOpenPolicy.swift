import Foundation

/// 资料生命周期：v5.0 本地优先，首次启动就开本机资料，账号只是后续增强。
///
/// 以前“首次未绑定不开库”的门禁会迫使所有用户先登录；现在：
/// - 新安装直接创建本机库并允许写日记；
/// - 已有库/旧安装仍按救援路径打开；
/// - 登录只用于绑定账号、官方额度、云副本与设备管理。
///
/// 参数保留是为了让调用方与旧测试继续表达“库/旧资料/登录”的事实，
/// 但不再参与是否开库的判断。
enum LibraryOpenPolicy {
    static func shouldOpenLocalLibrary(
        hasDatabaseFile: Bool,
        hasLegacyLocalState: Bool,
        isSignedIn: Bool
    ) -> Bool {
        _ = (hasDatabaseFile, hasLegacyLocalState, isSignedIn)
        return true
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
