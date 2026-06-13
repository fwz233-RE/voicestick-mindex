import AppKit

final class FirmwareUpdateWindowController: NSWindowController {
    private let titleLabel = NSTextField(labelWithString: "正在更新固件")
    private let detailLabel = NSTextField(labelWithString: "正在准备更新...")
    private let progressIndicator = NSProgressIndicator()
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let speedLabel = NSTextField(labelWithString: "速度 --")
    private let timeLabel = NSTextField(labelWithString: "正在估算剩余时间")
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private let startedAt = Date()
    private var confirmedBytes = 0
    var onCancel: (() -> Void)?

    init(fileName: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "固件更新"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent(fileName: fileName)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(progress: FirmwareUpdateProgress) {
        if progress.isDeviceConfirmed {
            confirmedBytes = max(confirmedBytes, progress.writtenBytes)
        }

        let displayedBytes = progress.isDeviceConfirmed ?
            confirmedBytes :
            max(confirmedBytes, min(progress.writtenBytes, confirmedBytes + 64 * 1024))
        let displayedProgress = FirmwareUpdateProgress(
            writtenBytes: displayedBytes,
            totalBytes: progress.totalBytes,
            isDeviceConfirmed: progress.isDeviceConfirmed
        )
        let clamped = min(max(displayedProgress.fraction, 0), 1)
        let percent = Int(clamped * 100)
        progressIndicator.doubleValue = clamped * 100
        percentLabel.stringValue = "\(percent)%"

        let elapsed = max(0.1, Date().timeIntervalSince(startedAt))
        let bytesPerSecond = Double(max(confirmedBytes, displayedBytes)) / elapsed
        speedLabel.stringValue = "速度 \(Self.format(bytesPerSecond: bytesPerSecond))"

        if bytesPerSecond > 1 && displayedBytes < progress.totalBytes {
            let remainingBytes = progress.totalBytes - displayedBytes
            let remaining = Double(max(0, remainingBytes)) / bytesPerSecond
            timeLabel.stringValue = "剩余 \(Self.format(duration: remaining))"
        } else if displayedBytes >= progress.totalBytes {
            timeLabel.stringValue = "正在设备上完成更新"
        }
    }

    func finish(result: Result<Void, Error>) {
        cancelButton.isEnabled = false
        closeButton.isEnabled = true
        switch result {
        case .success:
            titleLabel.stringValue = "固件已更新"
            detailLabel.stringValue = "设备正在重启并进入新固件。"
            progressIndicator.doubleValue = 100
            percentLabel.stringValue = "100%"
            timeLabel.stringValue = "完成"
        case .failure(let error):
            titleLabel.stringValue = "更新失败"
            detailLabel.stringValue = error.localizedDescription
            timeLabel.stringValue = "设备保留当前固件。"
        }
    }

    private func buildContent(fileName: String) {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.stringValue = fileName
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 1

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.doubleValue = 0
        progressIndicator.controlSize = .regular

        let progressRow = NSStackView()
        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.spacing = 10
        progressRow.addArrangedSubview(progressIndicator)
        progressRow.addArrangedSubview(percentLabel)
        percentLabel.alignment = .right
        percentLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true

        timeLabel.textColor = .secondaryLabelColor
        speedLabel.textColor = .secondaryLabelColor

        let detailRow = NSStackView()
        detailRow.orientation = .horizontal
        detailRow.alignment = .centerY
        detailRow.spacing = 12
        detailRow.addArrangedSubview(speedLabel)
        detailRow.addArrangedSubview(timeLabel)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cancelButton.target = self
        cancelButton.action = #selector(cancelUpdate)
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.isEnabled = false
        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(closeButton)

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
        stack.addArrangedSubview(progressRow)
        stack.addArrangedSubview(detailRow)
        stack.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            progressIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            progressRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func closeWindow() {
        window?.close()
    }

    @objc private func cancelUpdate() {
        cancelButton.isEnabled = false
        titleLabel.stringValue = "正在取消固件更新"
        detailLabel.stringValue = "正在停止传输，并请求设备中止更新。"
        timeLabel.stringValue = "正在取消"
        onCancel?()
    }

    private static func format(duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds < 60 {
            return "\(seconds)s"
        }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private static func format(bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .binary
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }
}
