# Provider marks

Every mark here is drawn as a **template image**: `PlatformLogoImage.load` sets `isTemplate = true` and the SwiftUI call site renders it with `.renderingMode(.template)`, so only the silhouette is used and the colour comes from the label — black in Light, white in Dark, on every surface including the menu bar status item.  A mark therefore only has to be a correct *shape*; its own fill colour is discarded.

`claude.svg`, `openai.svg`, `grok.svg` and `minimax.svg` are faithful copies of the provider assets already shipped by BotFleet under `/Users/jay/Code/BotFleet/ios/App/Assets.xcassets/ProviderMark*.imageset/`.  They are bundled for local display only and remain subject to their source project licenses.  Antigravity uses the Gemini mark, and Grok CLI / Grok Bot use the Grok mark; no new artwork was created for them.

`gemini.svg` is the BotFleet mark with its elliptical-arc flags separated (`a14.147 14.147 0 01-4.45-3.001` → `a 14.147 14.147 0 0 1 -4.45 -3.001`) and its three redundant gradient-overlay copies of the base path dropped.  Apple's CoreSVG decoder does not tokenize the terse back-to-back arc flags the minified original used, and silently dropped most of the path — the mark rendered as an unrecognisable fragment.  A `gemini.png` rasterization used to stand in for it; with the arc fix the SVG loads correctly at every size, so the PNG is gone.

`cursor.svg` is from the Simple Icons CDN (`https://cdn.simpleicons.org/cursor`, slug `cursor`), released under CC0 1.0 Universal; the Cursor name and mark remain trademarks of their owner.  It replaces the `cursor.png` raster that was carried because BotFleet ships no Cursor SVG.
