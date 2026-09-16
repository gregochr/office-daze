import SwiftUI
import UIKit

/// What a Home Screen quick action asks the app to do.
///
/// There is one: long-press the icon, choose "Scan a booking", and the app
/// opens on the live scanner. It is the scan button pressed from the
/// springboard, and it ends on the flag that button sets — `HomeScreen`'s
/// `camera` — so there is one way to open the scanner rather than two that
/// could drift apart.
///
/// The item itself is declared in Info.plist. This is the half that says what
/// its type means.
enum QuickAction: Equatable {
    /// Straight onto the booking scanner.
    case scan

    /// The action a shortcut's type names, or nil for a type the app does not
    /// know.
    ///
    /// Matched exactly against `UIApplicationShortcutItemType` in Info.plist.
    /// They are one string written in two places, and a difference between them
    /// fails nowhere: the app simply opens on the home screen, which reads as a
    /// launch rather than as a bug. So QuickActionTests reads the plist back and
    /// holds every item on the icon to this table.
    static func action(for type: String) -> QuickAction? {
        switch type {
        case "com.thegregorysonline.officedaze.scan": .scan
        default: nil
        }
    }
}

/// The app delegate exists to name the scene delegate below, and does nothing
/// else.
///
/// A quick action is delivered to a scene delegate, and a SwiftUI app has none
/// of its own to put code in. The way to get one is to return a configuration
/// from here with the class filled in: SwiftUI then makes the instance for the
/// scene, forwards UIKit's scene callbacks to it and — because the class is
/// `@Observable` — puts it in the environment, which is how the screen that
/// owns the scanner hears about the action.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // The class and nothing else. SwiftUI still supplies the window and
        // everything in it, exactly as it does with no configuration at all.
        //
        // A cold launch's shortcut is in `options` here as well, and is left
        // there deliberately: the scene delegate is handed the same options,
        // and reading them there puts both launch paths in the one object the
        // screen can see.
        let configuration = UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// Where a quick action arrives, whichever way the app was opened.
///
/// There are two ways, and each only ever uses its own door. Opened by the
/// quick action, the app is handed it in the connection options, and
/// `windowScene(_:performActionFor:completionHandler:)` is never called.
/// Already running, it is handed to that method, and the connection is long
/// past. A handler on only one of them works when tried one way and does nothing
/// the other: Xcode's Run leaves the app running, so the warm door is the one a
/// developer tends to try, while a phone that has not opened the app since it
/// restarted comes in by the cold one.
///
/// Both doors lead to `receive(_:)`, and the action is only *held* here. The
/// flag that opens the scanner is `HomeScreen`'s own state, so the screen takes
/// the action when it can act on it — which, on a cold launch, is after this
/// delegate has already been told.
@Observable
final class SceneDelegate: NSObject, UIWindowSceneDelegate {

    /// The action waiting for a screen to act on it.
    private(set) var pendingQuickAction: QuickAction?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        receive(connectionOptions.shortcutItem)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(receive(shortcutItem))
    }

    /// Holds the action a shortcut names. False, with nothing held, for a launch
    /// with no shortcut in it or a type the app does not know — which is also
    /// the answer the warm path reports back to iOS.
    @discardableResult
    func receive(_ shortcut: UIApplicationShortcutItem?) -> Bool {
        guard let shortcut, let action = QuickAction.action(for: shortcut.type) else {
            return false
        }
        pendingQuickAction = action
        return true
    }

    /// Whether `action` was waiting, forgetting it if so. One press opens the
    /// scanner once, rather than again every time the screen that took it is
    /// drawn.
    func take(_ action: QuickAction) -> Bool {
        guard pendingQuickAction == action else { return false }
        pendingQuickAction = nil
        return true
    }
}
