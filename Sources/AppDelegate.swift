// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ApplicationServices
import QuartzCore

enum MetadataTransitionPhase: Equatable { case grace, pending, unavailable }

/// Candidate changes and AX gaps share bounded notice/expiry times rather than hiding the window.
struct MetadataTransitionWindow {
    let noticeDelay: TimeInterval = 0.15
    let failureDelay: TimeInterval = 1.2
    private(set) var startedAt: TimeInterval?
    private(set) var generation = 0

    mutating func begin(at now: TimeInterval) {
        if startedAt == nil { startedAt = now; generation += 1 }
    }
    mutating func finish() { startedAt = nil; generation += 1 }
    func phase(at now: TimeInterval) -> MetadataTransitionPhase {
        guard let startedAt else { return .grace }
        if now >= startedAt + failureDelay { return .unavailable }
        return now >= startedAt + noticeDelay ? .pending : .grace
    }
    func nextDeadline(at now: TimeInterval) -> TimeInterval? {
        guard let startedAt else { return nil }
        switch phase(at: now) {
        case .grace: return startedAt + noticeDelay
        case .pending: return startedAt + failureDelay
        case .unavailable: return nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: InfoPanel!
    private var content: InfoPanelContent!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let worker = DispatchQueue(label: "photo-info.reader", qos: .userInitiated)
    private let reader = LightroomSelectionReader()
    private let store = MetadataStore()
    private let appearance = AppearanceSettings()
    private var settingsController: AppearanceSettingsWindowController?
    private var settingsVisible = false
    private var ownApplicationForeground = false
    private var restoreLightroomAfterSettings = false
    // Accessed only from worker: no stale-selection result is admitted into this cache.
    private var refreshSchedule = MetadataRefreshSchedule()
    private var lastLookup: MetadataLookup?
    private var lookupFailure: (selection: PhotoSelection, since: TimeInterval)?
    private var reading = false
    private var paused = false
    private var lastDiagnostic = ""
    private var renderedSelection: PhotoSelection?
    private var pendingSelection: PhotoSelection?
    private var pendingMessage = "暂时无法读取当前照片"
    private var transition = MetadataTransitionWindow()
    private var loadingWork: DispatchWorkItem?
    private var scheduledCheckpoint: TimeInterval?
    private var didRequestPermission = false
    private var latestWindowFrame: NSRect?
    private var hasValidSnapshot = false
    private var applyingPosition = false
    private var resizingPanel = false
    private var resizeGeneration = 0
    private let testShow = CommandLine.arguments.contains("--test-show")
    private var offset = NSPoint(x: 24, y: 76)
    private var lightroomAvailable = false
    private var lightroomForeground = false
    private var sessionActive = true
    private let diagnosticPath: String? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--diagnostic-file"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        if let x = defaults.object(forKey: "PanelOffsetX") as? NSNumber,
           let y = defaults.object(forKey: "PanelOffsetY") as? NSNumber,
           x.doubleValue.isFinite, y.doubleValue.isFinite {
            offset = NSPoint(x: x.doubleValue, y: y.doubleValue)
        }
        content = InfoPanelContent(frame: NSRect(origin: .zero, size: InfoPanelContent.panelSize))
        content.onOpenAccessibility = { [weak self] in self?.openAccessibility() }
        content.onExpansionChange = { [weak self] height, animated in self?.resizePanel(to: height, animated: animated) }
        content.setBackgroundOpacity(appearance.backgroundOpacity)
        appearance.onChange = { [weak self] opacity in self?.content.setBackgroundOpacity(opacity) }
        panel = InfoPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Lightroom · 拍摄信息"
        panel.contentView = content
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isMovable = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "Lightroom 拍摄信息")
        let menu = NSMenu()
        menu.addItem(withTitle: "显示拍摄信息", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "隐藏拍摄信息", action: #selector(hidePanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "辅助功能权限…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出拍摄信息", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu

        let notifications = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            notifications.addObserver(self, selector: #selector(applicationChanged), name: name, object: nil)
        }
        notifications.addObserver(self, selector: #selector(sessionInactive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        notifications.addObserver(self, selector: #selector(sessionActivated), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        updateWorkspaceState()
        updatePolling()
        tick()
        if CommandLine.arguments.contains("--settings") { openSettings() }
    }

    private var foregroundEligible: Bool {
        sessionActive && !paused && lightroomAvailable && (testShow || lightroomForeground || (settingsVisible && ownApplicationForeground))
    }

    @objc private func applicationChanged() {
        updateWorkspaceState()
        updatePolling()
        if !foregroundEligible { hideForBinding(reason: "lightroomInactive") }
        tick()
    }

    private func updateWorkspaceState() {
        let application = NSRunningApplication.runningApplications(withBundleIdentifier: LightroomSelectionReader.bundleID).first
        lightroomAvailable = application.map { !$0.isHidden && !$0.isTerminated } ?? false
        let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        lightroomForeground = foreground == LightroomSelectionReader.bundleID
        ownApplicationForeground = foreground == Bundle.main.bundleIdentifier
    }

    private func updatePolling() {
        guard sessionActive && (foregroundEligible || diagnosticPath != nil) else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let newTimer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in self?.tick() }
        newTimer.tolerance = 0.015
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    @objc private func sessionInactive() {
        sessionActive = false
        updatePolling()
        hideForBinding(reason: "sessionInactive")
    }

    @objc private func sessionActivated() {
        sessionActive = true
        applicationChanged()
    }

    private func tick() {
        guard sessionActive else { return }
        if !foregroundEligible { hideForBinding(reason: "lightroomInactive") }
        guard AXIsProcessTrusted() else {
            if foregroundEligible {
                content.showStatus("需要辅助功能权限，才能跟随当前照片", permissionRequired: true)
                positionPermissionPanel()
                setPanelVisible(true)
            }
            diagnostic(["status": "permissionRequired", "visible": panel.isVisible])
            requestPermissionOnce()
            return
        }
        guard foregroundEligible || diagnosticPath != nil else { return }
        guard !reading else { return }
        reading = true
        worker.async { [weak self] in
            guard let self else { return }
            let first = self.reader.readSnapshot()
            if case .selected(let selection) = first.state, self.lookupFailure?.selection != selection {
                self.lookupFailure = nil
            }
            if case .selected(let selection) = first.state, first.windowFrame != nil,
               !self.refreshSchedule.needsLookup(for: selection, at: ProcessInfo.processInfo.systemUptime),
               let cached = self.lastLookup {
                DispatchQueue.main.async {
                    self.reading = false
                    self.finishUnchanged(snapshot: first, cached: cached)
                }
                return
            }
            DispatchQueue.main.async { self.observe(first) }
            var result: MetadataLookup?
            if case .selected(let selection) = first.state, first.windowFrame != nil {
                switch selection.source {
                case .cloud: result = self.store.lookup(filename: selection.filename, albumName: selection.albumName)
                case .local: result = .unavailable("本地视图暂未支持，请切回云端照片")
                case .unknown: result = .unavailable("暂时无法确认照片来源")
                }
            }
            let verified = self.reader.readSnapshot()
            if case .selected(let requested) = first.state,
               case .selected(let current) = verified.state, requested == current,
               verified.windowFrame != nil, let result {
                let now = ProcessInfo.processInfo.systemUptime
                var cacheResult = false
                switch result {
                case .found: self.lookupFailure = nil; cacheResult = true
                case .unavailable:
                    if self.lookupFailure?.selection != current { self.lookupFailure = (current, now) }
                    cacheResult = current.source != .cloud || now - (self.lookupFailure?.since ?? now) >= 1.2
                }
                if cacheResult {
                    self.refreshSchedule.complete(current, at: now)
                    self.lastLookup = result
                }
            }
            DispatchQueue.main.async {
                self.reading = false
                self.finish(first: first, result: result, verified: verified)
            }
        }
    }

    private func finishUnchanged(snapshot: LightroomSnapshot, cached: MetadataLookup) {
        guard case .selected(let selected) = snapshot.state,
              let frame = appKitFrame(snapshot.windowFrame) else {
            observe(snapshot)
            return
        }
        if selected == renderedSelection && transition.startedAt == nil {
            latestWindowFrame = frame
            hasValidSnapshot = true
            followLightroomWindow()
            // Metadata and UI text are unchanged; only position/visibility can need work.
            setPanelVisible(foregroundEligible)
        } else {
            // The one fresh AX snapshot already validates this unchanged cached selection.
            finish(first: snapshot, result: cached, verified: snapshot)
        }
    }

    private func observe(_ snapshot: LightroomSnapshot) {
        let selection: PhotoSelection
        switch snapshot.state {
        case .temporarilyUnavailable:
            if let frame = appKitFrame(snapshot.windowFrame) { latestWindowFrame = frame; followLightroomWindow() }
            beginSelectionGap()
            return
        case .notRunning, .noPhoto, .permissionRequired:
            hideForBinding(reason: "confirmedNoVisiblePhoto")
            return
        case .selected(let value): selection = value
        }
        guard let frame = appKitFrame(snapshot.windowFrame) else {
            beginSelectionGap()
            return
        }
        latestWindowFrame = frame
        followLightroomWindow()
        hasValidSnapshot = true
        beginTransition(to: selection)
    }

    private func finish(first: LightroomSnapshot, result: MetadataLookup?, verified: LightroomSnapshot) {
        let current: PhotoSelection
        switch verified.state {
        case .temporarilyUnavailable:
            observe(verified)
            return
        case .notRunning, .noPhoto, .permissionRequired:
            hideForBinding(reason: "confirmedNoVisiblePhoto")
            return
        case .selected(let value): current = value
        }
        guard let frame = appKitFrame(verified.windowFrame) else {
            beginSelectionGap()
            return
        }
        latestWindowFrame = frame
        followLightroomWindow()
        hasValidSnapshot = true
        guard case .selected(let requested) = first.state, requested == current, let result else {
            // Stale queries neither commit their data nor reset the unresolved transition's deadline.
            beginTransition(to: current)
            return
        }
        if case .unavailable(let message) = result, current.source == .cloud {
            beginTransition(to: current, message: message)
            return
        }
        finishTransition()
        renderedSelection = current
        // Filename and metadata are committed together, with no intermediate blank frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch result {
        case .found(let photo):
            content.show(photo)
            setPanelVisible(foregroundEligible && hasValidSnapshot)
            if let data = try? JSONEncoder().encode(photo),
               var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object["status"] = "ready"
                object["visible"] = panel.isVisible
                object["panelX"] = panel.frame.minX
                object["panelY"] = panel.frame.minY
                object["panelHeight"] = panel.frame.height
                diagnostic(object)
            }
        case .unavailable(let message):
            content.showStatus(message, filename: current.filename)
            setPanelVisible(foregroundEligible && hasValidSnapshot)
            diagnostic(["status": "waiting", "message": message, "filename": current.filename, "visible": panel.isVisible])
        }
        CATransaction.commit()
    }

