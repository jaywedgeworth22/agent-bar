import AppKit
import SwiftUI

/// Displays the provider mark bundled with the menu bar application.
///
/// The provider key is the canonical key used by QuotaCore.  Unknown keys
/// deliberately use a neutral SF Symbol instead of guessing at a brand.
///
/// Marks are template images: only their silhouette is used, and the colour
/// comes from the label, so one asset is legible on a light and a dark surface.
public struct PlatformLogo: View {
    public let providerKey: String
    public let size: CGFloat
    /// The colour the mark is drawn in.  Nil takes the label colour, which is
    /// what makes a mark black in Light and white in Dark.
    public let tint: Color?

    public init(providerKey: String, size: CGFloat = 22, tint: Color? = nil) {
        self.providerKey = providerKey
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        Group {
            if let image = PlatformLogoImage.load(providerKey: providerKey) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint ?? Theme.ink)
            } else {
                Image(systemName: "questionmark.circle")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

public enum PlatformLogoImage {
    private static let cache = NSCache<NSString, NSImage>()
    private static let menuBarCache = NSCache<NSString, NSImage>()

    private static let resourceNames: [String: (name: String, ext: String)] = [
        "anthropic": ("claude", "svg"),
        "claude": ("claude", "svg"),
        "openai": ("openai", "svg"),
        "codex": ("openai", "svg"),
        "google-antigravity": ("gemini", "svg"),
        "antigravity": ("gemini", "svg"),
        "gemini": ("gemini", "svg"),
        "xai": ("grok", "svg"),
        "grok": ("grok", "svg"),
        "grok-cli": ("grok", "svg"),
        "grok-bot": ("grok", "svg"),
        "minimax": ("minimax", "svg"),
        "cursor": ("cursor", "svg"),
    ]

    public static func load(providerKey: String) -> NSImage? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let resource = resourceNames[key],
              let url = Bundle.module.url(forResource: resource.name, withExtension: resource.ext)
                  ?? Bundle.module.url(
                      forResource: resource.name,
                      withExtension: resource.ext,
                      subdirectory: "ProviderMarks"
                  ),
              let cached = cache.object(forKey: key as NSString) ?? NSImage(contentsOf: url) else {
            return nil
        }
        if cache.object(forKey: key as NSString) == nil {
            // Every mark is drawn as a template, so it takes the label colour
            // and reads correctly in both Light and Dark rather than keeping a
            // brand colour that disappears against one of them.
            cached.isTemplate = true
            cache.setObject(cached, forKey: key as NSString)
        }
        return cached
    }

    public static func menuBarImage(providerKey: String, size: CGFloat = 16) -> NSImage? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = menuBarCache.object(forKey: key as NSString) {
            return cached
        }
        guard let original = load(providerKey: key) else {
            return nil
        }
        let targetSize = NSSize(width: size, height: size)
        let img = NSImage(size: targetSize)
        img.lockFocus()
        original.draw(in: NSRect(origin: .zero, size: targetSize),
                      from: NSRect(origin: .zero, size: original.size),
                      operation: .copy,
                      fraction: 1.0)
        img.unlockFocus()
        img.isTemplate = true
        menuBarCache.setObject(img, forKey: key as NSString)
        return img
    }

    public static func fallbackSymbolName(for providerKey: String) -> String {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "anthropic", "claude": return "sparkles"
        case "openai", "codex": return "cpu"
        case "google-antigravity", "antigravity", "gemini": return "sparkle"
        case "xai", "grok", "grok-cli", "grok-bot": return "bolt"
        case "minimax": return "m.square"
        case "cursor": return "cursorarrow.rays"
        default: return "gauge.with.dots.needle.50percent"
        }
    }
}
