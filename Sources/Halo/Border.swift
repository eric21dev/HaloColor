import AppKit
import ApplicationServices
import QuartzCore   // CACurrentMediaTime — line-pet animation clock
import Effects      // sill: drawLinePets / LinePet / NSColor(HexColor)
import HaloCore

/// AppKit normally keeps windows below the menu bar. A tracking overlay
/// needs its full frame, including the glow margin above a target window;
/// otherwise AppKit shifts the whole ring down while keeping its size.
private final class TrackingOverlayWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// The ring overlay + its driver.
//
// BorderController resolves the frontmost third-party window (front-to-back
// z-order from CGWindowList, skipping halo's own + excluded apps + tiny
// popups), hugs it with a transparent click-through overlay, and flashes
// on focus change. Driven by WindowServerEvents: each MOVE/RESIZE re-hugs
// (smooth follow during a drag), each FRONT/REORDER re-resolves the focused
// window. The ring's look (color / width / glow / cycle / flash) is owned
// by BorderFX — halo's local animator over sill's shared effect catalog
// (`Effects.EffectSpec`). The overlay ↔ ring arithmetic is
// `HaloCore.RingGeometry`; the pick itself is `HaloCore.FocusResolver`.
//
// BorderController is the ONE owner of the config: it loads it, hot-reloads
// it off its own 0.4s safety-net poll, and hands every tunable to fx /
// shake / ring / sound through `applyConfig`.
//
// @MainActor: every entry point (events, timers, the settle re-resolves)
// arrives on the main run loop; the timer / dispatch closures re-enter via
// `MainActor.assumeIsolated`, the family's pattern (facet's BorderFX).

@MainActor
final class BorderController {
    private var cfg: HaloConfig
    private let events: WindowServerEvents
    private var safetyNet: Timer?
    private let overlay = TrackingOverlayWindow(contentRect: .zero, styleMask: [.borderless],
                                                backing: .buffered, defer: true)
    private let fx = BorderFX()
    private let shake = WindowShake()
    private let focusSound = FocusSound()
    private let focusedToast = FocusedAppToast()
    private let ring: RingView
    private var dimOverlays: [UInt32: NSWindow] = [:]
    private let selfPID = ProcessInfo.processInfo.processIdentifier
    private var lastWID: UInt32 = 0
    private var didFirstResolve = false
    private var lastConfigMtime: Date?
    /// The ONE 30 Hz redraw heartbeat — pumps `ring.needsDisplay` while the
    /// border animates (rainbow / breathing / flash) OR line-pets orbit. Both
    /// ride a single wall clock in `RingView.draw`; this is just the cadence,
    /// not an animator (the math is sill's clockless `resolveBorder`).
    private var redrawTimer: Timer?

    /// The config as last applied (launch or hot-reload).
    var config: HaloConfig { cfg }

    init(events: WindowServerEvents) {
        let config = HaloConfig.load()
        self.cfg = config
        self.events = events
        self.ring = RingView(config: config, fx: fx)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.ignoresMouseEvents = true               // click-through
        overlay.level = .floating
        overlay.hasShadow = false
        overlay.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]  // desktop-local (rides the Space slide)
        overlay.contentView = ring

