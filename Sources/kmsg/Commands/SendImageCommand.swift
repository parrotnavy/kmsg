import ArgumentParser
import AppKit
import Foundation

struct SendImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send-image",
        abstract: "Send an image to a chat"
    )

    @Argument(help: "Name of the chat or friend to send to")
    var recipient: String

    @Argument(help: "Path to the image file")
    var imagePath: String

    @Option(
        name: .long,
        help: "Strict mode: send only to the one chat titled exactly this. Ambiguity or mismatch aborts; the target is re-checked right before pasting and right before the send button."
    )
    var expectTitle: String?

    @Option(
        name: .long,
        help: "Strict mode (with --expect-title): a recent message of the target chat. Repeatable. Every one must appear in the window transcript."
    )
    var expectRecent: [String] = []

    @Flag(name: .long, help: "Don't actually send, just show what would happen")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Flag(name: .long, help: "Disable AX path cache for this run")
    var noCache: Bool = false

    @Flag(name: [.short, .long], help: "Keep chat and list windows open after sending image")
    var keepWindow: Bool = false

    @Flag(name: .long, help: "Enable deep window recovery when fast window detection fails")
    var deepRecovery: Bool = false

    func validate() throws {
        if !expectRecent.isEmpty && expectTitle == nil {
            throw ValidationError("--expect-recent requires --expect-title.")
        }
    }

    private var strictCheck: StrictTargetCheck? {
        expectTitle.map { StrictTargetCheck(expectTitle: $0, expectRecent: expectRecent, traceAX: traceAX) }
    }

    func run() throws {
        if dryRun {
            print("Dry run mode - no image will be sent")
            print("Recipient: \(recipient)")
            print("Image: \(imagePath)")
            if let expectTitle {
                print("Expect title: \(expectTitle)")
            }
            if !expectRecent.isEmpty {
                print("Expect recent messages: \(expectRecent.count)")
            }
            return
        }

        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
        let imageURL = URL(fileURLWithPath: imagePath)

        guard FileManager.default.fileExists(atPath: imagePath) else {
            print("Error: File not found at \(imagePath)")
            throw ExitCode.failure
        }

        let kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        let chatWindowResolver = ChatWindowResolver(
            kakao: kakao,
            runner: runner,
            useCache: !noCache,
            deepRecoveryEnabled: deepRecovery,
            expectedTitle: expectTitle
        )

        var openedResolution: ChatWindowResolution?
        do {
            print("Looking for chat with '\(recipient)'...")
            let resolution = try chatWindowResolver.resolve(query: recipient)
            openedResolution = resolution

            try sendImageToWindow(imageURL, window: resolution.window, kakao: kakao, runner: runner)
            closeWindowsIfNeeded(
                resolution: resolution,
                kakao: kakao,
                resolver: chatWindowResolver,
                runner: runner
            )
        } catch {
            print("Failed to send image: \(error)")
            if expectTitle != nil, !keepWindow, let openedResolution, openedResolution.openedTransiently {
                _ = chatWindowResolver.closeWindow(openedResolution.window)
            }
            throw ExitCode.failure
        }
    }

    private func sendImageToWindow(_ imageURL: URL, window: UIElement, kakao: KakaoTalkApp, runner: AXActionRunner) throws {
        // 1. Copy image to clipboard
        guard let image = NSImage(contentsOf: imageURL) else {
            throw KakaoTalkError.actionFailed("Failed to load image from \(imageURL.path)")
        }

        // 2. Activate KakaoTalk and focus window
        kakao.activate()
        try? window.focus()
        Thread.sleep(forTimeInterval: 0.3)

        try strictCheck?.verify(window, kakao: kakao, stage: "before paste")
        if strictCheck != nil {
            // The transcript read can take seconds and move focus; bring the chat back, re-check cheaply.
            kakao.activate()
            try? window.focus()
            Thread.sleep(forTimeInterval: 0.2)
            try strictCheck?.verify(window, kakao: kakao, stage: "at paste", includeTranscript: false)
        }

        let pasteboard = NSPasteboard.general
        let savedItems = Self.snapshotPasteboard(pasteboard)
        defer { Self.restorePasteboard(pasteboard, items: savedItems) }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])

        runner.log("Image copied to clipboard")

        // 3. Paste image
        runner.pressPaste()
        runner.log("Paste command sent")

        // 4. Confirmation sheet can be transient or skipped entirely depending on KakaoTalk state.
        if let confirmationSheet = waitForConfirmationSheet(in: window, runner: runner) {
            runner.log("Confirmation sheet found")
            Thread.sleep(forTimeInterval: 0.2)

            guard let button = findSendButton(in: confirmationSheet) else {
                if strictCheck != nil {
                    runner.pressEscape()
                    throw KakaoTalkError.elementNotFound("[TARGET_MISMATCH] send button not found on the confirmation sheet; strict mode does not guess")
                }
                if !waitForSendCompletion(in: window, confirmationSheet: confirmationSheet, runner: runner) {
                    throw KakaoTalkError.elementNotFound("Send button not found on confirmation sheet")
                }
                runner.log("send-image: sheet vanished before button lookup; treating as success")
                print("✓ Image sent to '\(recipient)'")
                Thread.sleep(forTimeInterval: 0.5)
                return
            }

            do {
                try strictCheck?.verify(window, kakao: kakao, stage: "before send button", attachedSheet: confirmationSheet, includeTranscript: false)
            } catch {
                runner.pressEscape()
                throw error
            }

            if !runner.clickWithRetry(button, label: "send button"),
               !waitForSendCompletion(in: window, confirmationSheet: confirmationSheet, runner: runner)
            {
                throw KakaoTalkError.actionFailed("Failed to click send button after retries")
            }
        } else {
            if strictCheck != nil {
                throw KakaoTalkError.actionFailed("[TARGET_MISMATCH] confirmation sheet did not appear; strict mode cannot verify before sending")
            }
            runner.log("send-image: confirmation sheet not observed; allowing direct-send path")
            Thread.sleep(forTimeInterval: 0.7)
        }

        print("✓ Image sent to '\(recipient)'")

        // Give it a moment to finish sending
        Thread.sleep(forTimeInterval: 0.5)
    }

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restorePasteboard(_ pasteboard: NSPasteboard, items: [NSPasteboardItem]) {
        // Give KakaoTalk time to read the pasted image before the clipboard changes back.
        Thread.sleep(forTimeInterval: 0.5)
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private func closeWindowsIfNeeded(
        resolution: ChatWindowResolution,
        kakao: KakaoTalkApp,
        resolver: ChatWindowResolver,
        runner: AXActionRunner
    ) {
        guard !keepWindow else {
            runner.log("send-image: keep-window enabled; skipping auto-close")
            return
        }

        if resolver.closeWindow(resolution.window) {
            print("✓ Chat window closed.")
        } else {
            runner.log("send-image: close window could not be verified")
        }

        if let listWindow = kakao.chatListWindow,
           !areSameAXElement(listWindow, resolution.window)
        {
            if resolver.closeWindow(listWindow) {
                runner.log("send-image: chat list window closed")
            } else {
                runner.log("send-image: chat list window could not be verified")
            }
        }
    }

    private func waitForConfirmationSheet(in window: UIElement, runner: AXActionRunner) -> UIElement? {
        var sheet: UIElement?
        _ = runner.waitUntil(label: "confirmation sheet", timeout: 1.5, pollInterval: 0.1) {
            sheet = locateConfirmationSheet(in: window)
            return sheet != nil
        }
        return sheet
    }

    private func locateConfirmationSheet(in window: UIElement) -> UIElement? {
        if let found = window.attributeOptional(kAXSheetsAttribute).flatMap({ (elements: [AXUIElement]) in elements.first }) {
            return UIElement(found)
        }
        return window.findFirst(where: { $0.role == kAXSheetRole })
    }

    private func findSendButton(in confirmationSheet: UIElement) -> UIElement? {
        confirmationSheet.findAll(role: kAXButtonRole).first { button in
            let title = (button.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title == "전송" || title == "Send"
        }
    }

    private func waitForSendCompletion(
        in window: UIElement,
        confirmationSheet: UIElement,
        runner: AXActionRunner
    ) -> Bool {
        runner.waitUntil(label: "send-image completion", timeout: 1.5, pollInterval: 0.1) {
            locateConfirmationSheet(in: window) == nil || !windowContainsElement(window, target: confirmationSheet)
        }
    }

    private func windowContainsElement(_ window: UIElement, target: UIElement) -> Bool {
        window.findFirst(where: { candidate in
            areSameAXElement(candidate, target)
        }) != nil
    }

    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }
}
