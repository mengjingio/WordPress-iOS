import Foundation

struct AppStoreInfoViewModel {
    let appName: String
    let version: String
    let releaseNotes: [String.SubSequence]
    let onUpdateTapped: () -> Void

    let title = Strings.title
    let message = Strings.message
    let whatsNewTitle = Strings.whatsNew
    let updateButtonTitle = Strings.Actions.update
    let cancelButtonTitle = Strings.Actions.cancel
    let moreInfoButtonTitle = Strings.Actions.moreInfo

    init(_ appStoreInfo: AppStoreInfo, onUpdateTapped: @escaping () -> Void) {
        self.appName = appStoreInfo.trackName
        self.version = String(format: Strings.versionFormat, appStoreInfo.version)
        self.releaseNotes = appStoreInfo.releaseNotes.split(whereSeparator: \.isNewline)
        self.onUpdateTapped = onUpdateTapped
    }
}

private enum Strings {
    static let versionFormat = NSLocalizedString("inAppUpdate.versionFormat", value: "Version %@", comment: "Format for latest version available")
    static let title = NSLocalizedString("inAppUpdate.title", value: "App Update Available", comment: "Title for view displayed when there's a newer version of the app available")
    static let message = NSLocalizedString("inAppUpdate.message", value: "To use this app, download the latest version.", comment: "Message for view displayed when there's a newer version of the app available")
    static let whatsNew = NSLocalizedString("blockingUpdate.whatsNew", value: "What's New", comment: "Section title for what's new in the latest update available")

    enum Actions {
        static let update = NSLocalizedString("inAppUpdate.action.update", value: "Update", comment: "Update button title")
        static let cancel = NSLocalizedString("inAppUpdate.action.cancel", value: "Cancel", comment: "Cancel button title")
        static let moreInfo = NSLocalizedString("blockiaction.action.moreInfo", value: "More info", comment: "More info button title")
    }
}
