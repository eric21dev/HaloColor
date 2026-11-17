import AppKit
import Foundation
import HaloCore

/// The settings view and focus controller use the same on-disk app list.
@MainActor
enum AppColorRegistry {
    static let didChange = Notification.Name("HaloColorAppColorsDidChange")
    static let editRequested = Notification.Name("HaloColorEditAppColor")

    static func registerIfNeeded(bundleID: String) throws -> String? {
        guard !bundleID.isEmpty,
              bundleID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") })
        else { return nil }

        let config = HaloConfig.load()
        let entries = config.appColorEntries
        guard !contains(bundleID: bundleID, in: entries) else { return nil }

        let used = Set(entries.compactMap { entry -> Int? in
            guard let separator = entry.firstIndex(of: "=") else { return nil }
            let id = String(entry[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(config.color(for: id).rgb)
        }).union([Int(config.color.rgb)])
        let hex = nextColor(avoiding: used)
        let url = URL(fileURLWithPath: HaloConfig.configFilePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try replaceEntries(entries + ["\(bundleID)=\(hex)"], in: &source)
        try source.write(to: url, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: didChange, object: nil,
                                        userInfo: ["bundleID": bundleID])
        return hex
    }

    static func contains(bundleID: String, in entries: [String]) -> Bool {
        entries.contains { entry in
            guard let separator = entry.firstIndex(of: "=") else { return false }
            return entry[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }

    static func suggestedColor(usedHexes: [String]) -> String {
        let used = Set(usedHexes.compactMap { value -> Int? in
            let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard hex.hasPrefix("#"), hex.count == 7 else { return nil }
            return Int(hex.dropFirst(), radix: 16)
        })
        return nextColor(avoiding: used)
    }

    static func replaceEntries(_ entries: [String], in source: inout String) throws {
        let section = "[app-colors]\napps = [\n"
            + entries.map { "  \"\($0)\"," }.joined(separator: "\n")
            + (entries.isEmpty ? "" : "\n") + "]\n"
        let regex = try NSRegularExpression(pattern: "(?ms)^\\[app-colors\\]\\s*\\n.*?(?=^\\[|\\z)")
        let range = NSRange(source.startIndex..., in: source)
        if let match = regex.firstMatch(in: source, range: range),
           let swiftRange = Range(match.range, in: source) {
            source.replaceSubrange(swiftRange, with: section + "\n")
        } else {
            if !source.isEmpty && !source.hasSuffix("\n") { source += "\n" }
            source += "\n" + section
        }
    }

    private static func nextColor(avoiding used: Set<Int>) -> String {
        let palette = [0x28A9FF, 0x28D98A, 0xF4C542, 0xFF5B7F,
                       0xB780F5, 0xFB8900, 0x39C5C8, 0xE964C9]
        for rgb in palette where !used.contains(rgb) && separated(rgb, from: used) {
            return String(format: "#%06X", rgb)
        }
        for index in 0..<4096 {
            let hue = CGFloat((Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1))
            let saturation: CGFloat = index.isMultiple(of: 3) ? 0.62 : 0.82
            let brightness: CGFloat = index.isMultiple(of: 4) ? 0.83 : 0.97
            guard let color = NSColor(calibratedHue: hue, saturation: saturation,
                                      brightness: brightness, alpha: 1).usingColorSpace(.deviceRGB)
            else { continue }
            let rgb = (Int((color.redComponent * 255).rounded()) << 16)
                | (Int((color.greenComponent * 255).rounded()) << 8)
                | Int((color.blueComponent * 255).rounded())
            if !used.contains(rgb) && (separated(rgb, from: used) || index >= 2048) {
                return String(format: "#%06X", rgb)
            }
        }
        for rgb in 0...0xFFFFFF where !used.contains(rgb) {
            return String(format: "#%06X", rgb)
        }
        return "#28A9FF"
    }

    private static func separated(_ candidate: Int, from used: Set<Int>) -> Bool {
        used.allSatisfy { other in
            let dr = ((candidate >> 16) & 255) - ((other >> 16) & 255)
            let dg = ((candidate >> 8) & 255) - ((other >> 8) & 255)
            let db = (candidate & 255) - (other & 255)
            return dr * dr + dg * dg + db * db >= 70 * 70
        }
    }
}
