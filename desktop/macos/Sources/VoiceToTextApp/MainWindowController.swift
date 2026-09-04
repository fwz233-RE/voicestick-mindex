import AppKit
import Combine
import SwiftUI

private enum MaterialTheme {
    static let primary = Color(red: 0.27, green: 0.22, blue: 0.69)
    static let primaryContainer = Color(red: 0.91, green: 0.88, blue: 1.0)
    static let onPrimaryContainer = Color(red: 0.12, green: 0.08, blue: 0.35)
    static let surface = Color(red: 0.98, green: 0.98, blue: 1.0)
    static let surfaceContainer = Color(red: 0.94, green: 0.93, blue: 0.98)
    static let surfaceContainerHigh = Color(red: 0.90, green: 0.89, blue: 0.94)
    static let outline = Color(red: 0.47, green: 0.46, blue: 0.52)
    static let onSurface = Color(red: 0.11, green: 0.11, blue: 0.14)
    static let onSurfaceVariant = Color(red: 0.29, green: 0.28, blue: 0.33)
    static let recording = Color(red: 0.73, green: 0.10, blue: 0.12)
    static let recordingContainer = Color(red: 1.0, green: 0.86, blue: 0.85)
}

private enum PanelRecordingPhase {
    case idle
    case preparing
    case recording
    case finishing
}

private final class PopoverViewModel: ObservableObject {
    @Published var status = "Ready to listen"
    @Published var recordingPhase: PanelRecordingPhase = .idle
    @Published var text = ""
    @Published var historyItems: [HistoryItem] = []

    var onToggleRecording: (() -> Void)?
    var onCopy: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onQuit: (() -> Void)?
}

private struct MaterialFilledButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(color.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: color.opacity(configuration.isPressed ? 0.12 : 0.24), radius: 4, x: 0, y: 2)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct MaterialTonalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(MaterialTheme.onPrimaryContainer)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(MaterialTheme.primaryContainer.opacity(configuration.isPressed ? 0.70 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct MaterialIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(MaterialTheme.onSurfaceVariant)
            .frame(width: 28, height: 28)
            .background(configuration.isPressed ? MaterialTheme.surfaceContainerHigh : Color.clear)
            .clipShape(Circle())
    }
}

private final class MaterialNSTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var placeholderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.62)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let drawingFont = font ?? NSFont.systemFont(ofSize: 14)
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        (placeholder as NSString).draw(
            at: origin,
            withAttributes: [
                .font: drawingFont,
                .foregroundColor: placeholderColor
            ]
        )
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

private struct MaterialTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MaterialNSTextView()
        textView.delegate = context.coordinator
        textView.placeholder = "Your transcription will appear here…"
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 15, weight: .regular)
        textView.textColor = NSColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.needsDisplay = true
        textView.scrollToEndOfDocument(nil)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

private struct MaterialPopoverView: View {
    @ObservedObject var model: PopoverViewModel

