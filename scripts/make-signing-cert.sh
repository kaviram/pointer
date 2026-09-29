#!/bin/bash
#
# One-time setup: mint a self-signed code-signing identity named "Pointer Dev".
#
# Why bother: macOS ties the Screen Recording grant to the app's *code
# identity*. Ad-hoc signing (codesign -s -) derives that identity from the
# binary hash, so every rebuild re-prompts for permission AND leaves a stale
# entry you have to delete by hand in System Settings. A stable signing
# identity makes the grant persist across rebuilds.
#
# No Apple account, no paid membership, no annual expiry.
#
#   ./make-signing-cert.sh            generate + import (unattended)
#   ./make-signing-cert.sh --trust    also mark it trusted (opens a password
#                                     dialog; optional — see below)
#
# Trust is NOT required to sign. An untrusted self-signed identity signs
# perfectly well and gives the stable code identity we're after; `codesign -v`
# just notes the root isn't trusted. That step is offered only for users who
# want clean verification output, and it is behind a flag because it opens a
# GUI password dialog and will otherwise hang an unattended run.

set -euo pipefail

NAME="Pointer Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12_PASS="pointer-dev"
DO_TRUST=0

for arg in "$@"; do
    case "$arg" in
        --trust) DO_TRUST=1 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Bounded wait, so a step that wants GUI authorization can't hang the script.
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

print_next_steps() {
    cat <<'STEPS'

--------------------------------------------------------------------
One more thing, and it's a click rather than a command.

The first time codesign uses this new key, macOS shows a dialog:

    "codesign wants to sign using key "Pointer Dev" in your keychain."

Click **Always Allow** (not "Allow"). That authorizes codesign for this
key permanently, and no later build will ask again.

If you'd rather pre-authorize it now instead of on first build, run this
yourself — it needs your login password, so it has to be you typing it:

    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s -k "<your login password>" \
        ~/Library/Keychains/login.keychain-db

Then: ./build.sh
--------------------------------------------------------------------
STEPS
}

echo "==> Checking for an existing '$NAME' identity"
# Deliberately not `find-identity -v`: -v lists only *trusted* identities, and
# an untrusted-but-usable identity would look missing.
if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "    Already present:"
    security find-identity -p codesigning | grep "$NAME" | sed 's/^/    /'
    print_next_steps
    exit 0
fi

echo "==> Generating a self-signed code-signing certificate"
# extendedKeyUsage=codeSigning is what makes this usable by codesign; a plain
# self-signed TLS certificate will not work.
openssl req -x509 \
    -newkey rsa:2048 \
    -keyout "$WORK/key.pem" \
    -out "$WORK/cert.pem" \
    -days 7300 \
    -nodes \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    2>/dev/null

echo "==> Packaging as PKCS#12"
openssl pkcs12 -export \
    -inkey "$WORK/key.pem" \
    -in "$WORK/cert.pem" \
    -name "$NAME" \
    -out "$WORK/identity.p12" \
    -passout "pass:$P12_PASS" \
    2>/dev/null

echo "==> Importing into the login keychain"
# -T /usr/bin/codesign adds codesign to the key's access list.
security import "$WORK/identity.p12" \
    -k "$KEYCHAIN" \
    -f pkcs12 \
    -P "$P12_PASS" \
    -T /usr/bin/codesign

if [[ "$DO_TRUST" == "1" ]]; then
    echo "==> Marking the certificate as trusted (a password dialog will appear)"
    if run_bounded 60 security add-trusted-cert \
        -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
    then
        echo "    Trusted."
    else
        echo "    Skipped — the dialog wasn't completed within 60s."
        echo "    This does not stop you signing. To do it by hand: open"
        echo "    Keychain Access, find '$NAME', Get Info, expand Trust, set"
        echo "    Code Signing to Always Trust."
    fi
else
    echo "==> Skipping the trust step (not needed for signing; pass --trust to opt in)"
fi

echo
echo "==> Verifying the identity is usable"
if security find-identity -p codesigning | grep -q "$NAME"; then
    security find-identity -p codesigning | grep "$NAME" | sed 's/^/    /'
    echo
    echo "Identity created. CSSMERR_TP_NOT_TRUSTED here is expected and harmless"
    echo "unless you ran --trust: it affects verification output, not signing."
    print_next_steps
else
    echo "    The certificate was imported but no matching identity was found," >&2
    echo "    which usually means the private key didn't come across." >&2
    echo "    Use the Keychain Access route in README.md instead." >&2
    exit 1
fi
