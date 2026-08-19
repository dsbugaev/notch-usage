#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="build/NotchUsage.app"
IDENTITY="NotchUsage Signing"

# Stable local self-signed identity; failures degrade to ad-hoc signing
create_identity() {
  local tmpd
  tmpd=$(mktemp -d) || return 1
  /usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$tmpd/key.pem" -out "$tmpd/cert.pem" \
      -days 3650 -nodes -subj "/CN=$IDENTITY" \
      -addext "extendedKeyUsage=critical,codeSigning" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1 \
    && /usr/bin/openssl pkcs12 -export -out "$tmpd/id.p12" -inkey "$tmpd/key.pem" \
      -in "$tmpd/cert.pem" -password pass:notchusage -name "$IDENTITY" 2>/dev/null \
    && security import "$tmpd/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
      -P notchusage -T /usr/bin/codesign >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmpd"
  return $rc
}
if ! security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  create_identity || echo "warning: could not create signing identity, will sign ad-hoc"
fi

# Credential helper: built ONCE and cached outside the app bundle. The keychain
# "Always Allow" approval is tied to this exact file, so it must not be rebuilt
# on every app update — do not delete build/NotchUsage Credentials casually.
HELPER_BIN="build/NotchUsage Credentials"
mkdir -p build
if [ ! -f "$HELPER_BIN" ]; then
  swiftc -O src/credhelper.swift -o "$HELPER_BIN"
  codesign --force -s "$IDENTITY" "$HELPER_BIN" 2>/dev/null || codesign --force -s - "$HELPER_BIN"
  echo "credential helper built (first time): keychain will ask once per profile"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -parse-as-library src/main.swift -o "$APP/Contents/MacOS/NotchUsage"
# -p preserves bytes and times: the copied helper keeps its identity/approvals
cp -p "$HELPER_BIN" "$APP/Contents/MacOS/"

if ! codesign --force -s "$IDENTITY" "$APP" 2>/dev/null; then
  echo "warning: stable identity unavailable, signing ad-hoc"
  codesign --force -s - "$APP"
fi
AUTH=$(codesign -dvv "$APP" 2>&1 | grep '^Authority' | head -1 || true)
echo "OK: $APP (${AUTH:-ad-hoc})"