    private var trimmedText: String {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            statusPill
            transcriptCard
            recordingButton
            actionButtons
            historySection
        }
        .padding(12)
        .frame(width: 370, height: 450)
        .background(MaterialTheme.surface)
        .foregroundColor(MaterialTheme.onSurface)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(MaterialTheme.primaryContainer)
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(MaterialTheme.primary)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("Voice to Text")
                    .font(.system(size: 16, weight: .bold))
                Text("Live speech transcription")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(MaterialTheme.onSurfaceVariant)
            }

            Spacer(minLength: 8)

            Button(action: { model.onQuit?() }) {
                Image(systemName: "power")
            }
            .buttonStyle(MaterialIconButtonStyle())
            .help("Quit")

            Button(action: { model.onClose?() }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(MaterialIconButtonStyle())
            .help("Close")
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.recordingPhase == .recording ? MaterialTheme.recording : MaterialTheme.primary)
                .frame(width: 8, height: 8)
                .shadow(color: (model.recordingPhase == .recording ? MaterialTheme.recording : MaterialTheme.primary).opacity(0.35), radius: 3)

            Text(model.status)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundColor(MaterialTheme.onSurfaceVariant)

            Spacer(minLength: 6)

            Text("Hold 🌐")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(MaterialTheme.onSurfaceVariant)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(MaterialTheme.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(MaterialTheme.surfaceContainer)
        .clipShape(Capsule())
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("TRANSCRIPT", systemImage: "text.alignleft")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(MaterialTheme.primary)
                Spacer()
                Text("\(model.text.count) characters")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(MaterialTheme.onSurfaceVariant)
            }

            MaterialTextEditor(text: $model.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132)
        .background(Color.white.opacity(0.82))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(MaterialTheme.outline.opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var recordingButton: some View {
        Button(action: { model.onToggleRecording?() }) {
            switch model.recordingPhase {
            case .idle:
                Label("Start recording", systemImage: "mic.fill")
            case .preparing:
                Label("Cancel", systemImage: "xmark")
            case .recording:
                Label("Stop recording", systemImage: "stop.fill")
            case .finishing:
                Label("Finishing…", systemImage: "ellipsis")
            }
        }
        .buttonStyle(MaterialFilledButtonStyle(
            color: model.recordingPhase == .recording ? MaterialTheme.recording : MaterialTheme.primary
        ))
        .disabled(model.recordingPhase == .finishing)
        .opacity(model.recordingPhase == .finishing ? 0.66 : 1)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(action: {
                model.onCopy?(model.text)
                model.onClose?()
            }) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(MaterialTonalButtonStyle())
            .disabled(trimmedText.isEmpty)
            .opacity(trimmedText.isEmpty ? 0.48 : 1)

            Button(action: {
                model.text = ""
                model.onClose?()
            }) {
                Label("Clear", systemImage: "eraser")
            }
            .buttonStyle(MaterialTonalButtonStyle())
            .disabled(trimmedText.isEmpty)
            .opacity(trimmedText.isEmpty ? 0.48 : 1)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent activity")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.historyItems.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(MaterialTheme.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(MaterialTheme.primaryContainer)
                    .clipShape(Capsule())
            }

            if model.historyItems.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(MaterialTheme.onSurfaceVariant)
                    Text("Completed transcriptions appear here")
                        .font(.system(size: 12))
                        .foregroundColor(MaterialTheme.onSurfaceVariant)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(MaterialTheme.surfaceContainer.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 4) {
                        ForEach(model.historyItems.prefix(10)) { item in
                            Button(action: { model.text = item.text }) {
                                HStack(spacing: 10) {
                                    Image(systemName: "history")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(MaterialTheme.primary)
                                    Text(item.text.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 12))
                                        .foregroundColor(MaterialTheme.onSurface)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(MaterialTheme.onSurfaceVariant.opacity(0.6))
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(MaterialTheme.surfaceContainer.opacity(0.72))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 56)
            }
        }
    }
}

final class MainWindowController: NSObject, NSPopoverDelegate {
    var onToggleRecording: (() -> Void)? {
        didSet { model.onToggleRecording = onToggleRecording }
    }
    var onCopy: ((String) -> Void)? {
        didSet { model.onCopy = onCopy }
    }
    var onDismiss: (() -> Void)?
    var onQuit: (() -> Void)? {
        didSet { model.onQuit = onQuit }
    }

    private let popover = NSPopover()
    private let model = PopoverViewModel()
    private weak var anchorButton: NSStatusBarButton?

    override init() {
        super.init()
        popover.contentViewController = NSHostingController(rootView: MaterialPopoverView(model: model))
        popover.contentSize = NSSize(width: 370, height: 450)
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .aqua)
        popover.delegate = self
        model.onClose = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { popover.isShown }

    func show(anchoredTo button: NSStatusBarButton? = nil) {
        guard let button else { return }
        anchorButton = button

        // A status item has no stable screen position until AppKit attaches its
        // button to the menu-bar window. Waiting here prevents a (0, 0) anchor.
        guard button.window != nil else {
            DispatchQueue.main.async { [weak self, weak button] in
                guard let self, let button, button.window != nil else { return }
                self.presentPopover(from: button)
            }
            return
        }
        presentPopover(from: button)
    }

    private func presentPopover(from button: NSStatusBarButton) {
        guard !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func hide() {
        popover.performClose(nil)
        model.text = ""
    }

    func popoverDidClose(_ notification: Notification) {
        // This also handles a click outside the popover. Every dismissal starts
        // the next session with an empty input field.
        model.text = ""
        onDismiss?()
    }

    func setStatus(_ text: String) { model.status = text }
    func setPreparing() { model.recordingPhase = .preparing }
    func setRecording(_ recording: Bool) { model.recordingPhase = recording ? .recording : .idle }
    func setFinishing() { model.recordingPhase = .finishing }
    func setText(_ text: String) { model.text = text }
    func currentText() -> String { model.text }
    func setHistory(_ items: [HistoryItem]) { model.historyItems = items }
}
