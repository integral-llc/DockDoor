import ApplicationServices
import Cocoa
import Defaults

// MARK: - Global State

private weak var activeWindowManipulationObserversInstance: WindowManipulationObservers?
private var pendingNotifications: [String: DispatchWorkItem] = [:]
private let windowProcessingDebounceInterval: TimeInterval = Defaults[.windowProcessingDebounceInterval]
private let axObserverWorkQueue = DispatchQueue(label: "ddObsWorkQueue", qos: .userInitiated)

class WindowManipulationObservers {
    private let previewCoordinator: SharedPreviewWindowCoordinator

    private var observers: [pid_t: AXObserver] = [:]
    private var debouncedTasks: [String: Task<Void, Never>] = [:]
    var cacheUpdateWorkItem: (workItem: DispatchWorkItem, hasStateAdjustment: Bool, needsValidation: Bool)?
    var updateDateTimeWorkItem: DispatchWorkItem?
    private func debounce(key: String, delay: TimeInterval = windowProcessingDebounceInterval, operation: @escaping () async -> Void) {
        debouncedTasks[key]?.cancel()
        debouncedTasks[key] = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                DebugLogger.log("debounce", details: "Cancelled during sleep: \(key)")
                return
            }
            guard !Task.isCancelled else {
                DebugLogger.log("debounce", details: "Cancelled after sleep: \(key)")
                return
            }
            await operation()
        }
    }

    init(previewCoordinator: SharedPreviewWindowCoordinator) {
        self.previewCoordinator = previewCoordinator
        activeWindowManipulationObserversInstance = self
        setupObservers()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        removeAllObservers()
        if activeWindowManipulationObserversInstance === self {
            activeWindowManipulationObserversInstance = nil
        }
    }

    private func removeAllObservers() {
        let pids = Array(observers.keys)
        for pid in pids {
            removeObserver(for: pid)
        }
    }

    func reset() {
        removeAllObservers()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for app in apps {
            createObserverForApp(app)
        }
    }

    private func setupObservers() {
        DebugLogger.measure("setupObservers") {
            let notificationCenter = NSWorkspace.shared.notificationCenter
            notificationCenter.addObserver(self, selector: #selector(appDidLaunch(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
            notificationCenter.addObserver(self, selector: #selector(appDidTerminate(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

            notificationCenter.addObserver(self, selector: #selector(activeSpaceDidChange(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            notificationCenter.addObserver(self, selector: #selector(appDidActivate(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)

            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            DebugLogger.log("setupObservers", details: "Setting up observers for \(apps.count) running apps")

            for app in apps {
                createObserverForApp(app)
            }
        }
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular
        else {
            return
        }
        DebugLogger.log("appDidLaunch", details: "App: \(app.localizedName ?? "Unknown") (PID: \(app.processIdentifier))")
        createObserverForApp(app)
        handleNewWindow(for: app.processIdentifier)

        if Defaults[.showActiveAppIndicator] {
            ActiveAppIndicatorCoordinator.shared?.notifyDockItemsChanged()
        }
    }

    @MainActor
    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        DebugLogger.log("appDidTerminate", details: "App: \(app.localizedName ?? "Unknown") (PID: \(app.processIdentifier))")
        WindowUtil.purgeAppCache(with: app.processIdentifier)
        removeObserver(for: app.processIdentifier)

        let coordinator = previewCoordinator.windowSwitcherCoordinator
        if coordinator.isKeybindSessionActive {
            let pid = app.processIdentifier
            for i in stride(from: coordinator.windows.count - 1, through: 0, by: -1) {
                if coordinator.windows[i].app.processIdentifier == pid {
                    coordinator.removeWindow(at: i)
                }
            }
            if coordinator.windows.isEmpty {
                previewCoordinator.hideWindow()
            }
        } else if !Defaults[.keepPreviewOnAppTerminate] {
            previewCoordinator.hideWindow()
        }

        if Defaults[.showActiveAppIndicator] {
            ActiveAppIndicatorCoordinator.shared?.notifyDockItemsChanged()
        }
    }

    @objc private func activeSpaceDidChange(_ notification: Notification) {
        DebugLogger.log("activeSpaceDidChange")
        Task { @MainActor in
            previewCoordinator.hideWindow()
        }
        if Defaults[.showActiveAppIndicator] {
            ActiveAppIndicatorCoordinator.shared?.handleSpaceChanged()
        }
        debounce(key: "spaceChange") {
            await DebugLogger.measureAsync("updateAllWindowsInCurrentSpace") {
                await WindowUtil.updateAllWindowsInCurrentSpace()
            }
        }
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            return
        }

        if !previewCoordinator.windowSwitcherCoordinator.isKeybindSessionActive {
            previewCoordinator.hideWindow()
        }

        if let dockObserver = DockObserver.activeInstance,
           let currentClickedPID = dockObserver.currentClickedAppPID,
           currentClickedPID != app.processIdentifier
        {
            dockObserver.currentClickedAppPID = nil
        }

        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        axObserverWorkQueue.asyncAfter(deadline: .now() + 0.3) {
            if let focusedWindow = try? appAX.focusedWindow() {
                WindowUtil.updateWindowDateTime(element: focusedWindow, app: app)
            }
        }
    }

    private func createObserverForApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier

        DebugLogger.measure("createObserverForApp", details: "App: \(app.localizedName ?? "Unknown") (PID: \(pid))") {
            var observer: AXObserver?
            let result = AXObserverCreate(pid, axObserverCallback, &observer)
            guard result == .success, let observer else { return }

            let appElement = AXUIElementCreateApplication(pid)

            AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, UnsafeMutableRawPointer(bitPattern: Int(pid)))
            AXObserverAddNotification(observer, appElement, kAXUIElementDestroyedNotification as CFString, UnsafeMutableRawPointer(bitPattern: Int(pid)))
            AXObserverAddNotification(observer, appElement, kAXWindowMiniaturizedNotification as CFString, UnsafeMutableRawPointer(bitPattern: Int(pid)))
            AXObserverAddNotification(observer, appElement, kAXWindowDeminiaturizedNotification as CFString, UnsafeMutableRawPointer(bitPattern: Int(pid)))
            AXObserverAddNotification(observer, appElement, kAXApplicationHiddenNotification as CFString, UnsafeMutableRawPointer(bitPattern: Int(pid)))
            AXObserverAddNotification(observer, appElement, kAXApplicationShownNotification as CFString, UnsafeMutableRawPointer(bitPattern: Int(pid)))
            AXObserverAddNotification(observer, appElement, kAXWindowResizedNotification as CFString, UnsafeMutableRawPointer(bitPattern: Int(pid)))
            AXObserverAddNotification(observer, appElement, kAXWindowMovedNotification as CFString, UnsafeMutableRawPointer(bitPattern: Int(pid)))
            AXObserverAddNotification(observer, appElement, kAXMainWindowChangedNotification as CFString, UnsafeMutableRawPointer(bitPattern: Int(pid)))
            AXObserverAddNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString, UnsafeMutableRawPointer(bitPattern: Int(pid)))
            AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, UnsafeMutableRawPointer(bitPattern: Int(pid)))
            AXObserverAddNotification(observer, appElement, kAXTitleChangedNotification as CFString, UnsafeMutableRawPointer(bitPattern: Int(pid)))

            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

            observers[pid] = observer
        }
    }

    private func removeObserverForApp(_ app: NSRunningApplication) {
        removeObserver(for: app.processIdentifier)
    }

    func removeObserver(for pid: pid_t) {
        guard let observer = observers[pid] else { return }

        let appElement = AXUIElementCreateApplication(pid)

        AXObserverRemoveNotification(observer, appElement, kAXWindowCreatedNotification as CFString)
        AXObserverRemoveNotification(observer, appElement, kAXUIElementDestroyedNotification as CFString)
        AXObserverRemoveNotification(observer, appElement, kAXWindowMiniaturizedNotification as CFString)
        AXObserverRemoveNotification(observer, appElement, kAXWindowDeminiaturizedNotification as CFString)
        AXObserverRemoveNotification(observer, appElement, kAXApplicationHiddenNotification as CFString)
        AXObserverRemoveNotification(observer, appElement, kAXApplicationShownNotification as CFString)
        AXObserverRemoveNotification(observer, appElement, kAXMainWindowChangedNotification as CFString)
        AXObserverRemoveNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString)
        AXObserverRemoveNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString)
        AXObserverRemoveNotification(observer, appElement, kAXWindowResizedNotification as CFString)
        AXObserverRemoveNotification(observer, appElement, kAXWindowMovedNotification as CFString)
        AXObserverRemoveNotification(observer, appElement, kAXTitleChangedNotification as CFString)

        observers.removeValue(forKey: pid)
    }

    func handleNewWindow(for pid: pid_t) {
        debounce(key: "windowCreation") {
            if let app = NSRunningApplication(processIdentifier: pid) {
                DebugLogger.log("handleNewWindow", details: "App: \(app.localizedName ?? "Unknown") (PID: \(pid))")
                await DebugLogger.measureAsync("updateNewWindowsForApp", details: "PID: \(pid)") {
                    await WindowUtil.updateNewWindowsForApp(app)
                }
            }
        }
    }

    func processAXNotification(element: AXUIElement, notificationName: String, app: NSRunningApplication, pid: pid_t) {
        DebugLogger.log("processAXNotification", details: "Notification: \(notificationName), App: \(app.localizedName ?? "Unknown") (PID: \(pid))")

        switch notificationName {
        case kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            let appAX = AXUIElementCreateApplication(app.processIdentifier)
            let focusedWindowID = (try? appAX.focusedWindow()).flatMap { try? $0.cgWindowId() }
            Task { @MainActor [weak self] in
                self?.previewCoordinator.windowSwitcherCoordinator.setFocusedWindowID(focusedWindowID)
            }
            if let focusedWindowID {
                WindowRecaptureScheduler.shared.noteWindowChanged(pid: pid, windowID: focusedWindowID)
            }
            updateTimestampIfAppActive(element: element, app: app)
            handleWindowEvent(element: element, app: app, notification: notificationName, validate: false) { [weak self] windowSet in
                guard let self else { return }
                let windowID = try? element.cgWindowId()
                update(windowSet: &windowSet, matching: windowID, element: element) { window in
                    window.spaceID = window.id.cgsSpaces().first.map { Int($0) }
                    if let pos = try? element.position() {
                        window.screenIdentifier = WindowUtil.screenIdentifier(forWindowAt: pos)
                    }
                }
            }
        case kAXUIElementDestroyedNotification:
            handleWindowEvent(element: element, app: app, notification: notificationName, validate: true)
        case kAXWindowResizedNotification, kAXWindowMovedNotification:
            if let changedWindowID = try? element.cgWindowId() {
                WindowRecaptureScheduler.shared.noteWindowChanged(pid: pid, windowID: changedWindowID)
            }
            handleWindowEvent(element: element, app: app, notification: notificationName, validate: false) { [weak self] windowSet in
                guard let self else { return }
                let windowID = try? element.cgWindowId()
                update(windowSet: &windowSet, matching: windowID, element: element) { window in
                    window.spaceID = window.id.cgsSpaces().first.map { Int($0) }
                    if let pos = try? element.position() {
                        window.screenIdentifier = WindowUtil.screenIdentifier(forWindowAt: pos)
                    }
                }
            }
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            let windowID = try? element.cgWindowId()
            let minimizedState = try? element.isMinimized()
            if notificationName == kAXWindowDeminiaturizedNotification, let windowID {
                WindowRecaptureScheduler.shared.noteWindowChanged(pid: pid, windowID: windowID)
            }
            handleWindowEvent(element: element, app: app, notification: notificationName, validate: true) { [weak self] windowSet in
                guard let self else { return }
                update(windowSet: &windowSet, matching: windowID, element: element) { window in
                    window.isMinimized = minimizedState ?? false
                }
            }
            if Defaults[.showActiveAppIndicator] {
                ActiveAppIndicatorCoordinator.shared?.notifyDockItemsChanged()
            }
        case kAXApplicationHiddenNotification:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                if NSRunningApplication(processIdentifier: pid) == nil {
                    WindowUtil.purgeAppCache(with: pid)
                    removeObserver(for: pid)
                } else {
                    handleWindowEvent(element: element, app: app, notification: notificationName, validate: true) { windowSet in
                        windowSet = Set(windowSet.map { window in
                            var updated = window
                            updated.isHidden = true
                            if let freshSpace = updated.id.cgsSpaces().first.map({ Int($0) }) {
                                updated.spaceID = freshSpace
                            }
                            return updated
                        })
                    }
                }
            }
        case kAXApplicationShownNotification:
            WindowRecaptureScheduler.shared.noteWindowChanged(pid: pid, windowID: nil)
            handleWindowEvent(element: element, app: app, notification: notificationName, validate: true) { windowSet in
                windowSet = Set(windowSet.map { window in
                    var updated = window
                    updated.isHidden = false
                    updated.spaceID = updated.id.cgsSpaces().first.map { Int($0) }
                    if let pos = try? updated.axElement.position() {
                        updated.screenIdentifier = WindowUtil.screenIdentifier(forWindowAt: pos)
                    }
                    return updated
                })
            }
        case kAXWindowCreatedNotification:
            handleNewWindow(for: pid)
        case kAXTitleChangedNotification:
            // cgWindowId only resolves for window elements, which filters out
            // title changes on arbitrary UI elements.
            if let changedWindowID = try? element.cgWindowId() {
                WindowRecaptureScheduler.shared.noteWindowChanged(pid: pid, windowID: changedWindowID)
            }
            handleWindowEvent(element: element, app: app, notification: notificationName, validate: false) { [weak self] windowSet in
                guard let self else { return }
                guard let role = try? element.role(), role == kAXWindowRole as String else { return }
                let windowID = try? element.cgWindowId()
                update(windowSet: &windowSet, matching: windowID, element: element) { window in
                    if let freshTitle = try? window.axElement.title(), !freshTitle.isEmpty {
                        window.windowName = freshTitle
                    }
                }
            }
        default:
            break
        }
    }

    private func updateTimestampIfAppActive(element: AXUIElement, app: NSRunningApplication) {
        updateDateTimeWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            if app.isActive {
                let appAX = AXUIElementCreateApplication(app.processIdentifier)
                if let focusedWindow = try? appAX.focusedWindow() {
                    WindowUtil.updateWindowDateTime(element: focusedWindow, app: app)
                }
            }
        }
        updateDateTimeWorkItem = workItem
        axObserverWorkQueue.asyncAfter(deadline: .now() + windowProcessingDebounceInterval, execute: workItem)
    }

    private func handleWindowEvent(element: AXUIElement,
                                   app: NSRunningApplication,
                                   notification: String,
                                   validate: Bool = false,
                                   stateAdjustment: ((inout Set<WindowInfo>) -> Void)? = nil)
    {
        let inheritedValidation = cacheUpdateWorkItem?.needsValidation ?? false

        if cacheUpdateWorkItem?.hasStateAdjustment != true {
            cacheUpdateWorkItem?.workItem.cancel()
        }

        let effectiveValidate = validate || inheritedValidation
        let hasStateAdjustment = stateAdjustment != nil
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DebugLogger.measure("updateWindowCache", details: "App: \(app.localizedName ?? "Unknown"), Notification: \(notification), Validate: \(effectiveValidate)") {
                WindowUtil.updateWindowCache(for: app) { windowSet in
                    let previousWindows = windowSet
                    if effectiveValidate {
                        windowSet = windowSet.filter { WindowUtil.isValidElement($0.axElement) }
                    }
                    stateAdjustment?(&windowSet)
                    if notification == (kAXUIElementDestroyedNotification as String),
                       self.didDestroyCachedWindow(
                           element,
                           previousWindows: previousWindows
                       )
                    {
                        WindowUtil.quitAppOnLastWindowCloseIfNeeded(
                            app: app,
                            previousWindowCount: previousWindows.count,
                            remainingWindowCount: windowSet.count
                        )
                    }
                }
            }
            cacheUpdateWorkItem = nil
        }
        cacheUpdateWorkItem = (workItem, hasStateAdjustment, effectiveValidate)
        axObserverWorkQueue.asyncAfter(deadline: .now() + windowProcessingDebounceInterval, execute: workItem)
    }

    private func didDestroyCachedWindow(_ destroyedElement: AXUIElement, previousWindows: Set<WindowInfo>) -> Bool {
        if previousWindows.contains(where: { $0.axElement == destroyedElement }) {
            return true
        }

        guard let destroyedWindowID = try? destroyedElement.cgWindowId() else {
            return false
        }
        return previousWindows.contains { $0.id == destroyedWindowID }
    }

    private func update(windowSet: inout Set<WindowInfo>,
                        matching windowID: CGWindowID?,
                        element: AXUIElement,
                        updateBlock: (inout WindowInfo) -> Void)
    {
        if let windowID,
           let existing = windowSet.first(where: { $0.id == windowID })
        {
            var updated = existing
            updateBlock(&updated)
            windowSet.remove(existing)
            windowSet.insert(updated)
            return
        }

        if let existing = windowSet.first(where: { $0.axElement == element }) {
            var updated = existing
            updateBlock(&updated)
            windowSet.remove(existing)
            windowSet.insert(updated)
        }
    }
}