        applyConfig(config)
        lastConfigMtime = Self.configMtime()
    }

    /// First resolve + the safety net (yabai-style): periodically
    /// re-subscribe the on-screen set + re-hug, so windows opened after
    /// launch start emitting MOVE/RESIZE and a missed event can't leave the
    /// ring stale. The live, smooth tracking still comes from the ~5ms
    /// events. The same tick carries the config mtime check (hot-reload).
    func start() {
        poll()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        safetyNet = timer
    }

    /// (Re)apply a config to fx / shake / ring. One path for both launch
    /// and hot-reload, so every tunable lands the same way.
    private func applyConfig(_ c: HaloConfig) {
        cfg = c
        ring.cfg = c
        if !c.showAppNameOnFocus { focusedToast.hide() }
        shake.amplitude = c.shakeAmplitude
        shake.durationMs = c.shakeDurationMs
        // Halo Color always uses the app's static color. Keep focus flash as
        // a brightness pulse; effect palettes and palette cycling must not
        // replace per-app colors.
        fx.configure(effectName: "off", glow: c.glow, width: c.width,
                     cycleSeconds: c.cycleSeconds, cycleColors: false,
                     minWidth: nil, maxWidth: nil, baseColor: NSColor(c.color))
        focusSound.configure(path: c.sound, volume: c.soundVolume)
        ring.needsDisplay = true
        syncRedraw()
    }

    /// Start / stop the 30 Hz redraw heartbeat to match what's animating now
    /// (border cycle / breath / flash, or line-pets orbiting forever while
    /// configured). Called whenever the animated state can change: configure,
    /// focus flash. A static border with no pets parks the timer entirely.
    private func syncRedraw() {
        if fx.animating(at: CACurrentMediaTime()) || hasOrbitEffect {
            startRedraw()
        } else {
            stopRedraw()
        }
    }

    private func startRedraw() {
        guard redrawTimer == nil else { return }
        // 30 Hz, .common so it keeps ticking during interaction. Self-stops in
        // the tick once nothing animates (the flash burst settles by wall-clock).
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ring.needsDisplay = true
                if !(self.fx.animating(at: CACurrentMediaTime()) || self.hasOrbitEffect) {
                    self.stopRedraw()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        redrawTimer = t
    }

    private func stopRedraw() { redrawTimer?.invalidate(); redrawTimer = nil }

    private var hasOrbitEffect: Bool {
        cfg.orbitEffect != "none" || !cfg.linePets.isEmpty
    }

    private static func configMtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: HaloConfig.configFilePath))?[.modificationDate] as? Date
    }

    /// Hot-reload: re-read + re-apply config when its mtime changes.
    /// Driven off the existing 0.4s safety-net poll (≤0.4s latency), which
    /// also covers editors that atomically replace the file (mtime/inode
    /// changes regardless). halo has no CLI/DNC client like facet, so
    /// polling the file's mtime is the natural trigger.
    private func reloadIfConfigChanged() {
        let m = Self.configMtime()
        guard m != lastConfigMtime else { return }
        lastConfigMtime = m
        let shakeWasEnabled = cfg.shake
        Log.line("config changed → hot-reload")
        applyConfig(HaloConfig.load())
        // If shake was just turned on but Accessibility isn't granted,
        // fire() would silently no-op — say so (grant takes effect live,
        // no restart, since fire() re-checks trust each time).
        if cfg.shake && !WindowShake.trusted {
            if !shakeWasEnabled {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            Log.line("shake is on but Accessibility isn't granted — enable Halo Color in "
                + "System Settings → Privacy & Security → Accessibility (no restart needed)")
        }
    }

    /// A window-server event arrived (fired on the main thread).
    func onEvent(_ event: UInt32) {
        if event != WindowServerEvents.MOVE { Log.debug("evt-\(event)") }
        update(trigger: "event-\(event)", resubscribe: event == WindowServerEvents.FRONT)
        // 1508 (app-switch) / 808 (same-app window-switch) fire BEFORE the
        // window server's z-order settles, so the immediate re-resolve reads
        // the OLD front and misses (then the 0.4s poll catches it — late).
        // Re-resolve a few times as it commits; the first that sees the new
        // front logs + flashes. (JankyBorders defers ~50ms for this.)
        if event == WindowServerEvents.FRONT || event == WindowServerEvents.REORDER {
            for ms in [16, 40, 80] {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(ms) / 1000) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.update(trigger: "event-\(event)+\(ms)ms", resubscribe: false)
                    }
                }
            }
        }
    }

    /// Periodic safety-net pass (re-subscribe the on-screen set + re-hug),
    /// plus the hot-reload mtime check.
    func poll() { reloadIfConfigChanged(); update(trigger: "poll", resubscribe: true) }

    /// One pass over a SINGLE window-server snapshot — drives both the
    /// per-window (re)subscription AND the focused-window resolve.
    private func update(trigger: String, resubscribe: Bool) {
        let t0 = ProcessInfo.processInfo.systemUptime
        let info = windowInfo()
        let resolveMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        if trigger == "poll" { Log.debug(String(format: "resolve %.2fms (%d windows)", resolveMs, info.count)) }

        if resubscribe {
            events.requestWindows(info.map(\.id))
        }
        // Settings is the only Halo Color window that can receive the ring.
        // Use its own WindowServer bounds while this app is active.
        let settingsWindow = NSApp.isActive
            ? NSApp.windows.first(where: { $0.title == "Colores por app · Halo Color" && $0.isVisible })
            : nil
        let settingsSnapshot: WindowSnapshot? = settingsWindow.map { window in
            info.first(where: { $0.id == UInt32(window.windowNumber) }) ?? WindowSnapshot(
                id: UInt32(window.windowNumber), ownerPID: selfPID,
                bounds: CGRect(x: window.frame.minX,
                               y: (NSScreen.screens.first?.frame.height ?? 0) - window.frame.maxY,
                               width: window.frame.width, height: window.frame.height))
        }
        guard let front = settingsSnapshot ?? FocusResolver.focused(
            in: info, selfPID: selfPID, minSize: cfg.minSize, isExcluded: isExcluded)
        else {
            overlay.orderOut(nil)
            clearDimOverlays()
            focusedToast.hide()
            lastWID = 0
            return
        }
        let (wid, pid) = (front.id, front.ownerPID)
        let focusedApp = NSRunningApplication(processIdentifier: pid)
        let bundleID = focusedApp?.bundleIdentifier
        // Always resolve the app color, including the global fallback when
        // the app-color list is empty or this app has no entry.
        fx.baseColor = NSColor(cfg.color(for: bundleID))
        let screenH = NSScreen.screens.first?.frame.height ?? 0      // CG (y-down) → Cocoa (y-up)
        updateDimOverlays(in: info, focusedPID: pid, screenHeight: screenH)
        overlay.setFrame(RingGeometry.overlayFrame(hugging: front.bounds, screenHeight: screenH),
                         display: true)
        if !overlay.isVisible { overlay.orderFrontRegardless() }
        ring.needsDisplay = true
        if wid != lastWID {
            lastWID = wid
            Log.debug(String(format: "focus → wid=%u via %@ (resolve %.2fms)", wid, trigger, resolveMs))
            if cfg.showAppNameOnFocus {
                let name = focusedApp?.localizedName ?? bundleID ?? "Aplicación"
                focusedToast.show(name: name, color: NSColor(cfg.color(for: bundleID)))
            }
            if cfg.flashOnFocus { fx.flash() }
            syncRedraw()
            // Gate the shake + sound on didFirstResolve (set once, never
            // reset) — NOT on lastWID, which the no-focus branch above resets
            // to 0; that would suppress them after any transient defocus.
            // didFirstResolve also keeps both off the launch resolve (halo
            // just started — you didn't change focus).
            if didFirstResolve { focusSound.play() }
            if cfg.shake && didFirstResolve { shake.fire(pid: pid_t(pid), wid: wid) }
        }
        didFirstResolve = true
    }

    /// Put a click-through tint immediately above each inactive app window
    /// but below windows stacked in front of it. This dims background apps
    /// without covering the focused window or intercepting input.
    private func updateDimOverlays(in windows: [WindowSnapshot], focusedPID: Int32,
                                   screenHeight: CGFloat) {
        guard cfg.dimInactive > 0 else { clearDimOverlays(); return }
        var wanted = Set<UInt32>()
        for window in windows.reversed() {
            guard window.ownerPID != selfPID,
                  window.ownerPID != focusedPID,
                  window.bounds.width >= cfg.minSize,
                  window.bounds.height >= cfg.minSize else { continue }
            wanted.insert(window.id)
            let dim = dimOverlays[window.id] ?? makeDimOverlay(for: window.id)
            if dimOverlays[window.id] == nil { dimOverlays[window.id] = dim }
            if let view = dim.contentView as? DimOverlayView {
                view.amount = CGFloat(cfg.dimInactive)
            }
            let frame = CGRect(x: window.bounds.minX,
                               y: screenHeight - window.bounds.maxY,
                               width: window.bounds.width,
                               height: window.bounds.height)
            dim.setFrame(frame, display: true)
            if !dim.isVisible { dim.order(.above, relativeTo: Int(window.id)) }
        }
        let stale = dimOverlays.keys.filter { !wanted.contains($0) }
        for id in stale {
            dimOverlays[id]?.orderOut(nil)
            dimOverlays.removeValue(forKey: id)
        }
    }

    private func makeDimOverlay(for windowID: UInt32) -> NSWindow {
        let dim = TrackingOverlayWindow(contentRect: .zero, styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        dim.isOpaque = false
        dim.backgroundColor = .clear
        dim.ignoresMouseEvents = true
        dim.level = .normal
        dim.hasShadow = false
        dim.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        dim.contentView = DimOverlayView(frame: .zero)
        return dim
    }

    private func clearDimOverlays() {
        for window in dimOverlays.values { window.orderOut(nil) }
        dimOverlays.removeAll()
    }

    /// `[exclude].apps` check for a candidate's pid. Resolves the bundle
    /// id lazily — only when an exclusion is configured — so the common
    /// empty case never touches NSRunningApplication.
    private func isExcluded(pid: Int32) -> Bool {
        guard !cfg.excludedApps.isEmpty else { return false }
        let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        return cfg.isExcluded(bundleID: bid)
    }

    /// On-screen, layer-0 (normal) windows, front-to-back, as the pure
    /// snapshot `FocusResolver` reads. Rows missing an id / pid / bounds
    /// are dropped here (they can't be hugged anyway).
    private func windowInfo() -> [WindowSnapshot] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let pid = d[kCGWindowOwnerPID as String] as? Int32,
                  let wid = d[kCGWindowNumber as String] as? UInt32,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"]
            else { return nil }
            return WindowSnapshot(id: wid, ownerPID: pid, bounds: CGRect(x: x, y: y, width: w, height: h))
        }
    }
}

