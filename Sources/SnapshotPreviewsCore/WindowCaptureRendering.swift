//
//  WindowCaptureRendering.swift
//
//  eero fork addition — see UIKitRenderingStrategy.performRender.
//

#if canImport(UIKit) && !os(watchOS) && !os(visionOS) && !os(tvOS)
import Foundation
import UIKit
import SwiftUI

/// Renders a preview by mounting it FULL-SCREEN in the real key window and capturing the WHOLE window
/// after presentation settles — so a real `.sheet` / `.fullScreenCover` / `.presentationDetents`
/// (which present asynchronously into the window's presentation layer, ABOVE the previewed view)
/// appears in the snapshot with no author opt-in modifier.
///
/// This is opt-in via `EMERGE_PREVIEW_WINDOW_CAPTURE` and only reachable from the in-app render server
/// (`Snapshots` / `mise run preview`), never from the XCTest snapshot path — see the gate in
/// `UIKitRenderingStrategy.performRender`. The server consumes only `SnapshotResult.image`, so this
/// path supplies minimal metadata (the precision/tags/colorScheme fields are unused there).
enum WindowCaptureRendering {

  /// Whether the opt-in window-capture render path is active for this process.
  static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["EMERGE_PREVIEW_WINDOW_CAPTURE"] == "1"
  }

  /// Seconds to wait for asynchronous presentation (sheet/cover) to mount before capturing.
  /// Animations are disabled, so a presented sheet settles within a couple of runloop turns; the
  /// default is generous to stay robust on a cold simulator. Override with EMERGE_PREVIEW_SETTLE_SECONDS.
  private static var settleSeconds: Double {
    if let raw = ProcessInfo.processInfo.environment["EMERGE_PREVIEW_SETTLE_SECONDS"],
       let parsed = Double(raw), parsed >= 0 {
      return parsed
    }
    return 1.2
  }

  @MainActor
  static func render(
    preview: SnapshotPreviewsCore.Preview,
    window: UIWindow,
    completion: @escaping (SnapshotResult) -> Void
  ) {
    UIView.setAnimationsEnabled(false)

    // Wrap exactly as the standard path does (color-scheme bridging + Emerge modifier finder) so the
    // previewed view behaves identically; the captured color scheme is irrelevant on the server path.
    var wrapped: any View = preview.view().transaction { $0.disablesAnimations = true }
    wrapped = PreferredColorSchemeWrapper { AnyView(wrapped) }
    let host = UIHostingController(rootView: EmergeModifierView(wrapped: wrapped))
    host.view.backgroundColor = .clear

    // Mount full-screen so a detent/sheet lays out against the real device geometry (real safe-area
    // insets, real screen height) — the whole point of capturing a sheet faithfully.
    window.rootViewController = host
    host.view.frame = window.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.layoutIfNeeded()

    // Let SwiftUI commit the `.sheet`/`.fullScreenCover` presentation (asynchronous), then capture.
    DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) {
      window.layoutIfNeeded()
      CATransaction.flush()

      let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
      let image = renderer.image { _ in
        // Capture the WHOLE window — this includes any modally-presented sheet/cover and its dimming.
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }

      completion(SnapshotResult(
        image: .success(image),
        precision: nil,
        accessibilityEnabled: nil,
        colorScheme: nil,
        appStoreSnapshot: nil))
    }
  }
}
#endif
