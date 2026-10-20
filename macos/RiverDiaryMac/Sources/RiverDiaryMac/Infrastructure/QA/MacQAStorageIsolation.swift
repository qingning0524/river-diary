import Foundation

enum MacQAStorageIsolation {
    static let qaBundleIdentifier = "studio.riverdiary.mac.qa"

    static func startupError(
        bundleIdentifier: String?,
        environment: [String: String],
        applicationSupportDirectory: URL?,
        temporaryDirectory: URL,
        sharedTemporaryDirectory: URL = URL(fileURLWithPath: "/tmp", isDirectory: true)
    ) -> String? {
        guard bundleIdentifier == qaBundleIdentifier else { return nil }

        guard let fixedHomePath = environment["CFFIXED_USER_HOME"], !fixedHomePath.isEmpty,
              let declaredQAHomePath = environment["RIVER_DIARY_MAC_QA_HOME"], !declaredQAHomePath.isEmpty,
              let realHomePath = environment["HOME"], !realHomePath.isEmpty else {
            return "QA 版本必须通过隔离启动器设置独立用户目录。"
        }

        let fixedHome = canonicalURL(fixedHomePath)
        let declaredQAHome = canonicalURL(declaredQAHomePath)
        let realHome = canonicalURL(realHomePath)
        guard fixedHome == declaredQAHome, fixedHome != realHome else {
            return "QA 版本拒绝使用正式用户目录。"
        }

        let allowedTemporaryRoots = [canonicalURL(temporaryDirectory), canonicalURL(sharedTemporaryDirectory)]
        guard allowedTemporaryRoots.contains(where: { isStrictDescendant(fixedHome, of: $0) }) else {
            return "QA 用户目录必须位于系统临时目录中。"
        }

        guard let applicationSupportDirectory,
              canonicalURL(applicationSupportDirectory) == canonicalURL(
                fixedHome.appendingPathComponent("Library/Application Support", isDirectory: true)
              ) else {
            return "QA 应用支持目录与隔离用户目录不匹配。"
        }

        return nil
    }

    private static func canonicalURL(_ path: String) -> URL {
        canonicalURL(URL(fileURLWithPath: path, isDirectory: true))
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isStrictDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = canonicalURL(child).pathComponents
        let parentComponents = canonicalURL(parent).pathComponents
        return childComponents.count > parentComponents.count
            && Array(childComponents.prefix(parentComponents.count)) == parentComponents
    }
}
