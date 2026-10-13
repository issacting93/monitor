// Notifications.swift — telling the user a long job finished while they were away
//
// Stage 9 of §9. A mixdown of eight tracks takes long enough to leave the room for,
// and the app's only report on finishing was a status string in a window the user was
// not looking at. This is the announcement for exactly that case and no other.

#if os(macOS)
import AppKit
import UserNotifications

enum Notifications {

    /// Whether the system has granted permission, and whether we have asked yet.
    ///
    /// Read and written from the main thread only — both call sites are edit completions,
    /// which `runOffMain` applies on main. A lock would suggest otherwise.
    private static var isAuthorized = false
    private static var hasAsked = false

    /// Announces that a long job finished, **unless the app is frontmost**.
    ///
    /// The "unless" is the design, not a nicety. A status line the user is already
    /// looking at says the same thing, and a banner over it is noise — Apple's own rule
    /// for notifications, and the reason this is a guard rather than a preference.
    /// (It is also belt-and-braces: with no `UNUserNotificationCenterDelegate`
    /// installed, macOS suppresses banners from a frontmost app anyway, so a mistake
    /// here degrades to "nothing happens" rather than to a duplicate.)
    ///
    /// Permission is requested at the first completion that would actually be posted,
    /// never at launch. A system prompt on first run, for a feature most sessions never
    /// reach, is the other half of the same restraint; and a prompt is only worth
    /// showing at the moment the user has a reason to say yes.
    static func completion(title: String, body: String) {
        guard !NSApp.isActive else { return }

        if hasAsked {
            if isAuthorized { post(title: title, body: body) }
            return
        }
        // Once only. Asking again after a refusal prompts nothing and is not a second
        // chance, so there is no path back to `requestAuthorization`.
        hasAsked = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async {
                    isAuthorized = granted
                    if granted { post(title: title, body: body) }
                }
            }
    }

    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // The job is finished and the app is in the background: there is no window to
        // look at, so the sound is the part that reaches the user. Restraint about
        // *when* to notify is not the same as notifying silently.
        content.sound = .default

        // A nil trigger delivers immediately. The identifier is per-notification rather
        // than a fixed string so two completions in a row are two banners instead of the
        // second replacing the first.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
#endif
