import AppKit
import ApplicationServices
import Carbon.HIToolbox
import PickerCore
import os

enum InsertPayload {
    case text(String)
    case gif(data: Data, fileURL: URL)
    case pasteboardItems([[NSPasteboard.PasteboardType: Data]])
}

enum InsertOutcome {
    case pasted
    /// The payload is on the clipboard but could not be pasted; the UI shows "Copied, press ⌘V".
    case copiedOnly
}

@MainActor
final class Inserter {
    /// How long the payload stays on the clipboard before the user's clipboard is restored. GIFs
    /// get longer: apps that upload the file read the pasteboard later than a text paste.
    static func restoreDelay(for payload: InsertPayload) -> TimeInterval {
        if case .gif = payload { return 1.5 }
        return 0.5
    }
    private static let log = Logger(subsystem: "com.emojipicker.app", category: "inserter")

    private let pasteboard: NSPasteboard
    private var targetPID: pid_t?
    private var pendingSnapshot: PasteboardSnapshot?
    private var pendingRestore: DispatchWorkItem?
    private var ownOrder: [Int] = []
    /// changeCounts of the last ~20 pasteboard writes this Inserter made (payload, restore or
    /// clear). Restores carry no marker, so the clipboard monitor skips these counts instead.
    private(set) var ownChangeCounts: Set<Int> = []

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Call when the picker is presented: remembers the app that will receive the paste. If this
    /// app is frontmost (Settings or onboarding open), there is no target: picking only copies.
    func rememberTarget() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        targetPID = pid == getpid() ? nil : pid
    }

    private func recordOwnWrite() {
        let count = pasteboard.changeCount
        guard !ownChangeCounts.contains(count) else { return }
        ownOrder.append(count)
        ownChangeCounts.insert(count)
        if ownOrder.count > 20 { ownChangeCounts.remove(ownOrder.removeFirst()) }
    }

    func insert(_ payload: InsertPayload) -> InsertOutcome {
        // A restore is still pending and our payload is on the clipboard: keep the user's
        // original snapshot rather than capturing our own payload as "the original".
        let snapshot: PasteboardSnapshot
        if let pending = pendingSnapshot, pasteboard.types?.contains(OwnMarker.type) == true {
            snapshot = pending
        } else {
            snapshot = PasteboardSnapshot.capture(pasteboard)
        }
        pendingRestore?.cancel()
        pendingRestore = nil
        pendingSnapshot = nil

        guard write(payload) else {
            Self.log.error("failed to write payload to pasteboard")
            return .copiedOnly
        }
        let ourChangeCount = pasteboard.changeCount

        // Can't paste (no Accessibility permission, password field with Secure Input, or the
        // target app quit / is no longer frontmost): leave the payload on the clipboard, don't restore.
        let trusted = AXIsProcessTrusted()
        let secureInput = IsSecureEventInputEnabled()
        let frontmost = targetIsFrontmost()
        guard trusted, !secureInput, frontmost else {
            Self.log.info("""
                not pasting: accessibilityTrusted=\(trusted, privacy: .public) \
                secureInput=\(secureInput, privacy: .public) targetFrontmost=\(frontmost, privacy: .public) \
                target=\(self.targetPID.map(String.init) ?? "nil", privacy: .public) \
                frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", privacy: .public)
                """)
            return .copiedOnly
        }

        postCommandV()

        pendingSnapshot = snapshot
        let pb = pasteboard
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingSnapshot = nil
                self?.pendingRestore = nil
                // Someone (the user or the target app) changed the clipboard meanwhile: leave it alone.
                guard shouldRestore(currentChangeCount: pb.changeCount, ourChangeCount: ourChangeCount) else { return }
                if snapshot.containsSensitiveTypes {
                    // Never re-write a secret; just remove our payload.
                    pb.clearContents()
                } else {
                    snapshot.restore(to: pb)
                }
                self?.recordOwnWrite()
            }
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay(for: payload), execute: work)
        return .pasted
    }

    private func targetIsFrontmost() -> Bool {
        guard let pid = targetPID,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated
        else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private func write(_ payload: InsertPayload) -> Bool {
        pasteboard.clearContents()
        var items: [NSPasteboardItem] = []
        switch payload {
        case .text(let string):
            let item = NSPasteboardItem()
            item.setString(string, forType: .string)
            items.append(item)
        case .gif(let data, let fileURL):
            // One item, GIF bytes plus a file URL, deliberately with no TIFF/PNG: an app that finds a
            // still-image type tends to paste that (one frame). Expected per app (reasoned, not yet
            // confirmed in the hands-on check; record the actual result here):
            // - Slack, Teams (Chromium): read public.file-url as a file and upload the .gif, so it animates.
            //   Chromium ignores com.compuserve.gif data.
            // - Mail: a file URL becomes an attachment; an inline .gif animates.
            // - WhatsApp: takes the file URL or the GIF data.
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
            item.setString(fileURL.absoluteString, forType: .fileURL)
            items.append(item)
        case .pasteboardItems(let dicts):
            for dict in dicts {
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                items.append(item)
            }
        }
        // Marker rides on the first item (a separate empty item could confuse pasting apps).
        items.first?.setData(Data(), forType: OwnMarker.type)
        let ok = pasteboard.writeObjects(items)
        recordOwnWrite()
        return ok
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V) // 0x09
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
