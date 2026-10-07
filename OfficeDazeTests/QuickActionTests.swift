import Foundation
import Testing
import UIKit
@testable import OfficeDaze

/// The Home Screen quick action, from the plist to the scene delegate.
///
/// SpringBoard itself is out of reach: a long press on the icon needs a UI test
/// target, and there is none. Everything after the press can be reached — the
/// table that says what a shortcut's type means, the plist it has to agree
/// with, and the delegate both launch paths hand the shortcut to.
@Suite("The Home Screen quick action")
@MainActor
struct QuickActionTests {

    private static let scanType = "com.thegregorysonline.officedaze.scan"

    @Test("The scan shortcut's type names scanning, and matched exactly")
    func theScanTypeNamesScanning() {
        #expect(QuickAction.action(for: Self.scanType) == .scan)
        #expect(QuickAction.action(for: "com.thegregorysonline.officedaze.Scan") == nil, "matched exactly, not loosely")
        #expect(QuickAction.action(for: "scan") == nil)
        #expect(QuickAction.action(for: "") == nil)
    }

    /// The type is one string written in two places, and a difference between
    /// them fails nowhere — the icon offers "Scan a booking", and choosing it
    /// opens the app on the home screen. The test host is the app, so its
    /// bundle is the one whose icon carries these items.
    @Test("Every quick action on the icon is one the app acts on, and scanning is offered as the design has it")
    func thePlistAndTheTableAgree() throws {
        let items = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UIApplicationShortcutItems") as? [[String: String]]
        )
        #expect(!items.isEmpty)
        for item in items {
            let type = try #require(item["UIApplicationShortcutItemType"])
            #expect(QuickAction.action(for: type) != nil, "\(type) is on the icon and does nothing")
        }

        let scan = try #require(items.first { $0["UIApplicationShortcutItemType"] == Self.scanType })
        #expect(scan["UIApplicationShortcutItemTitle"] == "Scan a booking")
        #expect(scan["UIApplicationShortcutItemIconSymbolName"] == "viewfinder", "a viewfinder, not a camera")
    }

    /// The warm path, through the real delegate method. The scene is the test
    /// host's own, handed over only because the method asks for one; the
    /// delegate never looks at it.
    @Test("A shortcut delivered to the running app is held for the screen, and handed over once")
    func aWarmShortcutIsHeldAndTakenOnce() throws {
        let delegate = SceneDelegate()
        var handled: Bool?

        delegate.windowScene(
            try hostScene(),
            performActionFor: UIApplicationShortcutItem(type: Self.scanType, localizedTitle: "Scan a booking"),
            completionHandler: { handled = $0 }
        )

        #expect(handled == true, "iOS is told the action was handled")
        #expect(delegate.pendingQuickAction == .scan)
        #expect(delegate.take(.scan))
        #expect(!delegate.take(.scan), "one press opens the scanner once")
        #expect(delegate.pendingQuickAction == nil)
    }

    @Test("A shortcut the app does not know is reported unhandled, and nothing is left waiting")
    func anUnknownShortcutIsNotHandled() throws {
        let delegate = SceneDelegate()
        var handled: Bool?

        delegate.windowScene(
            try hostScene(),
            performActionFor: UIApplicationShortcutItem(type: "com.thegregorysonline.officedaze.gone", localizedTitle: "Gone"),
            completionHandler: { handled = $0 }
        )

        #expect(handled == false)
        #expect(delegate.pendingQuickAction == nil)
        #expect(!delegate.take(.scan))
    }

    /// The cold path hands `receive` whatever the connection options carried,
    /// and for every launch but a quick action that is nothing. The options
    /// themselves cannot be built outside UIKit, so this is as near to
    /// `scene(_:willConnectTo:options:)` as a test can get.
    @Test("A launch with no shortcut in it leaves nothing waiting, and one with a shortcut holds it")
    func aColdLaunchHoldsOnlyWhatItCarried() {
        let delegate = SceneDelegate()

        #expect(!delegate.receive(nil))
        #expect(delegate.pendingQuickAction == nil)
        #expect(!delegate.take(.scan))

        #expect(delegate.receive(UIApplicationShortcutItem(type: Self.scanType, localizedTitle: "Scan a booking")))
        #expect(delegate.take(.scan))
    }

    private func hostScene() throws -> UIWindowScene {
        try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    }
}
