import CoreGraphics
import Foundation

final class HotKeyManager {
    enum StartResult {
        case started
        case permissionsRequired
        case unavailable
    }

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private let stateLock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventRunLoop: CFRunLoop?
    private var eventThread: Thread?

    private var gestureGeneration: UInt64 = 0
    private var isGlobeDown = false
    private var isHoldActive = false
    private var pressTimestamp: CGEventTimestamp = 0
    private var holdTimer: DispatchWorkItem?
    private let holdThresholdNanoseconds: CGEventTimestamp = 200_000_000

    deinit { stop() }

    var hasRequiredPermissions: Bool {
        CGPreflightListenEventAccess()
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let eventTap else { return false }
        return CFMachPortIsValid(eventTap) && CGEvent.tapIsEnabled(tap: eventTap)
    }

    @discardableResult
    func startGlobeKey(requestPermissions: Bool = true) -> StartResult {
        stop()

        var canListen = CGPreflightListenEventAccess()
        if requestPermissions, !canListen {
            canListen = CGRequestListenEventAccess()
        }
        guard canListen else { return .permissionsRequired }

        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                manager.resetGesture(notifyRelease: true)
                if let tap = manager.currentEventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            guard event.getIntegerValueField(.keyboardEventKeycode) == 63 else {
                return Unmanaged.passUnretained(event)
            }

            let isPressed: Bool
            switch type {
            case .keyDown:
                isPressed = true
            case .keyUp:
                isPressed = false
            case .flagsChanged:
                isPressed = event.flags.contains(.maskSecondaryFn)
            default:
                return Unmanaged.passUnretained(event)
            }

            manager.processGlobeTransition(pressed: isPressed, timestamp: event.timestamp)

            // This listener only observes the Globe/Fn transition. It does not
            // modify or suppress keyboard events, so Input Monitoring is the
            // only permission required for the hotkey itself.
            return Unmanaged.passUnretained(event)
        }

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: pointer
        ) else {
            return .unavailable
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let ready = DispatchSemaphore(value: 0)

        stateLock.lock()
        eventTap = tap
        runLoopSource = source
        stateLock.unlock()

        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            let runLoop = CFRunLoopGetCurrent()
            self.stateLock.lock()
            self.eventRunLoop = runLoop
            self.stateLock.unlock()

            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)

            self.stateLock.lock()
            if self.eventRunLoop === runLoop { self.eventRunLoop = nil }
            self.stateLock.unlock()
        }
        thread.name = "VoiceToText.GlobeEventTap"
        thread.qualityOfService = .userInteractive
        eventThread = thread
        thread.start()

        guard ready.wait(timeout: .now() + 2) == .success,
              CFMachPortIsValid(tap),
              CGEvent.tapIsEnabled(tap: tap) else {
            stop()
            return .unavailable
        }
        return .started
    }

    func stop() {
        resetGesture(notifyRelease: true)

        stateLock.lock()
        let runLoop = eventRunLoop
        let tap = eventTap
        eventRunLoop = nil
        eventTap = nil
        runLoopSource = nil
        eventThread = nil
        stateLock.unlock()

        if let tap { CFMachPortInvalidate(tap) }
        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private var currentEventTap: CFMachPort? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return eventTap
    }

    private func processGlobeTransition(pressed: Bool, timestamp: CGEventTimestamp) {
        if pressed {
            stateLock.lock()
            guard !isGlobeDown else {
                stateLock.unlock()
                return
            }
            gestureGeneration &+= 1
            let generation = gestureGeneration
            isGlobeDown = true
            isHoldActive = false
            pressTimestamp = timestamp
            holdTimer?.cancel()

            let timer = DispatchWorkItem { [weak self] in
                self?.activateHoldIfCurrent(generation: generation)
            }
            holdTimer = timer
            stateLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: timer)
            return
        }

        stateLock.lock()
        guard isGlobeDown else {
            stateLock.unlock()
            return
        }
        let elapsed = timestamp >= pressTimestamp ? timestamp - pressTimestamp : 0
        let wasActive = isHoldActive
        isGlobeDown = false
        isHoldActive = false
        holdTimer?.cancel()
        holdTimer = nil
        gestureGeneration &+= 1
        stateLock.unlock()

        if wasActive {
            DispatchQueue.main.async { [weak self] in self?.onKeyUp?() }
        } else if elapsed >= holdThresholdNanoseconds {
            // If the main thread was briefly busy, preserve the physical hold
            // based on hardware timestamps and emit one ordered start/stop pair.
            DispatchQueue.main.async { [weak self] in
                self?.onKeyDown?()
                self?.onKeyUp?()
            }
        }
        // A physical tap shorter than 200 ms is intentionally ignored.
    }

    private func activateHoldIfCurrent(generation: UInt64) {
        stateLock.lock()
        guard isGlobeDown, !isHoldActive, gestureGeneration == generation else {
            stateLock.unlock()
            return
        }
        isHoldActive = true
        stateLock.unlock()
        onKeyDown?()
    }

    private func resetGesture(notifyRelease: Bool) {
        stateLock.lock()
        let shouldNotify = notifyRelease && isHoldActive
        gestureGeneration &+= 1
        isGlobeDown = false
        isHoldActive = false
        pressTimestamp = 0
        holdTimer?.cancel()
        holdTimer = nil
        stateLock.unlock()

        if shouldNotify {
            DispatchQueue.main.async { [weak self] in self?.onKeyUp?() }
        }
    }
}