private final class DimOverlayView: NSView {
    var amount: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard amount > 0 else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(amount).setFill()
        path.fill()
    }
}

/// The rounded stroke. Reads its style live from BorderFX (color / width /
/// glow / cycle / flash), so all of facet's border effects apply.
final class RingView: NSView {
    var cfg: HaloConfig                 // var: swapped on hot-reload
    private let fx: BorderFX

    init(config: HaloConfig, fx: BorderFX) { self.cfg = config; self.fx = fx; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // NSBezierPath strokes are centred on their path. Move that path
        // inward by half the line width so the visible outer edge sits at
        // exactly the requested distance from the window frame.
        let now = CACurrentMediaTime()
        let style = fx.sample(at: now)
        let rect = RingGeometry.ringRect(in: bounds, pad: cfg.pad - style.width / 2)
        guard rect.width > 0, rect.height > 0 else { return }
        let radius: CGFloat
        switch cfg.borderStyle {
        case "square": radius = 0
        default: radius = cfg.cornerRadius
        }
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        // ONE wall-clock sample for the whole frame: the border color/width and
        // the pets below walk on the exact same `now` (the "one clock").
        path.lineWidth = style.width
        if cfg.borderStyle == "dashed" {
            let dash: [CGFloat] = [max(8, style.width * 4), max(5, style.width * 2)]
            path.setLineDash(dash, count: dash.count, phase: 0)
        } else if cfg.borderStyle == "dotted" {
            path.lineCapStyle = .round
            let dash: [CGFloat] = [0.1, max(5, style.width * 2.5)]
            path.setLineDash(dash, count: dash.count, phase: 0)
        }
        let stroke = style.color
        stroke.setStroke()
        // Isolate the glow shadow to the ring stroke so it doesn't bloom
        // under the pets drawn next.
        NSGraphicsContext.saveGraphicsState()
        if fx.glowEnabled {
            let shadow = NSShadow()
            shadow.shadowColor = stroke
            shadow.shadowBlurRadius = max(6, style.width * 4)
            shadow.set()
        }
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Arcade pets orbiting the ring (opt-in via `line-pets`). They ride
        // the same `rect` the ring strokes, so they walk ON the border. The
        // shared sill drawing; halo owns only the rect + the redraw cadence
        // (BorderFX keeps its timer alive while pets are configured).
        let selectedPets: [LinePet]
        switch cfg.orbitEffect {
        case "chomp": selectedPets = [.chomp]
        case "ghost": selectedPets = [.ghost]
        case "spark", "comet": selectedPets = []
        default: selectedPets = cfg.linePets
        }
        if !selectedPets.isEmpty {
            drawLinePets(selectedPets, on: rect, now: now, scale: cfg.petScale,
                         speed: PetOrbit.speed(around: rect, lapSeconds: cfg.petLapSeconds))
        }
        if cfg.orbitEffect == "spark" || cfg.orbitEffect == "comet" {
            drawOrbitAccent(on: rect, now: now, color: stroke)
        }
    }

