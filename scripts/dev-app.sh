#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/Passst-dev.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
KEYBOARD_SHORTCUTS_CHECKOUT="$ROOT_DIR/.build/checkouts/KeyboardShortcuts"
KEYBOARD_SHORTCUTS_UTILITIES="$KEYBOARD_SHORTCUTS_CHECKOUT/Sources/KeyboardShortcuts/Utilities.swift"
KEYBOARD_SHORTCUTS_PATCH="$ROOT_DIR/scripts/keyboard-shortcuts-resource-bundle.patch"
LAUNCH=true
WATCH=true

for argument in "$@"; do
    case "$argument" in
        --once)
            WATCH=false
            ;;
        --no-launch)
            LAUNCH=false
            WATCH=false
            ;;
        *)
            echo "Usage: scripts/dev-app.sh [--once] [--no-launch]" >&2
            exit 2
            ;;
    esac
done

cd "$ROOT_DIR"
swift package resolve

# Keep dependency bundles in Contents/Resources so the app passes strict signing checks.
if grep -Fq 'bundle: .module' "$KEYBOARD_SHORTCUTS_UTILITIES"; then
    patch -s -d "$KEYBOARD_SHORTCUTS_CHECKOUT" -p1 < "$KEYBOARD_SHORTCUTS_PATCH"
elif ! grep -q 'keyboardShortcutsResources' "$KEYBOARD_SHORTCUTS_UTILITIES"; then
    echo "KeyboardShortcuts resource patch does not match the resolved source." >&2
    exit 1
fi

source_fingerprint() {
    find \
        "$ROOT_DIR/Passst" \
        "$ROOT_DIR/Package.swift" \
        "$ROOT_DIR/Package.resolved" \
        -type f \
        -exec stat -f '%m %z %N' {} + | sort | shasum
}

build_app() {
    swift build -c debug || return 1
    local bin_dir
    bin_dir="$(swift build -c debug --show-bin-path)" || return 1

    rm -rf "$APP_DIR"
    mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
    cp "$bin_dir/Passst" "$MACOS_DIR/Passst"
    cp "$ROOT_DIR/Passst/Info.plist" "$CONTENTS_DIR/Info.plist"
    cp "$ROOT_DIR/Passst/Resources/Passst.icns" "$RESOURCES_DIR/Passst.icns"
    cp "$ROOT_DIR/Passst/Resources/PassstMenuBarTemplate.png" "$RESOURCES_DIR/PassstMenuBarTemplate.png"
    cp "$ROOT_DIR/Passst/Resources/ClipboardCopy.wav" "$RESOURCES_DIR/ClipboardCopy.wav"

    for bundle in "$bin_dir"/*.bundle; do
        if [[ -d "$bundle" ]]; then
            ditto "$bundle" "$RESOURCES_DIR/${bundle:t}"
        fi
    done

    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Passst" "$CONTENTS_DIR/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.passst.mac" "$CONTENTS_DIR/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Passst" "$CONTENTS_DIR/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.2.5" "$CONTENTS_DIR/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 11" "$CONTENTS_DIR/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 14.0" "$CONTENTS_DIR/Info.plist"

    codesign \
        --force \
        --deep \
        --sign - \
        --requirements '=designated => identifier "app.passst.mac"' \
        --entitlements "$ROOT_DIR/Passst/Passst.entitlements" \
        "$APP_DIR"
    codesign --verify --deep --strict "$APP_DIR"

    if $LAUNCH; then
        pkill -f "^$MACOS_DIR/Passst$" 2>/dev/null || true
        open -n "$APP_DIR"
    fi

    echo "$APP_DIR"
}

last_fingerprint="$(source_fingerprint)"

if ! build_app; then
    if ! $WATCH; then
        exit 1
    fi
    echo "Build failed. Waiting for source changes..." >&2
fi

if ! $WATCH; then
    exit 0
fi

echo "Watching for changes. Press Ctrl-C to stop."
while sleep 1; do
    current_fingerprint="$(source_fingerprint)"
    if [[ "$current_fingerprint" != "$last_fingerprint" ]]; then
        last_fingerprint="$current_fingerprint"
        echo "Change detected. Rebuilding..."
        if ! build_app; then
            echo "Build failed. Waiting for source changes..." >&2
        fi
    fi
done