// MARK: - Targeted Window Recapture

/// Keeps window thumbnails warm by recapturing changed windows shortly after an
/// AX event reports a move, resize, focus change, title change, de-miniaturize,
/// or app unhide, so dock hovers hit a fresh cache instead of paying the
/// on-hover TTL recapture. This is a fast targeted path layered on top of
/// updateAllWindowsInCurrentSpace, which remains the discovery fallback.
actor WindowRecaptureScheduler {
    static let shared = WindowRecaptureScheduler()

    private enum Scope {
        case windows(Set<CGWindowID>)
        case allWindows

        // A nil window ID widens the scope to the whole app.
        func merging(windowID: CGWindowID?) -> Scope {
            guard case let .windows(ids) = self, let windowID else { return .allWindows }
            return .windows(ids.union([windowID]))
        }

        func contains(_ windowID: CGWindowID) -> Bool {
            switch self {
            case let .windows(ids): ids.contains(windowID)
            case .allWindows: true
            }
        }
    }

    private static let debounceInterval: TimeInterval = 0.5

    private var pendingScopes: [pid_t: Scope] = [:]
    private var pendingTasks: [pid_t: Task<Void, Never>] = [:]
    private var inFlightPIDs: Set<pid_t> = []

    /// Safe to call from any thread; never blocks the caller.
    nonisolated func noteWindowChanged(pid: pid_t, windowID: CGWindowID?) {
        Task(priority: .utility) { await self.schedule(pid: pid, windowID: windowID) }
    }

    private func schedule(pid: pid_t, windowID: CGWindowID?) {
        let scope = pendingScopes[pid] ?? .windows([])
        pendingScopes[pid] = scope.merging(windowID: windowID)
        armDebounce(pid: pid)
    }

    // Trailing debounce: a drag or live-resize coalesces into a single
    // capture of the final state, 0.5s after the last event.
    private func armDebounce(pid: pid_t) {
        pendingTasks[pid]?.cancel()
        pendingTasks[pid] = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.fire(pid: pid)
        }
    }

    private func fire(pid: pid_t) async {
        pendingTasks[pid] = nil
        // A capture for this pid is running (the actor suspends across the await
        // below, so fires can interleave): keep the scope pending and retry, so
        // events reported during the capture are not silently dropped.
        guard !inFlightPIDs.contains(pid) else {
            if pendingScopes[pid] != nil { armDebounce(pid: pid) }
            return
        }
        guard let scope = pendingScopes.removeValue(forKey: pid) else { return }
        inFlightPIDs.insert(pid)
        defer { inFlightPIDs.remove(pid) }
        await Self.recaptureWindows(pid: pid, scope: scope)
        // Drain anything that accumulated while the capture ran.
        if pendingScopes[pid] != nil, pendingTasks[pid] == nil { armDebounce(pid: pid) }
    }

    private static func recaptureWindows(pid: pid_t, scope: Scope) async {
        guard WindowUtil.shouldCaptureWindowImages() else { return }
        // Never react to our own preview windows or filtered/system apps.
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular,
              !app.isHidden,
              !filteredBundleIdentifiers.contains(app.bundleIdentifier ?? ""),
              !WindowUtil.isAppFiltered(app)
        else { return }

        let cached = WindowUtil.readCachedWindows(for: pid)
        guard !cached.isEmpty else { return }

        let candidates = WindowUtil.filterWindowsByCurrentSpace(cached).filter { window in
            guard scope.contains(window.id), !window.isHidden else { return false }
            // Cache state can lag a de-miniaturize by a beat; trust the live AX flag.
            return !((try? window.axElement.isMinimized()) ?? window.isMinimized)
        }

        for window in candidates {
            guard let image = try? await WindowUtil.captureWindowImage(
                windowID: window.id,
                pid: pid,
                windowTitle: window.windowName,
                forceRefresh: true
            ) else { continue }
            // Image-only write: the snapshot's state flags may be stale by now
            // (minimize/hide/title events land concurrently), and the window may
            // have been removed from the cache entirely while capturing.
            WindowUtil.refreshCachedWindowImage(pid: pid, windowID: window.id, image: image)
        }
    }
}

func axObserverCallback(observer: AXObserver, element: AXUIElement, notificationName: CFString, userData: UnsafeMutableRawPointer?) {
    guard let userData else { return }
    let pid = pid_t(Int(bitPattern: userData))
    let notification = notificationName as String
    let key = "\(pid)-\(notification)"

    axObserverWorkQueue.async {
        pendingNotifications[key]?.cancel()

        let workItem = DispatchWorkItem {
            pendingNotifications.removeValue(forKey: key)
            if let app = NSRunningApplication(processIdentifier: pid),
               let observerInstance = activeWindowManipulationObserversInstance
            {
                observerInstance.processAXNotification(element: element, notificationName: notification, app: app, pid: pid)
            }
        }

        pendingNotifications[key] = workItem
        axObserverWorkQueue.asyncAfter(deadline: .now() + windowProcessingDebounceInterval, execute: workItem)
    }
}
