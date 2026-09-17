#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR"
DIST_DIR="$PACKAGE_DIR/dist"
APP_NAME="AgentBar"
PRODUCT_NAME="AgentBar"
RELEASE_BUNDLE_ID="com.jays.agent-bar.mac"
DEV_BUNDLE_ID="com.jays.agent-bar.mac.dev"
BUNDLE_ID="${AGENTBAR_BUNDLE_ID:-$RELEASE_BUNDLE_ID}"
CONFIGURATION="debug"
MIN_SYSTEM_VERSION="14.0"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_EXECUTABLE="$APP_MACOS/$PRODUCT_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/assets/icon-512.png"
ICON_FILE="AppIcon.icns"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

# Where a stray copy of the app tends to end up.  Only these are searched, so a
# bundle inside another checkout is never a candidate for pruning.
PRUNE_ROOTS=(
  "/Applications"
  "$HOME/Applications"
  "$HOME/Desktop"
  "$HOME/Downloads"
  "/Users/jay/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
  "$DIST_DIR"
)

usage() {
  cat >&2 <<'USAGE'
usage: script/build_and_run.sh [mode]

  run            (default) build, install to ~/Applications, relaunch it, then
                 delete the dist staging bundle and Trash every other copy
  --install      the same without relaunching
  --dev          build with the .dev bundle identifier into dist/ and launch it
                 beside the installed app, leaving the installed copy alone
  --dev-stop     quit only this checkout's dev process and delete dist/
  --package      build Release, zip it into dist/ with its SHA-256, and remove
                 the staged .app afterwards
  --build-only   stage dist/AgentBar.app and stop
  --debug        stage and run under lldb
  --logs         stage, launch, and stream the process log
  --telemetry    stage, launch, and stream this bundle identifier's log
  --verify       stage, launch, and confirm the process is running

  There is exactly one installed copy, at ~/Applications/AgentBar.app.  Every
  mode that installs also prunes: any other bundle whose CFBundleIdentifier is
  com.jays.agent-bar.mac, under /Applications, ~/Applications, ~/Desktop,
  ~/Downloads, iCloud Downloads or this checkout's dist/, is moved to the Trash
  and printed.  Bundles with another identifier, and bundles inside another
  checkout, are never touched.  Set AGENTBAR_PRUNE_DRY_RUN=1 to print what the
  prune would Trash without moving anything.
USAGE
}

kill_owned_process() {
  local target="$1"
  local pid command
  while read -r pid command; do
    [[ -n "${pid:-}" && "$command" == "$target" ]] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done < <(/bin/ps -axo pid=,command=)
}

kill_owned_app() {
  kill_owned_process "$APP_EXECUTABLE"
}

kill_installed_app() {
  kill_owned_process "$INSTALLED_APP/Contents/MacOS/$PRODUCT_NAME"
}

bundle_identifier() {
  /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

build_and_stage() {
  swift build --package-path "$PACKAGE_DIR" --configuration "$CONFIGURATION" --jobs 2
  local build_bin_dir build_binary build_resources
  build_bin_dir="$(swift build --package-path "$PACKAGE_DIR" --configuration "$CONFIGURATION" --show-bin-path)"
  build_binary="$build_bin_dir/$PRODUCT_NAME"
  [[ -x "$build_binary" ]] || { echo "built executable not found: $build_binary" >&2; exit 1; }

  [[ ! -L "$DIST_DIR" ]] || { echo "refusing symlink dist directory: $DIST_DIR" >&2; exit 1; }
  [[ ! -L "$APP_BUNDLE" ]] || { echo "refusing symlink app bundle: $APP_BUNDLE" >&2; exit 1; }
  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$build_binary" "$APP_EXECUTABLE"
  chmod +x "$APP_EXECUTABLE"
  build_resources="$(find "$build_bin_dir" -maxdepth 1 -type d \( -name "*_"$PRODUCT_NAME.bundle -o -name "*_"$PRODUCT_NAME.resources \) -print -quit)"
  if [[ -n "$build_resources" ]]; then
    cp -R "$build_resources" "$APP_RESOURCES/"
  fi
  if [[ -f "$ICON_SOURCE" && -x "$(command -v sips 2>/dev/null || true)" && -x "$(command -v iconutil 2>/dev/null || true)" ]]; then
    local iconset
    iconset="$(mktemp -d "${TMPDIR:-/tmp}/agentbar-icon.XXXXXX").iconset"
    mkdir -p "$iconset"
    trap 'rm -rf "$iconset"' RETURN
    sips -z 16 16 "$ICON_SOURCE" --out "$iconset/icon_16x16.png" >/dev/null
    sips -z 32 32 "$ICON_SOURCE" --out "$iconset/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$ICON_SOURCE" --out "$iconset/icon_32x32.png" >/dev/null
    sips -z 64 64 "$ICON_SOURCE" --out "$iconset/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$ICON_SOURCE" --out "$iconset/icon_128x128.png" >/dev/null
    sips -z 256 256 "$ICON_SOURCE" --out "$iconset/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$ICON_SOURCE" --out "$iconset/icon_256x256.png" >/dev/null
    sips -z 512 512 "$ICON_SOURCE" --out "$iconset/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$ICON_SOURCE" --out "$iconset/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$ICON_SOURCE" --out "$iconset/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$iconset" -o "$APP_RESOURCES/AppIcon.icns"
    rm -rf "$iconset"
    trap - RETURN
  elif [[ -f "$ICON_SOURCE" ]]; then
    cp "$ICON_SOURCE" "$APP_RESOURCES/AppIcon.png"
    ICON_FILE="AppIcon.png"
  fi

  /usr/bin/tee "$INFO_PLIST" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_FILE</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  /usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
}

install_owned_app() {
  local destination="$INSTALLED_APP"
  local staging="$INSTALL_DIR/$APP_NAME.app.installing.$$"
  local backup="$INSTALL_DIR/$APP_NAME.app.previous.$$"
  mkdir -p "$INSTALL_DIR"
  [[ ! -L "$INSTALL_DIR" ]] || { echo "refusing symlink Applications directory: $INSTALL_DIR" >&2; exit 1; }
  [[ ! -e "$staging" && ! -L "$staging" ]] || { echo "temporary install path already exists: $staging" >&2; exit 1; }
  [[ ! -e "$backup" && ! -L "$backup" ]] || { echo "temporary rollback path already exists: $backup" >&2; exit 1; }
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ ! -L "$destination" && -d "$destination" ]] || { echo "refusing symlink or non-bundle destination: $destination" >&2; exit 1; }
    local existing_id
    existing_id="$(bundle_identifier "$destination")"
    if [[ -n "$existing_id" && "$existing_id" != "$BUNDLE_ID" ]]; then
      echo "overwriting bundle with identifier '$existing_id': $destination"
    fi
    # The copy being replaced has to stop running, and it is addressed by its
    # exact executable path so no other app named AgentBar is ever signalled.
    kill_installed_app
  fi
  cp -R "$APP_BUNDLE" "$staging"
  /usr/bin/plutil -lint "$staging/Contents/Info.plist" >/dev/null
  if [[ -e "$destination" ]]; then
    mv "$destination" "$backup"
  fi
  if ! mv "$staging" "$destination"; then
    if [[ -e "$backup" ]]; then mv "$backup" "$destination"; fi
    rm -rf "$staging"
    exit 1
  fi
  rm -rf "$backup"
  echo "installed $destination"
}

