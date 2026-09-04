import AppKit
import ApplicationServices
import CoreGraphics

final class InputInserter {
    final class Target {
        let application: NSRunningApplication
        fileprivate let focusedElement: AXUIElement?
        fileprivate let role: String?
        fileprivate let identifier: String?

        fileprivate init(
            application: NSRunningApplication,
            focusedElement: AXUIElement?,
            role: String?,
            identifier: String?
        ) {
            self.application = application
            self.focusedElement = focusedElement
            self.role = role
            self.identifier = identifier
        }
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    var hasPostPermission: Bool {
        CGPreflightPostEventAccess() && AXIsProcessTrusted()
    }

    func captureTarget(application: NSRunningApplication?) -> Target? {
        guard let application, !application.isTerminated else { return nil }
        let element = focusedElement(in: application.processIdentifier)
        return Target(
            application: application,
            focusedElement: element,
            role: element.flatMap { stringAttribute(kAXRoleAttribute, of: $0) },
            identifier: element.flatMap { stringAttribute(kAXIdentifierAttribute, of: $0) }
        )
    }

    @discardableResult
    func insert(
        _ text: String,
        into target: Target?,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        let immutableText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target, !target.application.isTerminated, !immutableText.isEmpty else {
            return false
        }
        guard AXIsProcessTrusted() || CGPreflightPostEventAccess() else {
            requestAccessibilityPermission()
            return false
        }

        let snapshot = capturePasteboard()
        let pasteboardChangeCount = writePasteboard(immutableText)
        target.application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        waitForApplication(
            target,
            text: immutableText,
            pasteboardSnapshot: snapshot,
            pasteboardChangeCount: pasteboardChangeCount,
            attemptsRemaining: 25,
            completion: completion
        )
        return true
    }

    func requestAccessibilityPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()
    }

    private func waitForApplication(
        _ target: Target,
        text: String,
        pasteboardSnapshot: PasteboardSnapshot,
        pasteboardChangeCount: Int,
        attemptsRemaining: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard !target.application.isTerminated else {
            restorePasteboard(pasteboardSnapshot, ifChangeCountIs: pasteboardChangeCount)
            completion(false)
            return
        }

        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == target.application.processIdentifier
        guard isFrontmost else {
            guard attemptsRemaining > 0 else {
                restorePasteboard(pasteboardSnapshot, ifChangeCountIs: pasteboardChangeCount)
                completion(false)
                return
            }
            target.application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.waitForApplication(
                    target,
                    text: text,
                    pasteboardSnapshot: pasteboardSnapshot,
                    pasteboardChangeCount: pasteboardChangeCount,
                    attemptsRemaining: attemptsRemaining - 1,
                    completion: completion
                )
            }
            return
        }

