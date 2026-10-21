import Foundation

/// Public legal and service pages linked from both apps' About screens.
///
/// Kept in the shared core so macOS and iOS cannot drift to different pages or
/// schemes. These are plain HTTPS URLs; opening them is always a user action.
public enum RiverLegalLinks {
    public static let privacyPolicy = URL(string: "https://flowriver.xyz/privacy.html")!
    public static let terms = URL(string: "https://flowriver.xyz/terms.html")!
    public static let serviceStatus = URL(string: "https://flowriver.xyz/status")!
    public static let securityContact = URL(string: "https://flowriver.xyz/.well-known/security.txt")!
}
