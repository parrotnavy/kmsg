import ApplicationServices.HIServices
import Foundation

/// Strict send-target checks shared by `send` and `send-image`.
///
/// The chat window must be titled exactly `expectTitle`, be the focused window,
/// own `input` when one is given, and (unless skipped) show every `expectRecent`
/// message in its transcript. Any mismatch throws and nothing is sent.
struct StrictTargetCheck {
    let expectTitle: String
    let expectRecent: [String]
    let traceAX: Bool

    func verify(
        _ window: UIElement,
        kakao: KakaoTalkApp,
        stage: String,
        input: UIElement? = nil,
        attachedSheet: UIElement? = nil,
        includeTranscript: Bool = true,
        newestOnly: Bool = false
    ) throws {
        let fail = { (reason: String) -> KakaoTalkError in
            KakaoTalkError.actionFailed("[TARGET_MISMATCH] \(stage): \(reason); not sending")
        }
        guard ChatWindowResolver.isExactTitle(window.title, expectTitle) else {
            throw fail("window title is '\(window.title ?? "")', expected '\(expectTitle)'")
        }
        if let attachedSheet {
            // While a sheet is up, macOS reports no focused window (or the sheet itself).
            // Require that this exact sheet is attached to the target window instead.
            let sheets: [AXUIElement] = window.attributeOptional(kAXSheetsAttribute) ?? []
            guard sheets.contains(where: { CFEqual($0, attachedSheet.axElement) })
                || Self.isDescendant(attachedSheet, of: window)
            else {
                throw fail("the confirmation sheet is not attached to the target chat window")
            }
            if let focused = kakao.focusedWindow,
               !CFEqual(focused.axElement, window.axElement),
               !CFEqual(focused.axElement, attachedSheet.axElement)
            {
                throw fail("focused window is '\(focused.title ?? "")', not the target chat")
            }
        } else {
            guard let focused = kakao.focusedWindow, CFEqual(focused.axElement, window.axElement) else {
                throw fail("focused window is '\(kakao.focusedWindow?.title ?? "none")', not the target chat")
            }
        }
        if let input {
            guard let owner: AXUIElement = input.attributeOptional(kAXWindowAttribute),
                  CFEqual(owner, window.axElement)
            else {
                throw fail("message input does not belong to the target chat window")
            }
        }
        // After a long message is typed the input grows and pushes older rows out of view,
        // so the check right before Enter only needs the newest expected message.
        let expected = newestOnly ? Array(expectRecent.prefix(1)) : expectRecent
        if includeTranscript && !expected.isEmpty {
            // Only the newest messages matter: read a short tail first, then a longer one before giving up
            // (a photo row or a window not scrolled to the bottom can push them out of the short tail).
            let reader = KakaoTalkTranscriptReader(kakao: kakao, runner: AXActionRunner(traceEnabled: traceAX))
            var missing = expected
            var bodyCount = 0
            var lastError: Error?
            for limit in [8, 16] {
                guard let snapshot = try? reader.readSnapshot(from: window, fallbackChatTitle: expectTitle, limit: limit) else {
                    lastError = TranscriptReadError.noMessageRows
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }
                let bodies = snapshot.messages.map { Self.normalizeForMatch($0.body) }.filter { !$0.isEmpty }
                bodyCount = bodies.count
                missing = expected.filter { candidate in
                    let want = Self.normalizeForMatch(candidate)
                    return !bodies.contains { body in
                        body == want || body.contains(want) || (body.count >= 8 && want.hasPrefix(body))
                    }
                }
                if missing.isEmpty { break }
            }
            if bodyCount == 0, let lastError {
                throw fail("could not read the chat transcript (\(lastError))")
            }
            guard missing.isEmpty else {
                throw fail("\(missing.count) of \(expected.count) expected recent messages are not in the window transcript (\(bodyCount) messages read)")
            }
            print("✓ Transcript matches \(expected.count) expected recent message(s) \(stage)")
        }
        print("✓ Target verified \(stage): '\(expectTitle)'")
    }

    static func isDescendant(_ element: UIElement, of ancestor: UIElement) -> Bool {
        var cursor = element.parent
        var hops = 0
        while let current = cursor, hops < 16 {
            if CFEqual(current.axElement, ancestor.axElement) { return true }
            cursor = current.parent
            hops += 1
        }
        return false
    }

    static func normalizeForMatch(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
