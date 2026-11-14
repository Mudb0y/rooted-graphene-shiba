#!/usr/bin/env bash

# Rebuilds SandFlyDefaultOverlay.apk. Needs aapt2, apksigner and openssl on PATH.
#
# Usage: build.sh <framework-res.apk from a GrapheneOS system image> <directory with ota.key, ota.pass and ota.crt>

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <framework-res.apk> <key directory>" >&2
  exit 1
fi

framework=$(realpath "$1")
keys=$(realpath "$2")
here=$(dirname "$(realpath "$0")")
out="$here/SandFlyDefaultOverlay.apk"

work=$(mktemp -d)
# apksigner names the signer after the key file, so the name must not start with a dot
der="$keys/overlaysign.der"
trap 'rm -rf "$work" "$der"' EXIT

echo "start: building $out"

aapt2 compile --dir "$here/res" -o "$work/res.zip"
# Linking against the real framework is what makes the hidden android:isStatic attribute resolve
aapt2 link -o "$work/unsigned.apk" --manifest "$here/AndroidManifest.xml" -I "$framework" \
  --min-sdk-version 34 --target-sdk-version 37 --version-code 1 --version-name 1.0 "$work/res.zip"

(umask 077 && openssl pkcs8 -topk8 -nocrypt -inform PEM -outform DER \
  -passin "file:$keys/ota.pass" -in "$keys/ota.key" -out "$der")
apksigner sign --v1-signing-enabled false --min-sdk-version 34 \
  --key "$der" --cert "$keys/ota.crt" --out "$out" "$work/unsigned.apk"
rm -f "$out.idsig"

if ! aapt2 dump xmltree --file AndroidManifest.xml "$out" | grep -qF 'isStatic(0x0101055a)=true'; then
  echo "error: $out is not a static overlay" >&2
  exit 1
fi

echo "result: built $out"
