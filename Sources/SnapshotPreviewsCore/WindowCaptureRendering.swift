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
/// once presentation has settled — so a real `.sheet` / `.fullScreenCover` / `.presentationDetents`
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

  /// How long to wait for an asynchronous presentation (sheet/cover) to APPEAR before concluding the
  /// preview has none and capturing immediately. We do NOT sleep this long for a sheet — once a
  /// presentation is detected we capture on the next runloop turn (typically a few frames in). This
  /// only bounds the no-presentation case (the common full-screen screen preview). Animations are
  /// disabled, so SwiftUI commits `.sheet(isPresented: true)` within a couple of frames; the default
  /// is comfortably above the observed latency. Override with EMERGE_PREVIEW_PRESENT_GRACE_MS.
  private static var presentGraceMilliseconds: Int {
    if let raw = ProcessInfo.processInfo.environment["EMERGE_PREVIEW_PRESENT_GRACE_MS"],
       let parsed = Int(raw), parsed >= 0 {
      return parsed
    }
    return 250
  }

  /// Poll step. One step ≈ one display frame; animations are disabled so a sheet mounts within a
  /// handful of these, and we capture on the first turn after it is laid out.
  private static let pollStepMilliseconds = 16

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

    let start = DispatchTime.now()
    let graceDeadline = start.advanced(by: .milliseconds(presentGraceMilliseconds))

    func elapsedMs() -> Double {
      Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    // Poll each runloop turn. Two exits:
    //   • a presented VC exists AND is laid out (non-empty bounds) → a sheet/cover is up → capture now.
    //   • the grace window elapses with no presentation → this preview has no sheet → capture now.
    // So a `.sheet(isPresented: true)` is photographed a few frames after its present commits (fast),
    // and a plain screen preview waits only the short grace, never a fixed long sleep.
    func attemptCapture() {
      let presented = host.presentedViewController
      let presentationSettled = presented.map { !$0.view.bounds.isEmpty } ?? false
      let graceElapsed = DispatchTime.now() >= graceDeadline

      guard presentationSettled || graceElapsed else {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(pollStepMilliseconds)) {
          attemptCapture()
        }
        return
      }

      window.layoutIfNeeded()
      CATransaction.flush()

      NSLog("WindowCaptureRendering: captured after %.0f ms (sheet=%@)",
            elapsedMs(), presentationSettled ? "yes" : "none")

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

    // Kick off on the next runloop turn so SwiftUI has a chance to process `isPresented = true`.
    DispatchQueue.main.async { attemptCapture() }
  }
}
#endif
