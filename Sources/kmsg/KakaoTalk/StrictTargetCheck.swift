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
        includeTranscript: Bool = true
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
        if includeTranscript && !expectRecent.isEmpty {
            // Only the newest messages matter, so read a short tail; retry once while a fresh window renders.
            let reader = KakaoTalkTranscriptReader(kakao: kakao, runner: AXActionRunner(traceEnabled: traceAX))
            var snapshot: TranscriptSnapshot?
            var lastError: Error?
            for attempt in 0..<2 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 1.0) }
                do {
                    snapshot = try reader.readSnapshot(from: window, fallbackChatTitle: expectTitle, limit: 8)
                    break
                } catch {
                    lastError = error
                }
            }
            guard let snapshot else {
                throw fail("could not read the chat transcript (\(lastError.map { "\($0)" } ?? "unknown"))")
            }
            let bodies = snapshot.messages.map { Self.normalizeForMatch($0.body) }.filter { !$0.isEmpty }
            let missing = expectRecent.filter { expected in
                let want = Self.normalizeForMatch(expected)
                return !bodies.contains { body in
                    body == want || body.contains(want) || (body.count >= 8 && want.hasPrefix(body))
                }
            }
            guard missing.isEmpty else {
                throw fail("\(missing.count) of \(expectRecent.count) expected recent messages are not in the window transcript (\(bodies.count) messages read)")
            }
            print("✓ Transcript matches \(expectRecent.count) expected recent message(s) \(stage)")
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
