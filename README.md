# CodeCaps

A macOS menu bar app that reads AI coding CLI quotas already on your Mac, and pushes and pulls them across a fleet of machines you control.

**[Download CodeCaps →](https://jaywedgeworth22.github.io/codecaps/)**

## Why This Exists

CodeCaps reads quota for the AI coding CLIs already signed in on this Mac — no provider API key is ever entered — and can push those readings to a server you run, and pull that server's aggregated readings back, so one Glance popover shows more than one machine's quota at once.

For a single Mac, better tools already exist.  [steipete/CodexBar](https://github.com/steipete/CodexBar) (MIT, 69 providers, signed and notarized) and [tddworks/ClaudeBar](https://github.com/tddworks/ClaudeBar) (MIT, 20+ providers, signed and notarized) both cover every provider CodeCaps does, and go further.  If you only care about the machine in front of you, use one of those instead.

CodeCaps's reason to exist is what neither handles: pushing quota to your own endpoint, and pulling a fleet's worth of machines back into one view.

## What It Shows

CodeCaps has two surfaces.  Nothing renders in both.

**Glance** is the menu bar popover — the two-second check.  One row per platform, grouped under `This Mac` and `Fleet`, each with a percentage, a usage bar, and a reset countdown.  Read-only aside from Refresh, Settings, and Open CodeCaps.

<img src="docs/screenshots/glance-light.png" width="380" alt="Glance, light"> <img src="docs/screenshots/glance-dark.png" width="380" alt="Glance, dark">

**Console** is a resizable window, sidebar split into Quotas and Settings: Quotas is an all-platforms overview plus a per-platform drill-down with search; Settings holds the five pages below.

<img src="docs/screenshots/console-light.png" width="760" alt="Console, light">
<img src="docs/screenshots/console-dark.png" width="760" alt="Console, dark">

## How A Platform's Headline Number Is Chosen

A platform can carry more than one quota window, so each surface has its own rule for which number leads:

- A collapsed row (Glance, or a Console card) shows the **fresh window closest to its cap** — lowest remaining percent — with that window's own reset countdown.
- The **menu bar** has its own picker (Menu Bar → Displayed Quota): *Lowest active quota* (default, lowest percent above 0%), *Lowest quota* (lowest percent outright, zero included), or one window pinned by name.
- The Console's **Next Reset** tile is the soonest reset across every fresh window on every platform — not scoped to whichever is near its cap.

Antigravity sells two independent model pools, shown as two rows, **Gemini** and **Claude & GPT**.  Collapsing them used to show "Antigravity 0%" the moment the Claude/GPT weekly cap was spent, while Gemini still had most of its allowance.  Whenever a pool's weekly window hits zero, its 5-hour percentage is withheld — shown as `n/a` rather than a number that can't mean anything until the week rolls over.

<img src="docs/screenshots/platform-antigravity.png" width="760" alt="Antigravity, Gemini pool">

## Providers

| Provider | What Is Read | Where From |
|---|---|---|
| Claude | Quota windows (5h, weekly) | `~/.claude/.credentials.json`, or the `Claude Code-credentials` Keychain item |
| Codex | Rate-limit windows | `~/.codex/auth.json` |
| Antigravity / Gemini | Pooled Gemini and Claude & GPT quota, two rows (above) | The `antigravity-usage` CLI, plus an RPC to Antigravity's own language server |
| Cursor | Included-plan usage | Cursor.app's local session database (`state.vscdb`) |
| Grok CLI | Billing/credits, via Grok's CLI proxy | `~/.grok/auth.json` |
| Grok Bot | Weekly usage, via Cursor's dashboard service | Same Cursor session database, a different endpoint |
| MiniMax | Per-model and weekly remaining quota | `~/.mmx/config.json` |
| DeepSeek | Not supported | Balance-based, not window-based.  No local reader; a pulled window is filtered out too — never appears anywhere. |

None of the above ever asks for a typed credential — every reader reuses a session or file the CLI already created.

The first time a freshly installed CodeCaps needs Claude Code's Keychain item, macOS asks whether to let it through: the login Keychain grants access per app, and a newly installed CodeCaps is a new app to it, so Claude can show as signed out even while Claude Code is signed in.  Open Console → Settings → Sources & Fleet, press **Allow Access To Claude Code** on the Claude row, and choose **Always Allow** in the panel macOS puts up — it is asked once, it is a read, and CodeCaps never writes to or removes Claude Code's saved login.

## Fleet Push And Pull

Both off by default, configured on Console → Settings → Sources & Fleet.

**Push formats** — two, chosen when pushing.  The producer id stays `agent-bar`, so a rename of the app does not split an existing Usage Monitor history.

`usage_monitor_v2` — one event per quota window:

```json
{
  "schemaVersion": 2,
  "producerId": "agent-bar",
  "producerInstanceId": "Jay's MacBook Pro",
  "events": [
    {
      "eventId": "subq:anthropic:5h-window:2026-09-17T14:00:00Z:2026-09-17T14:41:00Z",
      "provider": "anthropic",
      "service": "agent-bar",
      "label": "5h",
      "metricType": "quota",
      "billingMode": "actual",
      "confidence": "actual",
      "limit": 100,
      "credits": 62.0,
      "occurredAt": "2026-09-17T14:41:00Z",
      "metadata": {
        "bucketId": "5h-window",
        "isExhausted": false,
        "remainingUnknown": false,
        "scale": "percent_0_100",
        "source": "agent-bar",
        "usedPercent": 38.0
      },
      "tier": "Max 20x"
    }
  ]
}
```

`generic_webhook` — a plainer envelope:

```json
{
  "format": "agent-bar-quotas",
  "version": 1,
  "generatedAt": "2026-09-17T14:41:00Z",
  "machine": "Jay's MacBook Pro",
  "count": 1,
  "windows": [
    {
      "id": "anthropic:5h",
      "provider": "anthropic",
      "label": "5h",
      "status": "available",
      "isExhausted": false,
      "remainingPercent": 62.0,
      "resetAt": "2026-09-17T17:53:00Z",
      "window": "5h",
      "plan": "Max 20x",
      "occurredAt": "2026-09-17T14:41:00Z"
    }
  ]
}
```

**Pull.**  CodeCaps reads a server's aggregated windows back (`generatedAt`, `windows[]`, optional `providerGroups[]`) as `Fleet` rows.  A window is attributed to a machine by whatever `source`/`sourceApp` it carries — no machine identifier field exists yet, so indistinguishable Macs show up as one fleet origin.

**Endpoint rules.**  HTTPS required for any host; plain HTTP only for loopback (`localhost`, `127.0.0.1`, `::1`).  A URL with embedded credentials, a query string, or a fragment is rejected.

**Token storage.**  The Ingest Token and Read Token are the only two secrets stored, both in the macOS Keychain, not a config file.

## Local Handoff File

Independent of any server, CodeCaps writes a credential-free local snapshot to:

```
~/Library/Application Support/Usage Monitor/quota-windows.json
```

for other local consumers (for example, BotFleet's Usage Monitor).  `format` is `usage-monitor-local-quotas`, `version` `1`, alongside `producer` (`"agent-bar"`), `generatedAt`, a `windows` array, and an optional `issues` map — no server URLs, account identifiers, or tokens; error strings are checked for anything credential-shaped first.  Written `0600` inside a `0700` directory, via an atomic rename.

## Install

**Homebrew**

```bash
brew install --cask jaywedgeworth22/tap/codecaps
```

**Download**

Grab the signed and notarized `CodeCaps.dmg` from the [latest release](https://github.com/jaywedgeworth22/codecaps/releases/latest).

**Build From Source**

Requirements: macOS 14+, Apple silicon or Intel, Xcode Command Line Tools with a Swift 5.9+ toolchain.

```bash
git clone https://github.com/jaywedgeworth22/codecaps.git
cd codecaps
script/build_and_run.sh            # build, install to ~/Applications, and relaunch
```

Other modes: `--install` (same, no relaunch); `--dev` (separate `.dev` identifier into `dist/`, launched beside the installed copy; `--dev-stop` quits it and removes `dist/`); `--package` (universal Release, zipped into `dist/` with a SHA-256 file); `--release` (`--package`, then notarize and staple the app, and build, sign, notarize and staple `dist/CodeCaps.dmg`); `--build-only` (stage `dist/CodeCaps.app` only).

`--package` and `--release` build one universal binary for Apple silicon and Intel, verified with `lipo -archs`.  `CFBundleShortVersionString` comes from the `VERSION` file at the repo root, so cutting a release is one edit, and `CFBundleVersion` is the commit count.  `--release` notarizes through the keychain profile named by `AGENTBAR_NOTARY_PROFILE` (default `agentbar-notary`), which you create once with `xcrun notarytool store-credentials`.

`run` and `--install` keep exactly one installed copy, at `~/Applications/CodeCaps.app`: any other bundle with the same release identifier, in the usual install locations or this checkout's `dist/`, is Trashed and printed, including a copy still named `AgentBar.app`.  `CODECAPS_PRUNE_DRY_RUN=1` previews without moving anything; `CODECAPS_BUNDLE_ID` builds under a distinct identifier, for more than one checkout.

**Signing** is still evolving — take this as current-best, not a fixed contract.  The script signs with a Developer ID Application identity when available (`AGENTBAR_CODESIGN_IDENTITY`, or the first one already in your keychains), falling back to ad-hoc (`codesign --sign -`) if none is found or signing times out.  This matters beyond Gatekeeper: a stable identity keeps saved tokens (Sources & Fleet) readable across rebuilds; ad-hoc, every build gets a new identity, so a saved token needs Re-Authorize Saved Token afterward.

**Gatekeeper.**  Without a stable identity — always true for `--dev` — macOS blocks the first launch; right-click and choose Open, or `xattr -d com.apple.quarantine`.  `--package` signs for notarization but stops there; `--release` is the mode that actually submits to Apple and staples the ticket, which is how the published dmg opens with no warning at all.

**Icon.**  The master in `assets/` is a full-bleed square, and stays that way.  macOS before 26 does not mask an app icon, so `script/make_icon.swift` derives the macOS shape at build time — the master drawn inside an 824x824 rounded rectangle on a 1024 canvas, with the standard drop shadow — and the `.icns` is built from that.  The master files are only ever read.

## Settings

Console's sidebar has five Settings pages.

- **Menu Bar** — where the icon shows (menu bar, Dock, or both), plus its Displayed Quota picker (above).
- **Platforms** — platform list order, shared by Glance, Console, and the menu bar.
- **Sources & Fleet** — three groups: **This Mac** (readers on/off, one status row per platform), **Share This Mac** (push: Ingest Endpoint, Ingest Token, Payload Format, Save & Push Now), **Pull The Fleet** (pull: Quota Endpoint, Read Token, Save & Fetch Now).  Both fleet groups also offer Forget Token and, only when a saved token can't be read back, Re-Authorize Saved Token.
- **Appearance** — Light, Dark, or System; Light is default.
- **About** — version, push/pull/local-reader status, and a project page link.

<img src="docs/screenshots/settings-sources-fleet.png" width="760" alt="Sources and Fleet">

## Privacy

- Never asks for a provider API key; each CLI's own credential file, Keychain item, or session database is reused as-is.
- Nothing leaves this Mac until you turn on push or pull and enter an endpoint yourself; fields are empty by default.
- The Ingest Token and Read Token are the only two secrets stored, both in the Keychain.
- Endpoints are validated as above (HTTPS, loopback-only HTTP, no embedded credentials/query/fragment).
- The local handoff file carries quota readings only — no tokens, endpoints, or account identifiers.

## Provider Marks

Every mark is a template image — only its silhouette is used, colored from the label.  `claude.svg`, `openai.svg`, `grok.svg`, `minimax.svg` and `gemini.svg` are BotFleet's own assets (subject to their source licenses); Antigravity reuses the Gemini mark, Grok CLI/Grok Bot the Grok mark.  `cursor.svg` is from [Simple Icons](https://cdn.simpleicons.org/cursor), CC0 1.0; details in `Sources/CodeCaps/Resources/ProviderMarks/README.md`.

## Development

```bash
swift build
swift test
```

See `AGENTBAR_BUNDLE_ID` above when building from more than one checkout at once.

## License

MIT.

## Trademarks

Provider names and marks belong to their owners and are used only to identify the services.
