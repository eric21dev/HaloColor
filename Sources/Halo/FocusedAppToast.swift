import AppKit
import QuartzCore

/// A click-through, non-activating centered label shown after focus changes.
@MainActor
final class FocusedAppToast {
    private let panel: NSPanel
    private let labelView = FocusedAppToastView(frame: .zero)
    private var hideTimer: Timer?
    private var generation = 0

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 88),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = labelView
    }

    func show(name: String, color: NSColor) {
        generation += 1
        let current = generation
        hideTimer?.invalidate()
        labelView.title = name
        labelView.titleColor = color

        let font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        let textSize = (name as NSString).size(withAttributes: [.font: font])
        let width = min(640, max(190, textSize.width + 56))
        let size = NSSize(width: width, height: 88)
        let screen = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: screen.midX - size.width / 2,
                              y: screen.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOut(generation: current) }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    func hide() {
        generation += 1
        hideTimer?.invalidate()
        hideTimer = nil
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func fadeOut(generation current: Int) {
        guard current == generation else { return }
        hideTimer = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, current == self.generation else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }
}

private final class FocusedAppToastView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var titleColor: NSColor = .white { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                   xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.black.withAlphaComponent(0.58).setFill()
        capsule.fill()

        let font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = titleColor.withAlphaComponent(0.75)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = .zero
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: titleColor,
            .shadow: shadow,
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let point = NSPoint(x: (bounds.width - textSize.width) / 2,
                            y: (bounds.height - textSize.height) / 2)
        (title as NSString).draw(at: point, withAttributes: attributes)
    }
}
