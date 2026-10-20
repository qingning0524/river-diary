// Generated from 工具/catalog.py. Both targets import the same catalog and source.
import SwiftUI
public enum RiverGlyphName: String, CaseIterable, Identifiable {
    case river = "river"
    case today = "today"
    case footprints = "footprints"
    case confirmations = "confirmations"
    case memory = "memory"
    case review = "review"
    case profile = "profile"
    case timeline = "timeline"
    case journal = "journal"
    case edit = "edit"
    case quickNote = "quick-note"
    case calendar = "calendar"
    case search = "search"
    case filter = "filter"
    case bookmark = "bookmark"
    case tag = "tag"
    case insight = "insight"
    case understanding = "understanding"
    case chat = "chat"
    case reunion = "reunion"
    case chapter = "chapter"
    case replay = "replay"
    case futureLetter = "future-letter"
    case experiment = "experiment"
    case health = "health"
    case sleep = "sleep"
    case steps = "steps"
    case movement = "movement"
    case location = "location"
    case map = "map"
    case photo = "photo"
    case microphone = "microphone"
    case activity = "activity"
    case desktop = "desktop"
    case phone = "phone"
    case link = "link"
    case sync = "sync"
    case cloud = "cloud"
    case backup = "backup"
    case restore = "restore"
    case export = "export"
    case share = "share"
    case privacy = "privacy"
    case lock = "lock"
    case key = "key"
    case shield = "shield"
    case settings = "settings"
    case appearance = "appearance"
    case notifications = "notifications"
    case account = "account"
    case logout = "logout"
    case help = "help"
    case success = "success"
    case warning = "warning"
    case error = "error"
    case info = "info"
    case add = "add"
    case close = "close"
    case back = "back"
    case forward = "forward"
    case expand = "expand"
    case send = "send"
    case play = "play"
    case pause = "pause"
    case trash = "trash"
    case undo = "undo"
    case copy = "copy"
    case refresh = "refresh"
    case eye = "eye"
    case eyeOff = "eye-off"
    case download = "download"
    case contextPack = "context-pack"
    case habit = "habit"
    case goal = "goal"
    case progress = "progress"
    case database = "database"
    case source = "source"
    case evidence = "evidence"
    case more = "more"
    case chevronDown = "chevron-down"
    public var id: String { rawValue }
    public var assetName: String { "RiverGlyph" + rawValue.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() }
}
public struct RiverGlyphView: View {
    public enum State { case normal, selected }
    public let name: RiverGlyphName
    public var state: State
    public var size: CGFloat
    public init(_ name: RiverGlyphName, state: State = .normal, size: CGFloat = 20) {
        self.name = name; self.state = state; self.size = size
    }
    public var body: some View {
        Image(name.assetName + (state == .selected ? "Selected" : ""))
            .resizable().renderingMode(.original).interpolation(.high)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}