    private func drawOrbitAccent(on rect: CGRect, now: Double, color: NSColor) {
        let perimeter = 2 * (rect.width + rect.height)
        guard perimeter > 0 else { return }
        let distance = CGFloat(now.truncatingRemainder(dividingBy: 5) / 5) * perimeter
        func point(_ d: CGFloat) -> CGPoint {
            var offset = (d + perimeter).truncatingRemainder(dividingBy: perimeter)
            if offset < rect.width { return CGPoint(x: rect.minX + offset, y: rect.minY) }
            offset -= rect.width
            if offset < rect.height { return CGPoint(x: rect.maxX, y: rect.minY + offset) }
            offset -= rect.height
            if offset < rect.width { return CGPoint(x: rect.maxX - offset, y: rect.maxY) }
            offset -= rect.width
            return CGPoint(x: rect.minX, y: rect.maxY - offset)
        }
        let count = cfg.orbitEffect == "comet" ? 9 : 5
        for index in (0..<count).reversed() {
            let position = point(distance - CGFloat(index) * 7)
            let size: CGFloat = cfg.orbitEffect == "comet" ? max(2, 8 - CGFloat(index) * 0.7) : (index == 0 ? 9 : 3)
            let dot = NSBezierPath(ovalIn: CGRect(x: position.x - size / 2, y: position.y - size / 2,
                                                 width: size, height: size))
            color.withAlphaComponent(index == 0 ? 1 : max(0.15, 0.7 - CGFloat(index) * 0.08)).setFill()
            dot.fill()
        }
    }
}
