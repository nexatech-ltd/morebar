import AppKit
import ScreenCaptureKit
import os

/// The two permissions a menu bar manager cannot live without:
///  - Accessibility: synthetic clicks/moves of other apps' icons and AX-based
///    source resolution;
///  - Screen Recording: snapshots of hidden icons and reading other apps'
///    window names.
///
/// macOS 26 quirks handled here:
///  - CGRequestScreenCaptureAccess() shows no prompt (broken since macOS 15),
///    so SCShareableContent is what triggers the Screen Recording prompt and
///    registers the app in the System Settings list;
///  - a Screen Recording grant only takes effect after the app is relaunched;
///  - MoreBar is an LSUIElement accessory app that is never frontmost. Firing
///    BOTH TCC prompts at once makes the window server drop one of them — the
///    dropped one never even registers in its Settings list, forcing the user
///    to add the app manually with "+". So the two requests are SEQUENCED
///    through the poll loop: only one prompt is ever outstanding, with a gap
///    between them, and the app is brought forward before each.
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
    private var ticks = 0
    private var accessibilityPrompted = false
    private var accessibilityPromptTick = 0
    private var screenRecordingPrompted = false

    /// Ticks to wait after the Accessibility prompt before triggering the
    /// Screen Recording one, so the two dialogs never race.
    private static let promptGapTicks = 3

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

    private static let log = Logger(subsystem: "dev.nexatech.MoreBar", category: "permissions")

    /// Starts the sequenced permission flow. Calls onGranted (once) when both
    /// permissions are in place.
    func requestIfNeeded() {
        Self.log.info("permissions at launch: AX=\(Self.accessibilityGranted) SR-preflight=\(Self.screenRecordingGranted)")
        guard Self.status != .granted else {
            Self.log.info("both already granted; needsRelaunch=\(Self.screenRecordingNeedsRelaunch)")
            onGranted?(false)
            return
        }
        // Deliberately do NOT trigger any prompt synchronously here — the poll
        // loop sequences them so two TCC dialogs never fire at once.
        startPolling()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        ticks += 1
        let ax = Self.accessibilityGranted
        let sr = Self.screenRecordingGranted

        if ax && sr {
            pollTimer?.invalidate()
            pollTimer = nil
            Self.log.info("both permissions granted")
            onGranted?(true)
            return
        }

        // Step 1: Accessibility, first and ALONE. The AX prompt is a system
        // dialog that stays up until the user acts; we must not raise the
        // Screen Recording prompt while it is open, or the two overlap and the
        // window server drops one (which then never registers). So we wait for
        // Accessibility to be GRANTED before touching Screen Recording.
        if !ax {
            if !accessibilityPrompted {
                Self.log.info("prompting for Accessibility")
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                accessibilityPrompted = true
                accessibilityPromptTick = ticks
            }
            return
        }

        // Step 2: Screen Recording, only after Accessibility is granted — the
        // AX dialog is gone by now, so this prompt appears cleanly on its own.
        if !sr && !screenRecordingPrompted {
            Self.log.info("requesting Screen Recording")
            triggerScreenRecordingPrompt()
            screenRecordingPrompted = true
        }
    }

    private func triggerScreenRecordingPrompt() {
        // SCShareableContent is the correct API to register the app in the
        // Screen Recording list and present the prompt. It only works when the
        // process is its OWN TCC responsible process — launching from a parent
        // that already holds the permission (e.g. a terminal) makes macOS
        // attribute the capture to that parent, so no prompt/record is created.
        SCShareableContent.getWithCompletionHandler { content, error in
            guard let error = error as NSError? else {
                Self.log.info("SCShareableContent ok: windows=\(content?.windows.count ?? -1, privacy: .public)")
                return
            }
            Self.log.info("SCShareableContent error: code=\(error.code, privacy: .public) desc=\(error.localizedDescription, privacy: .public)")
            // -3801 (SCStreamErrorUserDeclined) means the system will not
            // present the prompt for us — the app must be added manually.
            // Open the pane once so the user can do it without hunting.
            if error.code == -3801 {
                Task { @MainActor in Self.openScreenRecordingSettings() }
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