# Moves a bundle to the Trash rather than deleting it, so a mistake is
# recoverable.  `rm -rf` on an app bundle is not.
trash_path() {
  local path="$1"
  if [[ "${AGENTBAR_PRUNE_DRY_RUN:-0}" == "1" ]]; then
    echo "would trash $path"
    return 0
  fi
  if /usr/bin/osascript -e "tell application \"Finder\" to delete POSIX file \"$path\"" >/dev/null 2>&1; then
    echo "trashed $path"
  else
    echo "could not Trash (left in place): $path" >&2
  fi
}

# Exactly one installed copy.  Anything else carrying this app's release bundle
# identifier, in one of the usual places, goes to the Trash — and nothing else
# does: a different identifier is skipped, and no other checkout is searched.
prune_other_copies() {
  local keep="$1"
  local root candidate identifier
  for root in "${PRUNE_ROOTS[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      [[ "$candidate" != "$keep" ]] || continue
      identifier="$(bundle_identifier "$candidate")"
      [[ "$identifier" == "$RELEASE_BUNDLE_ID" ]] || continue
      kill_owned_process "$candidate/Contents/MacOS/$PRODUCT_NAME"
      trash_path "$candidate"
    done < <(find "$root" -maxdepth 3 -name "$APP_NAME.app" -type d 2>/dev/null)
  done
}

package_dist() {
  CONFIGURATION="release"
  build_and_stage
  local zip_file="$DIST_DIR/$APP_NAME.zip"
  rm -f "$zip_file"
  (cd "$DIST_DIR" && zip -q -r -y "$APP_NAME.zip" "$APP_NAME.app")
  local sha
  sha="$(shasum -a 256 "$zip_file" | awk '{print $1}')"
  echo "$sha  $APP_NAME.zip" > "$DIST_DIR/$APP_NAME.zip.sha256"
  # The zip is the artifact; leaving the staged bundle behind is how a second
  # copy of the app ends up on disk in the first place.
  rm -rf "$APP_BUNDLE"
  echo "Packaged: $zip_file"
  echo "SHA-256:  $sha"
}

case "$MODE" in
  --build-only|build-only)
    build_and_stage
    ;;
  run)
    build_and_stage
    install_owned_app
    /usr/bin/open -n "$INSTALLED_APP"
    rm -rf "$APP_BUNDLE"
    prune_other_copies "$INSTALLED_APP"
    ;;
  --install|install)
    build_and_stage
    install_owned_app
    rm -rf "$APP_BUNDLE"
    prune_other_copies "$INSTALLED_APP"
    ;;
  --dev|dev)
    BUNDLE_ID="$DEV_BUNDLE_ID"
    kill_owned_app
    build_and_stage
    # Launched from dist/, beside the installed copy, which is left running.
    /usr/bin/open -n "$APP_BUNDLE"
    echo "dev instance running from $APP_BUNDLE"
    ;;
  --dev-stop|dev-stop)
    kill_owned_app
    rm -rf "$DIST_DIR"
    echo "dev instance stopped and $DIST_DIR removed"
    ;;
  --package|package)
    package_dist
    ;;
  --debug|debug)
    kill_owned_app
    build_and_stage
    lldb -- "$APP_EXECUTABLE"
    ;;
  --logs|logs)
    kill_owned_app
    build_and_stage
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$PRODUCT_NAME\""
    ;;
  --telemetry|telemetry)
    kill_owned_app
    build_and_stage
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    kill_owned_app
    build_and_stage
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    /usr/bin/pgrep -f -x "$APP_EXECUTABLE" >/dev/null
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
