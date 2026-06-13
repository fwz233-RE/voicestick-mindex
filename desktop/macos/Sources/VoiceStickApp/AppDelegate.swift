import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusController?
    private var coordinator: VoiceStickCoordinator?
    private var settingsWindowController: SettingsWindowController?
    private var pairDeviceWindowController: PairDeviceWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var firmwareUpdateWindowController: FirmwareUpdateWindowController?
    private var dockIconWindowIDs = Set<ObjectIdentifier>()
    private var config = AppConfig.defaults

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        configureApplicationIcon()
        if AppConfig.configExists {
            startApp(config: AppConfig.load())
        } else {
            showOnboarding()
        }
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 VoiceStick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func startApp(config: AppConfig) {
        self.config = config
        let statusController = StatusController(
            pairedDeviceIDs: config.pairedDeviceIDs,
            deviceThemeColors: config.deviceThemeColors,
            deviceOverlayPositions: config.deviceOverlayPositions,
            interactionMode: config.interactionMode,
            autoEnter: config.autoEnter,
            defaultOutputProfile: config.defaultOutputProfile,
            deviceOutputProfiles: config.deviceOutputProfiles
        )
        let coordinator = VoiceStickCoordinator(config: config, statusController: statusController)

        self.statusController = statusController
        self.coordinator = coordinator

        statusController.onQuit = { NSApp.terminate(nil) }
        statusController.onOpenSettings = { [weak self] in
            let controller = self?.settingsWindowController ?? SettingsWindowController()
            self?.settingsWindowController = controller
            controller.onConfigChanged = { [weak self] config in
                self?.config = config
                self?.statusController?.setPairedDeviceIDs(config.pairedDeviceIDs)
                self?.statusController?.setDeviceThemeColors(config.deviceThemeColors)
                self?.statusController?.setDeviceOverlayPositions(config.deviceOverlayPositions)
                self?.statusController?.setInputOptions(
                    interactionMode: config.interactionMode,
                    autoEnter: config.autoEnter
                )
                self?.statusController?.setDefaultOutputProfile(config.defaultOutputProfile)
                self?.statusController?.setDeviceOutputProfiles(config.deviceOutputProfiles)
                self?.coordinator?.updateConfig(config)
            }
            self?.showDockIconWhileWindowVisible(controller)
            controller.show()
        }
        statusController.onPairDevice = { [weak self] in
            self?.showPairDeviceWindow()
        }
        statusController.onForgetDevice = { [weak self] deviceID in
            self?.forgetDevice(deviceID)
        }
        statusController.onUpdateFirmwareDevice = { [weak self] deviceID in
            self?.updateFirmwareFromLatest(for: deviceID)
        }
        coordinator.onFirmwareUpdatePrompt = { [weak self] deviceID, currentVersion, latestVersion, isBelowMinimum in
            self?.showFirmwareUpdatePrompt(
                deviceID: deviceID,
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                isBelowMinimum: isBelowMinimum
            )
        }
        statusController.onRestoreLastInput = { [weak self] in
            self?.coordinator?.restoreLastInputConfirmation() ?? false
        }
        statusController.onSetInteractionMode = { [weak self] mode in
            self?.updateInputOptions(interactionMode: mode, autoEnter: nil)
        }
        statusController.onSetAutoEnter = { [weak self] autoEnter in
            self?.updateInputOptions(interactionMode: nil, autoEnter: autoEnter)
        }
        statusController.onSetDefaultOutputProfile = { [weak self] profile in
            self?.updateDefaultOutputProfile(profile)
        }
        statusController.onSetDeviceOutputProfile = { [weak self] deviceID, profile in
            self?.updateDeviceOutputProfile(deviceID: deviceID, profile: profile)
        }
        statusController.onSetDeviceThemeColor = { [weak self] deviceID, color in
            self?.updateDeviceThemeColor(deviceID: deviceID, color: color)
        }
        statusController.onSetDeviceOverlayPosition = { [weak self] deviceID, position in
            self?.updateDeviceOverlayPosition(deviceID: deviceID, position: position)
        }
        statusController.onCheckForUpdates = { [weak self] in
            self?.checkForApplicationUpdates()
        }
        statusController.setStatus(config.pairedDeviceIDs.isEmpty ? "需要配对 VoiceStick" : "就绪")
        coordinator.start()
    }

    private func updateInputOptions(interactionMode: InteractionMode?, autoEnter: Bool?) {
        var config = self.config
        if let interactionMode {
            config.interactionMode = interactionMode
        }
        if let autoEnter {
            config.autoEnter = autoEnter
        }
        do {
            try config.save()
            self.config = config
            statusController?.setInputOptions(
                interactionMode: config.interactionMode,
                autoEnter: config.autoEnter
            )
            coordinator?.updateConfig(config)
        } catch {
            statusController?.setStatus("输入设置保存失败")
        }
    }

    private func updateDeviceThemeColor(deviceID: String, color: OverlayThemeColor) {
        var config = self.config
        if color == .white {
            config.deviceThemeColors.removeValue(forKey: deviceID)
        } else {
            config.deviceThemeColors[deviceID] = color
        }
        do {
            try config.save()
            self.config = config
            statusController?.setDeviceThemeColors(config.deviceThemeColors)
        } catch {
            statusController?.setStatus("主题保存失败")
        }
    }

    private func updateDefaultOutputProfile(_ profile: OutputProfile) {
        var config = self.config
        config.defaultOutputProfile = profile
        do {
            try config.save()
            self.config = config
            statusController?.setDefaultOutputProfile(profile)
            coordinator?.updateConfig(config)
        } catch {
            statusController?.setStatus("输出设置保存失败")
        }
    }

    private func updateDeviceOutputProfile(deviceID: String, profile: OutputProfile) {
        var config = self.config
        let storedProfile = OutputProfile(
            target: config.defaultOutputProfile.target,
            transform: profile.transform,
            translationTarget: profile.translationTarget
        )
        if storedProfile.transform == config.defaultOutputProfile.transform &&
            storedProfile.translationTarget == config.defaultOutputProfile.translationTarget {
            config.deviceOutputProfiles.removeValue(forKey: deviceID)
        } else {
            config.deviceOutputProfiles[deviceID] = storedProfile
        }
        do {
            try config.save()
            self.config = config
            statusController?.setDeviceOutputProfiles(config.deviceOutputProfiles)
            coordinator?.updateConfig(config)
        } catch {
            statusController?.setStatus("输出设置保存失败")
        }
    }

    private func updateDeviceOverlayPosition(deviceID: String, position: OverlayPosition) {
        var config = self.config
        if position == .center {
            config.deviceOverlayPositions.removeValue(forKey: deviceID)
        } else {
            config.deviceOverlayPositions[deviceID] = position
        }
        do {
            try config.save()
            self.config = config
            statusController?.setDeviceOverlayPositions(config.deviceOverlayPositions)
        } catch {
            statusController?.setStatus("位置保存失败")
        }
    }

    private func showOnboarding() {
        let controller = OnboardingWindowController(config: AppConfig.defaults) { [weak self] config in
            self?.onboardingWindowController = nil
            self?.startApp(config: config)
        }
        onboardingWindowController = controller
        showDockIconWhileWindowVisible(controller)
        controller.show()
    }

    private func configureApplicationIcon() {
        if let image = Self.applicationIconImage() {
            NSApp.applicationIconImage = image
            let imageView = NSImageView(frame: NSRect(x: 4, y: 4, width: 120, height: 120))
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            let dockView = NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
            dockView.addSubview(imageView)
            NSApp.dockTile.contentView = dockView
            NSApp.dockTile.display()
        }
    }

    private func checkForApplicationUpdates() {
        guard let latestReleaseURL = URL(string: "https://api.github.com/repos/fwz233-RE/voicestick-mindex/releases/latest") else {
            openLatestReleasePage()
            return
        }

        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VoiceStick", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil || (response as? HTTPURLResponse)?.statusCode != 200 {
                    self.showUpdateCheckFailed()
                    return
                }
                guard
                    let data,
                    let payload = try? JSONDecoder().decode(GitHubLatestRelease.self, from: data),
                    let latestVersion = Self.normalizedVersion(payload.tagName)
                else {
                    self.showUpdateCheckFailed()
                    return
                }
                if Self.compareVersions(latestVersion, currentVersion) == .orderedDescending {
                    self.showApplicationUpdateAvailable(latestVersion: latestVersion, currentVersion: currentVersion)
                } else {
                    self.showApplicationAlreadyUpToDate(currentVersion: currentVersion)
                }
            }
        }.resume()
    }

    private func showApplicationUpdateAvailable(latestVersion: String, currentVersion: String) {
        let alert = NSAlert()
        alert.messageText = "发现新版本"
        alert.informativeText = "当前版本为 \(currentVersion)，最新版本为 \(latestVersion)。请打开下载页面下载安装新的 DMG。"
        alert.addButton(withTitle: "打开下载页面")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            openLatestReleasePage()
        }
    }

    private func showApplicationAlreadyUpToDate(currentVersion: String) {
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "当前版本为 \(currentVersion)。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showUpdateCheckFailed() {
        let alert = NSAlert()
        alert.messageText = "检查更新失败"
        alert.informativeText = "无法连接到 GitHub Release。你可以直接打开下载页面查看最新版本。"
        alert.addButton(withTitle: "打开下载页面")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            openLatestReleasePage()
        }
    }

    private func openLatestReleasePage() {
        guard let url = URL(string: "https://github.com/fwz233-RE/voicestick-mindex/releases/latest") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func normalizedVersion(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        return version.isEmpty ? nil : version
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftParts = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let rightParts = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(leftParts.count, rightParts.count)
        for index in 0..<count {
            let left = index < leftParts.count ? leftParts[index] : 0
            let right = index < rightParts.count ? rightParts[index] : 0
            if left > right { return .orderedDescending }
            if left < right { return .orderedAscending }
        }
        return .orderedSame
    }

    private struct GitHubLatestRelease: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }

    private func showPairDeviceWindow() {
        var config = AppConfig.load()
        let controller = PairDeviceWindowController(existingDeviceIDs: config.pairedDeviceIDs) { [weak self] deviceID in
            if !config.pairedDeviceIDs.contains(deviceID) {
                config.pairedDeviceIDs.append(deviceID)
            }
            do {
                try config.save()
                self?.config = config
                self?.statusController?.setPairedDeviceIDs(config.pairedDeviceIDs)
                self?.statusController?.setDeviceThemeColors(config.deviceThemeColors)
                self?.statusController?.setDeviceOverlayPositions(config.deviceOverlayPositions)
                self?.coordinator?.updatePairedDeviceIDs(config.pairedDeviceIDs)
                self?.coordinator?.checkFirmwareAfterPairing(deviceID: deviceID)
            } catch {
                self?.statusController?.setStatus("配对保存失败")
            }
        }
        pairDeviceWindowController = controller
        showDockIconWhileWindowVisible(controller)
        controller.show()
    }

    private func updateFirmwareFromLatest(for deviceID: String) {
        let updateWindow = FirmwareUpdateWindowController(fileName: "VS-\(deviceID)")
        updateWindow.onCancel = { [weak self] in
            self?.coordinator?.cancelFirmwareUpdate()
        }
        firmwareUpdateWindowController = updateWindow
        showDockIconWhileWindowVisible(updateWindow)
        updateWindow.show()

        coordinator?.updateFirmwareFromLatest(for: deviceID, progress: { [weak self] progress in
            DispatchQueue.main.async {
                self?.firmwareUpdateWindowController?.update(progress: progress)
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                self?.firmwareUpdateWindowController?.finish(result: result)
            }
        })
    }

    private func showFirmwareUpdatePrompt(deviceID: String,
                                          currentVersion: String,
                                          latestVersion: String,
                                          isBelowMinimum: Bool) {
        let alert = NSAlert()
        alert.messageText = isBelowMinimum ? "建议更新固件" : "有可用固件更新"
        alert.informativeText = "VS-\(deviceID) 当前运行固件 \(currentVersion)。最新固件为 \(latestVersion)。"
        alert.addButton(withTitle: "更新固件")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            updateFirmwareFromLatest(for: deviceID)
        }
    }

    private func showDockIconWhileWindowVisible(_ windowController: NSWindowController) {
        configureApplicationIcon()
        NSApp.setActivationPolicy(.regular)
        configureApplicationIcon()
        guard let window = windowController.window else { return }
        dockIconWindowIDs.insert(ObjectIdentifier(window))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillCloseForDockIcon),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func windowWillCloseForDockIcon(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            dockIconWindowIDs.remove(ObjectIdentifier(window))
        }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: notification.object
        )
        hideDockIconIfNoWindowsAreVisible()
    }

    private func hideDockIconIfNoWindowsAreVisible() {
        DispatchQueue.main.async {
            if self.dockIconWindowIDs.isEmpty {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private static func applicationIconImage() -> NSImage? {
        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()

        let candidateURLs = [
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns"),
            cwd.appendingPathComponent("Resources/AppIcon.icns"),
            cwd.appendingPathComponent("desktop/macos/Resources/AppIcon.icns"),
            executableDirectory?.appendingPathComponent("../../Resources/AppIcon.icns").standardizedFileURL,
            executableDirectory?.appendingPathComponent("../../../Resources/AppIcon.icns").standardizedFileURL,
            executableDirectory?.appendingPathComponent("../../../../Resources/AppIcon.icns").standardizedFileURL
        ]

        for url in candidateURLs.compactMap({ $0 }) where fileManager.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    private func forgetDevice(_ deviceID: String) {
        var config = AppConfig.load()
        config.pairedDeviceIDs.removeAll { $0 == deviceID }
        config.deviceThemeColors.removeValue(forKey: deviceID)
        config.deviceOverlayPositions.removeValue(forKey: deviceID)
        do {
            try config.save()
            statusController?.setPairedDeviceIDs(config.pairedDeviceIDs)
            statusController?.setDeviceThemeColors(config.deviceThemeColors)
            statusController?.setDeviceOverlayPositions(config.deviceOverlayPositions)
            statusController?.setConnectedDevices([])
            coordinator?.updatePairedDeviceIDs(config.pairedDeviceIDs)
        } catch {
            statusController?.setStatus("忘记设备失败")
        }
    }
}
