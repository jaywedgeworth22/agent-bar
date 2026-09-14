#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR"
DIST_DIR="$PACKAGE_DIR/dist"
APP_NAME="AgentBar"
PRODUCT_NAME="AgentBar"
BUNDLE_ID="com.jays.agent-bar.mac"
MIN_SYSTEM_VERSION="14.0"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_EXECUTABLE="$APP_MACOS/$PRODUCT_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/assets/icon-512.png"
ICON_FILE="AppIcon.icns"

usage() {
  echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify|--install|--package]" >&2
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

build_and_stage() {
  swift build --package-path "$PACKAGE_DIR" --configuration debug --jobs 2
  local build_bin_dir build_binary build_resources
  build_bin_dir="$(swift build --package-path "$PACKAGE_DIR" --configuration debug --show-bin-path)"
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
  local install_dir="$HOME/Applications"
  local destination="$install_dir/$APP_NAME.app"
  local staging="$install_dir/$APP_NAME.app.installing.$$"
  local backup="$install_dir/$APP_NAME.app.previous.$$"
  mkdir -p "$install_dir"
  [[ ! -L "$install_dir" ]] || { echo "refusing symlink Applications directory: $install_dir" >&2; exit 1; }
  [[ ! -e "$staging" && ! -L "$staging" ]] || { echo "temporary install path already exists: $staging" >&2; exit 1; }
  [[ ! -e "$backup" && ! -L "$backup" ]] || { echo "temporary rollback path already exists: $backup" >&2; exit 1; }
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ ! -L "$destination" && -d "$destination" ]] || { echo "refusing symlink or non-bundle destination: $destination" >&2; exit 1; }
    local existing_id
    existing_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$destination/Contents/Info.plist" 2>/dev/null || true)"
    if [[ -n "$existing_id" && "$existing_id" != "$BUNDLE_ID" ]]; then
      echo "overwriting bundle with identifier '$existing_id': $destination"
    fi
    kill_owned_process "$destination/Contents/MacOS/$PRODUCT_NAME"
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

package_dist() {
  build_and_stage
  local zip_file="$DIST_DIR/$APP_NAME.zip"
  rm -f "$zip_file"
  (cd "$DIST_DIR" && zip -r -y "$APP_NAME.zip" "$APP_NAME.app")
  local sha
  sha="$(shasum -a 256 "$zip_file" | awk '{print $1}')"
  echo "Packaged: $zip_file"
  echo "SHA-256:  $sha"
}

case "$MODE" in
  --build-only|build-only)
    build_and_stage
    ;;
  run)
    kill_owned_app
    build_and_stage
    /usr/bin/open -n "$APP_BUNDLE"
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
  --install|install)
    build_and_stage
    install_owned_app
    ;;
  --package|package)
    package_dist
    ;;
  *)
    usage
    exit 2
    ;;
esac
