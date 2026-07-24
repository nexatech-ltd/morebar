import AppKit
import ScreenCaptureKit
import os

/// The two permissions a menu bar manager cannot live without:
///  - Accessibility: synthetic clicks/moves of other apps' icons and AX-based
///    source resolution;
///  - Screen Recording: snapshots of hidden icons and reading other apps'
///    window names.
///
/// macOS 26 quirks: CGRequestScreenCaptureAccess() shows no prompt (broken
/// since macOS 15) — we poke SCShareableContent instead; a Screen Recording
/// grant only takes effect after the app is relaunched.
@MainActor
final class PermissionsManager {
    enum Status {
        case granted
        case missingAccessibility
        case missingScreenRecording
        case missingBoth
    }

    /// Called once both permissions are in place. `freshlyGranted` means they
    /// were granted just now (this session, via polling) rather than being
    /// present since the previous launch.
    var onGranted: ((_ freshlyGranted: Bool) -> Void)?

    private var pollTimer: Timer?

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static var status: Status {
        switch (accessibilityGranted, screenRecordingGranted) {
        case (true, true): .granted
        case (false, true): .missingAccessibility
        case (true, false): .missingScreenRecording
        case (false, false): .missingBoth
        }
    }

    private static let log = Logger(subsystem: "com.nexatech.MoreBar", category: "permissions")

    /// Requests any missing permissions (system prompts) and starts polling.
    /// Calls onGranted (once) when both are in place.
    func requestIfNeeded() {
        Self.log.info("permissions: AX=\(Self.accessibilityGranted) SR-preflight=\(Self.screenRecordingGranted)")
        guard Self.status != .granted else {
            Self.log.info("both permissions report granted; needsRelaunch=\(Self.screenRecordingNeedsRelaunch)")
            onGranted?(false)
            return
        }
        if !Self.accessibilityGranted {
            Self.log.info("prompting for Accessibility")
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        if !Self.screenRecordingGranted {
            // Triggers the system Screen Recording prompt and makes the app
            // appear in the System Settings list.
            Self.log.info("requesting Screen Recording via SCShareableContent")
            SCShareableContent.getWithCompletionHandler { content, error in
                Self.log.info("SCShareableContent result: windows=\(content?.windows.count ?? -1) error=\(String(describing: error))")
            }
        }
        startPolling()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, Self.status == .granted else { return }
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.onGranted?(true)
            }
        }
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// A Screen Recording grant only applies after a relaunch — we use that:
    /// the right is present in TCC, but windows are still "unreadable"
    /// in this process, so a relaunch is required.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    /// Screen Recording is granted but not yet effective in this process
    /// (the usual state right after granting) — detected as: preflight true,
    /// yet other apps' window names are unreadable.
    static var screenRecordingNeedsRelaunch: Bool {
        guard screenRecordingGranted else { return false }
        let readable = WindowInfo.statusItemWindows()
            .contains { $0.ownerPID != ProcessInfo.processInfo.processIdentifier && $0.name != nil }
        return !readable
    }
}
