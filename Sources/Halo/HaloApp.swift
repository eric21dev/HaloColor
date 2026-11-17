import AppKit
import ApplicationServices
import HaloCore

// halo — active-window border. Entry point + lifecycle.
//
// `@main enum HaloApp` — NOT top-level `main.swift`: the enum form keeps
// `@testable import Halo` possible without launching the agent (the
// family's shape — perch / wand / chord / glance). The file is named
// after the type, not `Main.swift`: a case-only rename of main.swift
// fails `git checkout` on a case-insensitive APFS checkout (measured on
// capsule's worktree, 2026-09-03).
//
// CLI surface. halo is config-driven — `~/.config/halo/config.toml`
// (hot-reloaded on save) is the entire control plane; there is no runtime
// control CLI (atelier Phase 3 classifies halo OUT of the domain-verb
// grammar — inventing a control CLI would be a feature, not a refactor).
// The only recognised flags are `--emit-schema` and the family `-h`/`--help`
// carve-out. ANY other argument is rejected loudly with exit 2 (the family
// "no silent fallback" sub-rule) instead of being silently ignored while
// halo launches anyway. A normal agent launch (`open Halo.app`, brew
// services, LaunchAgent) passes no argv, so this never blocks startup.
@main
enum HaloApp {
    @MainActor
    static func main() {
        let cliArgs = Array(CommandLine.arguments.dropFirst())

        if cliArgs.contains("--help") || cliArgs.contains("-h") {
            print("""
            halo — active-window border for macOS.

            USAGE
              halo                  run as agent (config-driven; no runtime CLI)
              halo --emit-schema    print the config.toml JSON Schema (Draft-07)
              halo --help, -h       this help

            EXIT CODES
              0   success
              2   unknown argument (loud on stderr)

            CONFIG
              ~/.config/halo/config.toml is the single source of truth, hot-reloaded
              on save. halo has no control flags — every knob lives in the file.

            DOCS
              https://github.com/akira-toriyama/halo
            """)
            exit(0)
        }

        // `--emit-schema` is a one-shot: print the `config.toml` JSON Schema
        // (Draft-07) to stdout and exit. Generated from the same declarative
        // `configSpec` that decodes the config, so the two can't drift. The repo
        // regenerates `config.schema.json` with `halo --emit-schema > config.schema.json`.
        if cliArgs.contains("--emit-schema") {
            print(HaloConfig.jsonSchema, terminator: "")
            exit(0)
        }

        // Reject anything else loudly (no silent fallback). `--emit-schema` /
        // `--help` / `-h` exited above, so any remaining token is unrecognised.
        if let bad = cliArgs.first {
            FileHandle.standardError.write(Data((
                "halo: unknown argument \"\(bad)\" — halo is config-driven and has "
                + "no control CLI. See `halo --help`.\n"
            ).utf8))
            exit(2)
        }

        // Refresh the taplo schema sidecar next to the user config so editor
        // completion/validation just works (idempotent; writes only on change,
        // and the watcher polls config.toml's mtime not this sibling, so no
        // hot-reload churn). Best-effort — never blocks start.
        HaloConfig.installSchema()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)        // LSUIElement: agent, no Dock icon
        // NSApp holds its delegate weakly: keep it alive for the whole run
        // by contract, not by the optimizer's ordering of the last release.
        withExtendedLifetime(HaloDelegate()) { delegate in
            app.delegate = delegate
            app.run()
        }
    }
}

// An LSUIElement agent (no Dock icon, never steals focus). It opens a
// dedicated window-event connection, then keeps a transparent ring hugged
// to whatever window is frontmost. Config is owned by BorderController
// (loaded there, hot-reloaded there); the delegate only wires the seam.
@MainActor
final class HaloDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let events = WindowServerEvents()
    private var border: BorderController!
    private var statusItem: NSStatusItem?
    private var settingsWindow: HaloColorSettingsWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        Log.line("halo up (verbose=\(Log.enabled))")

        border = BorderController(events: events)
        installMenuBarItem()

        // The ring itself is read-only, but focus-shake MOVES the focused
        // window via AX, which needs Accessibility. Prompt only when the
        // feature is on — `shake = false` keeps halo permission-free.
        if border.config.shake,
           !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            Log.line("focus-shake needs Accessibility — grant Halo Color in System Settings → "
                + "Privacy & Security → Accessibility, then restart (or set shake = false)")
        }

        events.onEvent = { [weak self] event, windowID in
            self?.border.onEvent(event, windowID: windowID)
        }

        guard events.start() else {
            Log.line("‼️ could not start the window-event seam — exiting")
            NSApp.terminate(nil); return
        }
        border.start()
    }

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled",
                                     accessibilityDescription: "Halo Color")
        item.button?.toolTip = "Halo Color"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = NSMenuItem(title: "Colores por app…",
                                  action: #selector(showColorSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let entries = HaloConfig.load().appColorEntries.compactMap { entry -> (String, String)? in
            guard let separator = entry.firstIndex(of: "=") else { return nil }
            let id = String(entry[..<separator])
            let hex = String(entry[entry.index(after: separator)...])
            return (id, hex)
        }
        let apps = NSMenuItem(title: "Apps registradas (\(entries.count))",
                              action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (id, hex) in entries {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
            let name = running?.localizedName
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?
                    .deletingPathExtension().lastPathComponent ?? id
            let item = NSMenuItem(title: "\(name)  ·  \(hex)",
                                  action: #selector(editAppColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.image = Self.colorSwatch(hex)
            submenu.addItem(item)
        }
        if entries.isEmpty {
            let empty = NSMenuItem(title: "Se añadirán al enfocarlas", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        menu.setSubmenu(submenu, for: apps)
        menu.addItem(apps)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Salir de Halo Color",
                              action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private static func colorSwatch(_ hex: String) -> NSImage? {
        guard hex.hasPrefix("#"), let rgb = Int(hex.dropFirst(), radix: 16) else { return nil }
        let color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                            green: CGFloat((rgb >> 8) & 255) / 255,
                            blue: CGFloat(rgb & 255) / 255, alpha: 1)
        return NSImage(size: NSSize(width: 15, height: 15), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func showColorSettings() {
        if settingsWindow == nil { settingsWindow = HaloColorSettingsWindow() }
        settingsWindow?.show()
    }

    @objc private func editAppColor(_ item: NSMenuItem) {
        guard let bundleID = item.representedObject as? String else { return }
        if settingsWindow == nil { settingsWindow = HaloColorSettingsWindow() }
        settingsWindow?.show(bundleID: bundleID)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}
