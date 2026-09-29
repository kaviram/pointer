#!/bin/bash
#
# Compile, assemble Pointer.app, sign it, and (by default) install to
# /Applications.
#
#   ./build.sh                 build, sign, install to /Applications
#   ./build.sh --no-install    build and sign into ./dist only
#   ./build.sh --debug         debug configuration
#
# Signing: prefers the self-signed "Pointer Dev" identity created by
# scripts/make-signing-cert.sh, because a stable code identity is what makes the
# Screen Recording grant survive rebuilds. Falls back to ad-hoc signing with a
# warning rather than failing the build.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Pointer"
BUNDLE_ID="com.kavi.pointer"
IDENTITY_NAME="Pointer Dev"
CONFIG="release"
INSTALL=1

for arg in "$@"; do
    case "$arg" in
        --no-install) INSTALL=0 ;;
        --debug) CONFIG="debug" ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -x "$BINARY" ]]; then
    echo "Build succeeded but $BINARY is missing." >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sanity-check the plist so a typo surfaces here rather than as a silent
# launch failure.
plutil -lint "$APP/Contents/Info.plist" > /dev/null

# Bounded wait so a first-run keychain dialog can't hang the build forever.
run_bounded() {
    local secs="$1"; shift
    "$@" >/dev/null 2>&1 &
    local pid=$!
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    local watcher=$!
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    kill "$watcher" 2>/dev/null || true
    return "$rc"
}

# An interrupted codesign leaves a *.cstemp scratch file inside the bundle.
# Left in place it becomes an unexpected sealed resource, and the *next*
# signature verifies as broken ("a sealed resource is missing or invalid") even
# though signing itself succeeded. Always clear them before signing.
clean_cstemp() {
    find "$APP" -name '*.cstemp' -delete 2>/dev/null || true
}

sign_adhoc() {
    clean_cstemp
    codesign --force --sign - "$APP"
}

echo "==> Signing"
# Deliberately not `find-identity -v`: -v lists only *trusted* identities, and a
# self-signed cert is untrusted by default yet signs perfectly well.
if security find-identity -p codesigning | grep -q "$IDENTITY_NAME"; then
    clean_cstemp
    if run_bounded 45 codesign --force --options runtime --timestamp=none \
        --sign "$IDENTITY_NAME" "$APP"
    then
        echo "    Signed with '$IDENTITY_NAME' (stable identity — the Screen"
        echo "    Recording grant will survive rebuilds)."
    else
        sign_adhoc
        cat <<'KEYWARN'
    Could not sign with 'Pointer Dev' — fell back to ad-hoc.

    This is almost always the one-time keychain dialog:

        "codesign wants to sign using key "Pointer Dev" in your keychain."

    It needs you to click **Always Allow**. If no dialog appeared, it may have
    been dismissed or timed out. Re-run ./build.sh, watch for the prompt, and
    click Always Allow — after that every build signs without asking.
KEYWARN
    fi
else
    sign_adhoc
    cat <<'WARN'
    WARNING: signed ad-hoc.

    Ad-hoc identity is derived from the binary hash, so it changes on every
    rebuild. macOS will re-prompt for Screen Recording each time, and you will
    need to delete the stale entry in
    System Settings > Privacy & Security > Screen Recording.

    Fix it once with:  ./scripts/make-signing-cert.sh
WARN
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /' || true

if [[ "$INSTALL" == "1" ]]; then
    TARGET="/Applications/$APP_NAME.app"
    echo "==> Installing to $TARGET"
    # Quit a running copy so the bundle isn't replaced underneath it.
    if pgrep -x "$APP_NAME" > /dev/null; then
        echo "    Quitting the running instance"
        osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || pkill -x "$APP_NAME" || true
        sleep 1
    fi
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
    echo
    echo "Done. Launch with:  open \"$TARGET\""
else
    echo
    echo "Done. Bundle at: $APP"
fi