        if let captured = target.focusedElement {
            _ = focus(captured)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == target.application.processIdentifier else {
                guard attemptsRemaining > 0 else {
                    self.restorePasteboard(pasteboardSnapshot, ifChangeCountIs: pasteboardChangeCount)
                    completion(false)
                    return
                }
                self.waitForApplication(
                    target,
                    text: text,
                    pasteboardSnapshot: pasteboardSnapshot,
                    pasteboardChangeCount: pasteboardChangeCount,
                    attemptsRemaining: attemptsRemaining - 1,
                    completion: completion
                )
                return
            }

            // Try the exact field captured before the menu popover appeared first.
            if let capturedElement = target.focusedElement {
                _ = self.focus(capturedElement)
                if self.replaceSelection(in: capturedElement, with: text) {
                    self.restorePasteboard(pasteboardSnapshot, ifChangeCountIs: pasteboardChangeCount)
                    completion(true)
                    return
                }
            }

            // Web views and Electron editors can replace their AX node while
            // retaining the same focused input. The process is still the exact
            // application selected before dictation, so use its current AX
            // responder rather than failing on object identity alone.
            if let currentElement = self.focusedElement(in: target.application.processIdentifier) {
                if self.replaceSelection(in: currentElement, with: text) {
                    self.restorePasteboard(pasteboardSnapshot, ifChangeCountIs: pasteboardChangeCount)
                    completion(true)
                    return
                }

                self.pasteWithVerification(
                    text,
                    into: currentElement,
                    targetPID: target.application.processIdentifier,
                    pasteboardSnapshot: pasteboardSnapshot,
                    previousChangeCount: pasteboardChangeCount,
                    completion: completion
                )
                return
            }

            // AX may expose no focused node at all, but the target application
            // is verified frontmost. Send the fallback paste directly to that
            // process instead of broadcasting it to whichever app wins focus.
            self.pasteWithoutAXVerification(
                text,
                targetPID: target.application.processIdentifier,
                pasteboardSnapshot: pasteboardSnapshot,
                pasteboardChangeCount: pasteboardChangeCount,
                completion: completion
            )
        }
    }

    private func resolveFocusedElement(for target: Target) -> AXUIElement? {
        guard let current = focusedElement(in: target.application.processIdentifier) else { return nil }
        guard let captured = target.focusedElement else { return current }
        if CFEqual(current, captured) { return current }

        // A few web views replace their accessibility node while preserving a
        // stable identifier. Accept that replacement only when both identity
        // metadata fields match; otherwise fail instead of typing elsewhere.
        let currentRole = stringAttribute(kAXRoleAttribute, of: current)
        let currentIdentifier = stringAttribute(kAXIdentifierAttribute, of: current)
        if let identifier = target.identifier, !identifier.isEmpty,
           currentIdentifier == identifier, currentRole == target.role {
            return current
        }
        return nil
    }

    private func focusedElement(in processID: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success,
              elementPID == processID else { return nil }
        return element
    }

    private func focus(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func replaceSelection(in element: AXUIElement, with text: String) -> Bool {
        guard !text.isEmpty else { return false }

        if AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success {
            return true
        }

        var valueReference: CFTypeRef?
        var rangeReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueReference
        ) == .success,
        let currentValue = valueReference as? String,
        AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeReference
        ) == .success,
        let rangeReference,
        CFGetTypeID(rangeReference) == AXValueGetTypeID() else {
            return false
        }

        let axRange = rangeReference as! AXValue
        guard AXValueGetType(axRange) == .cfRange else { return false }
        var selectedRange = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &selectedRange) else { return false }

        let nsValue = currentValue as NSString
        let replacementRange = NSRange(location: selectedRange.location, length: selectedRange.length)
        guard NSMaxRange(replacementRange) <= nsValue.length else { return false }
        let updatedValue = nsValue.replacingCharacters(in: replacementRange, with: text)
        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        ) == .success else { return false }

        var cursorRange = CFRange(
            location: selectedRange.location + (text as NSString).length,
            length: 0
        )
        if let cursorValue = AXValueCreate(.cfRange, &cursorRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                cursorValue
            )
        }
        return true
    }

    private func pasteWithoutAXVerification(
        _ text: String,
        targetPID: pid_t,
        pasteboardSnapshot: PasteboardSnapshot,
        pasteboardChangeCount: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard NSPasteboard.general.string(forType: .string) == text,
              postPasteShortcut(to: targetPID) else {
            restorePasteboard(pasteboardSnapshot, ifChangeCountIs: pasteboardChangeCount)
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
                completion(false)
                return
            }
            self.restorePasteboard(pasteboardSnapshot, ifChangeCountIs: pasteboardChangeCount)
            completion(true)
        }
    }

    private func pasteWithVerification(
        _ text: String,
        into element: AXUIElement,
        targetPID: pid_t,
        pasteboardSnapshot: PasteboardSnapshot,
        previousChangeCount: Int,
        completion: @escaping (Bool) -> Void
    ) {
        let beforeValue = stringAttribute(kAXValueAttribute, of: element)
        let currentChangeCount = NSPasteboard.general.changeCount == previousChangeCount
            ? previousChangeCount
            : writePasteboard(text)
        guard postPasteShortcut(to: targetPID) else {
            restorePasteboard(pasteboardSnapshot, ifChangeCountIs: currentChangeCount)
            completion(false)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            let afterValue = self.stringAttribute(kAXValueAttribute, of: element)
            if let beforeValue, let afterValue, beforeValue == afterValue {
                // Delivery was observable and nothing changed. A Unicode event
                // targeted to the same process is safer than repeating paste.
                let typed = self.postUnicodeText(text, to: targetPID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    self.restorePasteboard(pasteboardSnapshot, ifChangeCountIs: currentChangeCount)
                    let finalValue = self.stringAttribute(kAXValueAttribute, of: element)
                    completion(typed && finalValue != beforeValue)
                }
            } else {
                self.restorePasteboard(pasteboardSnapshot, ifChangeCountIs: currentChangeCount)
                completion(true)
            }
        }
    }

    private func postPasteShortcut(to processID: pid_t) -> Bool {
        guard hasPostPermission,
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processID)
        keyUp.postToPid(processID)
        return true
    }

    private func postUnicodeText(_ text: String, to processID: pid_t) -> Bool {
        guard hasPostPermission,
              let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        let characters = Array(text.utf16)
        guard !characters.isEmpty else { return false }

        // CGEvent Unicode payloads are intentionally kept small; long
        // transcriptions are emitted as ordered UTF-16 chunks.
        for start in stride(from: 0, to: characters.count, by: 20) {
            let end = min(start + 20, characters.count)
            let chunk = Array(characters[start..<end])
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            chunk.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
                keyUp.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            keyDown.postToPid(processID)
            keyUp.postToPid(processID)
        }
        return true
    }

    private func capturePasteboard() -> PasteboardSnapshot {
        let items = NSPasteboard.general.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { values, type in
                if let data = item.data(forType: type) { values[type] = data }
            }
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    @discardableResult
    private func writePasteboard(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    private func restorePasteboard(_ snapshot: PasteboardSnapshot, ifChangeCountIs expected: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expected else { return }
        pasteboard.clearContents()
        let items = snapshot.items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
