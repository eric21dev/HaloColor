// halo's border STYLE holder — thin, timer-less state over sill's pure
// `resolveBorder`. Holds the `[border]` config + the focus-flash cell; the
// ring view samples `color` / `width` each repaint. The redraw CADENCE is
// owned by `BorderController`'s one 30 Hz clock (shared with the line-pets),
// NOT here — so the border and the pets ride a SINGLE wall-clock `now`, and
// there's no longer a timer that exists just to keep redrawing pets (the old
// `petsActive` hack is gone).
//
// The animation MATH — width breathing, the 5-blink flash burst, and the
// rainbow / cycle / steady color resolve — lives in sill's CLOCKLESS
// `Effects.resolveBorder` / `rollFlash`, shared byte-for-byte with facet (the
// formerly-duplicated `BorderFX` animator, reconciled into one pure function).
// halo keeps only the app-side bits: the `NSColor` materialization and the
// configurable `baseColor` "off" fallback (halo has no panel palette, so it
// can't fall back to facet's per-surface `pal.primary`).
//
// @MainActor, like facet's: the second consumer of `resolveBorder` sits on
// the same isolation as the first.

import AppKit
import Effects
import HaloCore
import QuartzCore   // CACurrentMediaTime — the shared border + pets clock

@MainActor
final class BorderFX {
    private var fx: EffectSpec?
    private var glowOn = false
    private var baseW: Double = 3
    private var cycleSeconds: Double = 6
    private var minW: Double?
    private var maxW: Double?
    private var cycleColors = false
    /// Resting color when no effect is active ("off").
    var baseColor: NSColor = .systemTeal

    /// The focus-flash burst — pre-rolled on a focus change, decayed by
    /// wall-clock. nil = not flashing.
    private var flashState: FlashState?
    /// A short in-place brightness pulse for the static/app-color mode,
    /// so focus feedback can be enabled without replacing the app's hue.
    private var staticFlashStart: Double?

    init() {}

    func configure(effectName: String, glow: Bool, width: CGFloat,
                   cycleSeconds cs: CGFloat, cycleColors cc: Bool,
                   minWidth: CGFloat?, maxWidth: CGFloat?, baseColor bc: NSColor) {
        fx = borderEffectFor(effectName)
        glowOn = glow
        baseW = Double(width)
        cycleSeconds = max(1, Double(cs))
        cycleColors = cc
        minW = minWidth.map(Double.init)
        maxW = maxWidth.map(Double.init)
        baseColor = bc
    }

    var glowEnabled: Bool { glowOn }

    /// The ring's color + width for wall-clock `now` — sampled ONCE per
    /// `draw(_:)` so the two stay consistent across a flash boundary (and so
    /// the border shares the exact `now` the pets walk on).
    func sample(at now: Double) -> (color: NSColor, width: CGFloat) {
        let fr = resolveBorder(spec: fx, baseWidth: baseW, minWidth: minW, maxWidth: maxW,
                               cycleSeconds: cycleSeconds, cycleColors: cycleColors,
                               now: now, flash: flashState)
        var color: NSColor
        switch fr.color {
        case .off:
            color = baseColor
        case .rgb(let r, let g, let b):
            color = NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
        case .rainbowHue(let h):
            color = NSColor(hue: CGFloat(h), saturation: 0.9, brightness: 1, alpha: 1)
        }
        var width = CGFloat(fr.width)
        if fx == nil, let started = staticFlashStart {
            let elapsed = now - started
            if elapsed < 0.48 {
                let envelope = max(0, 1 - elapsed / 0.48)
                let pulse = abs(sin(elapsed * .pi * 6)) * envelope
                let blend = CGFloat(min(0.62, 0.18 + pulse * 0.44))
                color = color.blended(withFraction: blend, of: .white) ?? color
                width *= CGFloat(1 + pulse * 0.45)
            } else {
                staticFlashStart = nil
            }
        }
        return (color, width)
    }

    /// Start a focus flash: a 5-blink burst through the effect's palette.
    /// No-op when off / palette-less (then the ring just re-hugs silently).
    func flash() {
        if let fx, !fx.flash.isEmpty {
            flashState = rollFlash(fx.flash, now: CACurrentMediaTime())
        } else {
            staticFlashStart = CACurrentMediaTime()
        }
    }

    /// Is the BORDER itself animating right now? (rainbow / cycle-colors /
    /// breathing, or a flash burst mid-flight.) `BorderController`'s redraw
    /// clock ORs this with "has line-pets" to decide whether to keep ticking.
    func animating(at now: Double) -> Bool {
        let cyclingOrBreathing = (fx?.cycles ?? false) || (cycleColors && fx != nil) || breathing
        if fx != nil && cyclingOrBreathing { return true }
        if let started = staticFlashStart, now - started < 0.48 { return true }
        return flashState?.isActive(now: now) ?? false
    }

    private var breathing: Bool {
        guard fx != nil, let lo = minW, let hi = maxW else { return false }
        return hi > lo
    }
}
