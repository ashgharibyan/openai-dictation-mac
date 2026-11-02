import AppKit
import Combine
import DictateCore
import SwiftUI

/// Floating, non-activating indicator near the bottom of the screen. It never becomes key or
/// main, so the app you are dictating into keeps keyboard focus, and its buttons still work.
final class HUDPanel: NSPanel {
    init(rootView: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = [.intrinsicContentSize]
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDController {
    private let panel: HUDPanel
    private let controller: DictationController
    private var cancellables = Set<AnyCancellable>()

    init(controller: DictationController) {
        self.controller = controller
        panel = HUDPanel(rootView: HUDView(controller: controller))
        controller.$phase
            .combineLatest(controller.settings.$showHUD)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, enabled in self?.update(phase: phase, enabled: enabled) }
            .store(in: &cancellables)
        // Keep the panel centred as its content (message length) changes size.
        controller.$message
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reposition() } }
            .store(in: &cancellables)
    }

    private func update(phase: DictationPhase, enabled: Bool) {
        // Errors are shown even with the indicator turned off, so failures are never silent.
        let visible = phase != .idle && (enabled || phase == .error)
        if visible {
            if !panel.isVisible { reposition(onMouseScreen: true) }
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private var screen: NSScreen?

    private func reposition(onMouseScreen: Bool = false) {
        if onMouseScreen || screen == nil {
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        }
        guard let screen, let content = panel.contentView else { return }
        let size = content.fittingSize
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 48, width: size.width, height: size.height),
                       display: true)
    }
}

struct HUDView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(spacing: 12) {
            icon
            content
            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 220, maxWidth: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(16)
        .animation(.easeOut(duration: 0.15), value: controller.phase)
    }

    @ViewBuilder private var icon: some View {
        switch controller.phase {
        case .recording:
            Image(systemName: "mic.fill").foregroundStyle(.red).font(.system(size: 16, weight: .semibold))
                .symbolEffect(.pulse, options: .repeating)
        case .transcribing, .inserting:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 16))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 16))
        case .idle:
            Image(systemName: "mic").font(.system(size: 16))
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .recording:
            HStack(spacing: 10) {
                if let start = controller.recordingStartedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(Self.format(context.date.timeIntervalSince(start)))
                            .font(.system(.body, design: .rounded).monospacedDigit())
                    }
                }
                LevelMeter(levels: controller.levels)
            }
        case .transcribing:
            Text(controller.message ?? "Transcribing…").font(.callout)
        case .inserting:
            Text("Inserting…").font(.callout)
        case .success:
            Text(controller.message ?? "Inserted").font(.callout).lineLimit(3)
        case .error:
            Text(controller.message ?? "Something went wrong").font(.callout).lineLimit(4)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var controls: some View {
        switch controller.phase {
        case .recording:
            HUDButton(symbol: "stop.fill", help: "Stop and transcribe") { controller.stopRecording() }
            HUDButton(symbol: "xmark", help: "Cancel (Esc)") { controller.cancel() }
        case .transcribing:
            HUDButton(symbol: "xmark", help: "Cancel (Esc)") { controller.cancel() }
        case .error:
            if controller.pending != nil {
                HUDButton(symbol: "arrow.clockwise", help: "Retry transcription") { controller.retryPending() }
                HUDButton(symbol: "trash", help: "Discard recording") { controller.discardPending() }
            }
            HUDButton(symbol: "xmark", help: "Dismiss") { controller.cancel() }
        default:
            EmptyView()
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct HUDButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.primary.opacity(0.75))
                    .frame(width: 3, height: 4 + CGFloat(levels[i]) * 20)
            }
        }
        .frame(height: 24)
        .animation(.linear(duration: 0.08), value: levels)
    }
}