    private func beginTransition(to selection: PhotoSelection, message: String? = nil) {
        if message == nil && selection == renderedSelection && transition.startedAt == nil { return }
        let changedCandidate = pendingSelection != selection
        pendingSelection = selection
        if let message { pendingMessage = message }
        else if changedCandidate || transition.startedAt == nil { pendingMessage = "暂时无法读取当前照片" }
        transition.begin(at: ProcessInfo.processInfo.systemUptime)
        scheduleTransitionDeadline()
    }

    private func beginSelectionGap() {
        pendingSelection = nil
        pendingMessage = "暂时无法读取当前照片"
        transition.begin(at: ProcessInfo.processInfo.systemUptime)
        scheduleTransitionDeadline()
    }

    private func scheduleTransitionDeadline() {
        guard transition.startedAt != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        applyPendingAction()
        let next = transition.nextDeadline(at: now)
        if loadingWork != nil, scheduledCheckpoint == next { return }
        loadingWork?.cancel()
        loadingWork = nil
        scheduledCheckpoint = next
        guard let next else { return }
        let generation = transition.generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.transition.generation == generation else { return }
            self.loadingWork = nil
            self.scheduledCheckpoint = nil
            self.scheduleTransitionDeadline()
        }
        loadingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, next - now), execute: work)
    }

    private func applyPendingAction() {
        switch transition.phase(at: ProcessInfo.processInfo.systemUptime) {
        case .grace: return
        case .pending:
            content.showPending(targetFilename: pendingSelection?.filename)
            diagnostic(["status": "pending", "filename": pendingSelection?.filename ?? "", "visible": panel.isVisible])
        case .unavailable:
            content.showStatus(pendingMessage, filename: pendingSelection?.filename ?? "")
            renderedSelection = nil
            diagnostic(["status": "waiting", "message": pendingMessage, "filename": pendingSelection?.filename ?? "", "visible": panel.isVisible])
        }
        // A transient read never orders the window out. Confirmed mode/visibility changes do that.
        setPanelVisible(foregroundEligible && hasValidSnapshot)
    }

    private func finishTransition() {
        loadingWork?.cancel()
        loadingWork = nil
        scheduledCheckpoint = nil
        pendingSelection = nil
        transition.finish()
    }

    private func hideForBinding(reason: String) {
        let wasVisible = panel.isVisible
        setPanelVisible(false)
        hasValidSnapshot = false
        latestWindowFrame = nil
        finishTransition()
        renderedSelection = nil
        if wasVisible { diagnostic(["status": "hidden", "reason": reason, "visible": false]) }
    }

    private func setPanelVisible(_ visible: Bool) {
        if visible {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func appKitFrame(_ frame: CGRect?) -> NSRect? {
        guard let frame, let primary = NSScreen.screens.first,
              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return nil }
        return NSRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    private func followLightroomWindow() {
        guard !resizingPanel, let frame = latestWindowFrame, NSEvent.pressedMouseButtons == 0 else { return }
        let inset: CGFloat = 12
        let x = min(max(frame.minX + offset.x, frame.minX + inset), max(frame.minX + inset, frame.maxX - panel.frame.width - inset))
        let y = min(max(frame.maxY - offset.y - panel.frame.height, frame.minY + inset), max(frame.minY + inset, frame.maxY - panel.frame.height - inset))
        let point = NSPoint(x: x, y: y)
        guard abs(point.x - panel.frame.minX) > 0.5 || abs(point.y - panel.frame.minY) > 0.5 else { return }
        applyingPosition = true
        panel.setFrameOrigin(point)
        applyingPosition = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !applyingPosition, !resizingPanel, let frame = latestWindowFrame else { return }
        offset = NSPoint(x: panel.frame.minX - frame.minX, y: frame.maxY - panel.frame.maxY)
        UserDefaults.standard.set(offset.x, forKey: "PanelOffsetX")
        UserDefaults.standard.set(offset.y, forKey: "PanelOffsetY")
    }

    private func resizePanel(to height: CGFloat, animated: Bool) {
        resizeGeneration += 1
        let generation = resizeGeneration
        resizingPanel = true
        let current = panel.frame
        let target = NSRect(x: current.minX, y: current.maxY - height, width: InfoPanelContent.panelSize.width, height: height)
        let finish: () -> Void = { [weak self] in
            guard let self, self.resizeGeneration == generation else { return }
            self.resizingPanel = false
            self.followLightroomWindow()
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = InfoPanelContent.expansionDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }, completionHandler: finish)
        } else {
            panel.setFrame(target, display: true)
            finish()
        }
    }

    private func positionPermissionPanel() {
        if latestWindowFrame != nil { followLightroomWindow(); return }
        guard let screen = NSScreen.main else { return }
        applyingPosition = true
        panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.maxY - 76))
        applyingPosition = false
    }

    private func requestPermissionOnce() {
        guard !didRequestPermission else { return }
        didRequestPermission = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func diagnostic(_ object: [String: Any]) {
        guard let diagnosticPath,
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]),
              let value = String(data: data, encoding: .utf8), value != lastDiagnostic else { return }
        lastDiagnostic = value
        try? data.write(to: URL(fileURLWithPath: diagnosticPath), options: .atomic)
        print(value)
        fflush(stdout)
    }

    @objc private func showPanel() { paused = false; updateWorkspaceState(); updatePolling(); tick() }
    @objc private func hidePanel() { paused = true; updatePolling(); hideForBinding(reason: "userHidden") }

    @objc private func openSettings() {
        if settingsController == nil {
            let controller = AppearanceSettingsWindowController(settings: appearance)
            controller.onVisibilityChange = { [weak self] visible in
                guard let self else { return }
                self.settingsVisible = visible
                self.applicationChanged()
                if !visible, self.restoreLightroomAfterSettings, self.ownApplicationForeground {
                    NSRunningApplication.runningApplications(withBundleIdentifier: LightroomSelectionReader.bundleID).first?.activate(options: [])
                }
            }
            settingsController = controller
        }
        if !settingsVisible { restoreLightroomAfterSettings = lightroomForeground }
        settingsController?.showSettings()
    }

    @objc private func openAccessibility() {
        didRequestPermission = false
        requestPermissionOnce()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hidePanel(); return false }
    @objc private func quit() { NSApp.terminate(nil) }
}
