#!/usr/bin/env bash

# Requires git, jq, and curl

KEY_AVB=${KEY_AVB:-avb.key}
KEY_OTA=${KEY_OTA:-ota.key}
CERT_OTA=${CERT_OTA:-ota.crt}
# Or else, set these env vars
KEY_AVB_BASE64=${KEY_AVB_BASE64:-''}
KEY_OTA_BASE64=${KEY_OTA_BASE64:-''}
CERT_OTA_BASE64=${CERT_OTA_BASE64:-''}

# Set these env vars, or else these params will be queries interactively
# PASSPHRASE_AVB
# PASSPHRASE_OTA

# Enable debug output only after sensitive vars have been set, to reduce risk of leak
DEBUG=${DEBUG:-''}
if [[ -n "${DEBUG}" ]]; then set -x; fi

# Mandatory params
DEVICE_ID=${DEVICE_ID:-} # See here for device IDs https://grapheneos.org/releases
GITHUB_TOKEN=${GITHUB_TOKEN:-''}
GITHUB_REPO=${GITHUB_REPO:-''}

# Optional
# If you want an OTA patched with magisk, set the preinit for your device
MAGISK_PREINIT_DEVICE=${MAGISK_PREINIT_DEVICE:-}
# Skip creation of rootless OTA by setting to "true"
SKIP_ROOTLESS=${SKIP_ROOTLESS:-'false'}
# Skip creation of magisk OTA by setting to "true".
SKIP_MAGISK=${SKIP_MAGISK:-'false'}
# In addition to upstream magisk, an OTA can be patched with pixincreate's magisk fork,
# which contains patches that make zygisk work on GrapheneOS.
# https://github.com/pixincreate/Magisk
# Note that modules verifying magisk's signature won't work with this fork.
# Enable by setting to "false".
SKIP_PIXINCREATE=${SKIP_PIXINCREATE:-'true'}
# https://grapheneos.org/releases#stable-channel
OTA_VERSION=${OTA_VERSION:-'latest'}

# Magisk and pixincreate's fork follow their newest release that is not marked as a pre-release, so every build
# patches with whatever is current when a GrapheneOS release comes out. Naming a tag here, e.g. v31.1, holds one
# back. A new Magisk can need a new avbroot, which is why avbroot follows its releases as well.
MAGISK_VERSION=${MAGISK_VERSION:-latest}
# The fork's tags don't always match upstream magisk's, e.g. v31.0-3
PIXINCREATE_VERSION=${PIXINCREATE_VERSION:-latest}

# Magisk ends up in the boot chain with root, and nothing but the APK's own signature says who a release is from.
# An APK is only used if it is signed with the certificate every release so far was signed with: John Wu's for
# Magisk, pixincreate's for the fork.
MAGISK_SIGNER=b4cb83b4dad99f997dbe872f013aa16c14eec41d167021f371f7e1330f273ee6
PIXINCREATE_SIGNER=0c523d37aca12a8086583c2d38231925642d9ed35f657a2914c52e014d1d0a18

SKIP_CLEANUP=${SKIP_CLEANUP:-''}

# For committing to GH pages in different repo, clone it to a different folder and set this var
PAGES_REPO_FOLDER=${PAGES_REPO_FOLDER:-''}

# Set asset released by this script to latest version, even when OTA_VERSION already exists for this device
FORCE_OTA_SERVER_UPLOAD=${FORCE_OTA_SERVER_UPLOAD:-'false'}
# Forces the artifacts to be built (and uploaded to a release)
# even it a release already contains the combination of device and flavor.
# This will lead to multiple artifacts with different commits on the release (that are not linked in the OTA server and thus are likely never used).
# However, except for test builds, we want the changes to be rolled out with new version.
# So these artifacts are just a waste of storage resources. Example
# shiba-2025020500-3e0add9-rootless.zip
# shiba-2025020500-6718632-rootless.zip
FORCE_BUILD=${FORCE_BUILD:-'false'}
# Skip setting asset released by this script to latest version, even when OTA_VERSION is latest for this device
# Takes precedence over FORCE_OTA_SERVER_UPLOAD
SKIP_OTA_SERVER_UPLOAD=${SKIP_OTA_SERVER_UPLOAD:-'false'}
# Skip patching modules (custota and oemunlockunboot) into OTA
SKIP_MODULES=${SKIP_MODULES:-'false'}
# Upload OTA to test folder on OTA server
UPLOAD_TEST_OTA=${UPLOAD_TEST_OTA:-false}
# Skip adding the apps listed in preinstall/apps.conf, the overlays in preinstall/overlay and the Magisk app to the OTA
SKIP_PREINSTALL=${SKIP_PREINSTALL:-'false'}
# Run the patch step with the host's python3 instead of in docker. Needs pydantic and tomlkit.
PATCH_NATIVE=${PATCH_NATIVE:-'false'}

OTA_CHANNEL=${OTA_CHANNEL:-stable-security-preview} # Alternative: 'stable' or 'alpha'
NO_COLOR=${NO_COLOR:-''}
OTA_BASE_URL="https://releases.grapheneos.org"

# chenxiaolong's tools follow their newest release too. Naming a version without its leading v, e.g. 3.39.1,
# holds one back. Whatever the version, nothing of his is used unless it is signed with CHENXIAOLONG_PK.
AVB_ROOT_VERSION=${AVB_ROOT_VERSION:-latest}
CUSTOTA_VERSION=${CUSTOTA_VERSION:-latest}
OEMUNLOCKONBOOT_VERSION=${OEMUNLOCKONBOOT_VERSION:-latest}
AFSR_VERSION=${AFSR_VERSION:-latest}
# my-avbroot-setup has no releases, so "latest" is the newest commit on its main branch that he signed. A commit
# named here is taken as it is.
PATCH_PY_COMMIT=${PATCH_PY_COMMIT:-latest}
# The Python image stays pinned. It never reaches the phone, the pinned one keeps working, and my-avbroot-setup
# locks its dependencies to the Python versions that existed when it was last updated.
# renovate: datasource=docker packageName=python
PYTHON_VERSION=3.15.2-alpine
# The patch step runs in this image with the signing keys mounted, and a tag can be pointed at another image
PYTHON_DIGEST=sha256:0f9552bb28711333da16915ec146f5e6bb44a7fdac9ced15dc17c2e0206346dd

CHENXIAOLONG_PK='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDOe6/tBnO7xZhAWXRj3ApUYgn+XZ0wnQiXM8B7tPgv4'
GIT_PUSH_RETRIES=10
# GitHub refuses release assets of 2 GiB or more
MAX_ASSET_BYTES=$((2 * 1024 * 1024 * 1024 - 1))

PREINSTALL_ARGS=()

set -o nounset -o pipefail -o errexit

declare -A POTENTIAL_ASSETS

function generateKeys() {
  downloadAvBroot
  # https://github.com/chenxiaolong/avbroot/tree/077a80f4ce7233b0e93d4a1477d09334af0da246#generating-keys
  # Generate the AVB and OTA signing keys.
  .tmp/avbroot key generate-key -o $KEY_AVB
  .tmp/avbroot key generate-key -o $KEY_OTA

  # Convert the public key portion of the AVB signing key to the AVB public key metadata format.
  # This is the format that the bootloader requires when setting the custom root of trust.
  .tmp/avbroot key extract-avb -k $KEY_AVB -o avb_pkmd.bin

  # Generate a self-signed certificate for the OTA signing key. This is used by recovery to verify OTA updates when sideloading.
  .tmp/avbroot key generate-cert -k $KEY_OTA -o $CERT_OTA

  echo Upload these to your CI server, if necessary.
  echo The script takes these values as env or file
  key2base64
}

function key2base64() {
  KEY_AVB_BASE64=$(base64 -w0 "$KEY_AVB") && echo "KEY_AVB_BASE64=$KEY_AVB_BASE64"
  KEY_OTA_BASE64=$(base64 -w0 "$KEY_OTA") && echo "KEY_OTA_BASE64=$KEY_OTA_BASE64"
  CERT_OTA_BASE64=$(base64 -w0 "$CERT_OTA") && echo "CERT_OTA_BASE64=$CERT_OTA_BASE64"
  export KEY_AVB_BASE64 KEY_OTA_BASE64 CERT_OTA_BASE64
}

function createAndReleaseRootedOta() {
  createRootedOta
  releaseOta

  createOtaServerData
  uploadOtaServerData
}

function createRootedOta() {
  [[ "$SKIP_CLEANUP" != 'true' ]] && trap cleanup EXIT ERR

  findLatestVersion
  checkBuildNecessary
  downloadAndroidDependencies
  verifyGrapheneOta
  patchOTAs
}

function cleanup() {
  print "Cleaning up..."
  rm -rf .tmp
  unset KEY_AVB_BASE64 KEY_OTA_BASE64 CERT_OTA_BASE64
  print "Cleanup complete."
}

function checkBuildNecessary() {
  local currentCommit
  currentCommit=$(git rev-parse --short HEAD)
  POTENTIAL_ASSETS=()
    
  if [[ -n "$MAGISK_PREINIT_DEVICE" ]]; then
    if [[ "$SKIP_MAGISK" != 'true' ]]; then
      # e.g. oriole-2023121200-magisk-v26.4-4647f74-dirty.zip
      POTENTIAL_ASSETS['magisk']="${DEVICE_ID}-${OTA_VERSION}-${currentCommit}-magisk-${MAGISK_VERSION}$(createAssetSuffix).zip"
    else
      printGreen "SKIP_MAGISK set, not creating upstream magisk OTA"
    fi

    if [[ "$SKIP_PIXINCREATE" != 'true' ]]; then
      # e.g. oriole-2023121200-pixincreate-v31.0-3-4647f74-dirty.zip
      POTENTIAL_ASSETS['pixincreate']="${DEVICE_ID}-${OTA_VERSION}-${currentCommit}-pixincreate-${PIXINCREATE_VERSION}$(createAssetSuffix).zip"
    else
      printGreen "SKIP_PIXINCREATE set, not creating pixincreate OTA"
    fi
  else 
    printGreen "MAGISK_PREINIT_DEVICE not set for device, not creating magisk OTA"
  fi
  
  if [[ "$SKIP_ROOTLESS" != 'true' ]]; then
    POTENTIAL_ASSETS['rootless']="${DEVICE_ID}-${OTA_VERSION}-${currentCommit}-rootless$(createAssetSuffix).zip"
  else
    printGreen "SKIP_ROOTLESS set, not creating rootless OTA"
  fi

  RELEASE_ID=''
  local response

  if [[ -z "$GITHUB_REPO" ]]; then print "Env Var GITHUB_REPO not set, skipping check for existing release" && return; fi

  print "Potential release: ${OTA_VERSION}"

  local params=()
  local url="https://api.github.com/repos/${GITHUB_REPO}/releases"

  if [ -n "${GITHUB_TOKEN}" ]; then
    params+=("-H" "Authorization: token ${GITHUB_TOKEN}")
  fi

  params+=("-H" "Accept: application/vnd.github.v3+json")
  response=$(
    curl --fail -sL "${params[@]}" "${url}" |
      jq --arg release_tag "${OTA_VERSION}" '.[] | select(.tag_name == $release_tag) | {id, tag_name, name, published_at, assets}'
  )

  if [[ -n ${response} ]]; then
    RELEASE_ID=$(echo "${response}" | jq -r '.id')
    print "Release ${OTA_VERSION} exists. ID=$RELEASE_ID"
    
    for flavor in "${!POTENTIAL_ASSETS[@]}"; do
      local selectedAsset POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
      print "Checking if asset exists ${POTENTIAL_ASSET_NAME}"
      
      # Save some storage by not building and uploading every new commit as asset
      selectedAsset=$(echo "${response}" | jq -r --arg assetPrefix "${DEVICE_ID}-${OTA_VERSION}" \
        '.assets[] | select(.name | startswith($assetPrefix)) | .name' \
          | grep "${flavor}" || true)
  
      if [[ -n "${selectedAsset}" ]] && [[ "$FORCE_BUILD" != 'true' ]] && [[ "$UPLOAD_TEST_OTA" != 'true' ]]; then
        printGreen "Skipping build of asset name '$POTENTIAL_ASSET_NAME'. Because this flavor already is released with a different commit." \
          "Set FORCE_BUILD or UPLOAD_TEST_OTA to force. Assets found on release: ${selectedAsset//$'\n'/ }"
        unset "POTENTIAL_ASSETS[$flavor]"
      else
        print "No asset found with name '$POTENTIAL_ASSET_NAME'."
      fi
    done
    
    if [ "${#POTENTIAL_ASSETS[@]}" -eq 0 ]; then
      printGreen "All potential assets already exist. Exiting"
      exit 0
    fi
  else
    print "Release ${OTA_VERSION} does not exist."
  fi
}

function checkMandatoryVariable() {
  for var_name in "$@"; do
    local var_value="${!var_name}"

    if [[ -z "$var_value" ]]; then
      printRed "Missing mandatory param $var_name"
      exit 1
    fi
  done
}

function createAssetSuffix() {
  local suffix=''
  if [[ "${SKIP_MODULES}" == 'true' ]]; then
    suffix+='-minimal'
  fi 
  if [[ "${UPLOAD_TEST_OTA}" == 'true' ]]; then
    suffix+='-test'
  fi
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    suffix+='-dirty'
  fi
  echo "$suffix"
}

function downloadAndroidDependencies() {
  checkMandatoryVariable 'MAGISK_VERSION' 'OTA_TARGET'

  mkdir -p .tmp
  if [[ "${POTENTIAL_ASSETS['magisk']+isset}" ]]; then
    downloadMagisk topjohnwu/Magisk "$MAGISK_VERSION" ".tmp/magisk-$MAGISK_VERSION.apk" "$MAGISK_SIGNER"
  fi

  if [[ "${POTENTIAL_ASSETS['pixincreate']+isset}" ]]; then
    downloadMagisk pixincreate/Magisk "$PIXINCREATE_VERSION" ".tmp/pixincreate-$PIXINCREATE_VERSION.apk" \
      "$PIXINCREATE_SIGNER"
  fi

  if ! ls ".tmp/$OTA_TARGET.zip" >/dev/null 2>&1; then
    curl --fail -sLo ".tmp/$OTA_TARGET.zip" "$OTA_URL"
  fi
}

# Magisk and the fork both release their APK as "Magisk-<tag>.apk"
function downloadMagisk() {
  local repo="$1" version="$2" file="$3" signer="$4" actual
  local url="https://github.com/$repo/releases/download/$version/Magisk-$version.apk"

  if ! command -v apksigner >/dev/null; then
    printRed "apksigner is needed to check who signed Magisk"
    exit 1
  fi

  if [[ ! -f "$file" ]]; then
    if ! curl --fail -sLo "$file.part" "$url"; then
      printRed "Cannot download $url"
      exit 1
    fi
    mv "$file.part" "$file"
  fi

  actual=$(apkCertDigest "$file")
  if [[ "$actual" != "$signer" ]]; then
    printRed "$file is signed by '${actual}', expected $signer. Not using it."
    rm -f "$file"
    exit 1
  fi
  print "Magisk $version from $repo is signed by its maintainer"
}

# Replaces "latest" in the named variable with the tag of the repo's newest release, without the prefix given
# as third argument. GitHub leaves drafts and pre-releases out of "latest". Anything else in the variable is a
# version somebody named, and stays.
function resolveLatest() {
  local -n resolved="$1"
  local repo="$2" prefix="${3:-}" url

  if [[ "$resolved" != 'latest' ]]; then
    return
  fi

  url=$(curl --fail -sL -I -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")
  if [[ "$url" != */releases/tag/?* ]]; then
    printRed "Cannot tell the latest release of $repo from $url"
    exit 1
  fi
  resolved=${url##*/releases/tag/}
  resolved=${resolved#"$prefix"}
  print "Latest release of $repo: $resolved"
}

# The OTA arrives over plain HTTPS and leaves here signed with our keys, so nothing downstream would notice a
# tampered one. grapheneos/<device> holds GrapheneOS's verified boot key from their signed factory image, whose
# SHA-256 is the key hash listed on https://grapheneos.org/install/web, and the certificate their OTAs are signed
# with. avbroot also checks that this certificate is the one the recovery inside the OTA trusts.
function verifyGrapheneOta() {
  local keys="grapheneos/$DEVICE_ID"

  if [[ ! -f "$keys/avb_pkmd.bin" || ! -f "$keys/ota.crt" ]]; then
    printRed "$keys does not hold GrapheneOS's keys for $DEVICE_ID, so the OTA cannot be verified."
    exit 1
  fi

  downloadAvBroot

  if ! .tmp/avbroot ota verify --input ".tmp/$OTA_TARGET.zip" \
    --public-key-avb "$keys/avb_pkmd.bin" --cert-ota "$keys/ota.crt"; then
    printRed ".tmp/$OTA_TARGET.zip is not signed with GrapheneOS's keys. Not patching it."
    rm -f ".tmp/$OTA_TARGET.zip"
    exit 1
  fi
  printGreen "$OTA_TARGET is signed with GrapheneOS's keys"
}

function findLatestVersion() {
  checkMandatoryVariable DEVICE_ID

  resolveLatest MAGISK_VERSION topjohnwu/Magisk
  print "Magisk version: $MAGISK_VERSION"
  if [[ "$SKIP_PIXINCREATE" != 'true' ]]; then
    resolveLatest PIXINCREATE_VERSION pixincreate/Magisk
    print "pixincreate version: $PIXINCREATE_VERSION"
  fi

  # Search for a new version grapheneos.
  # e.g. https://releases.grapheneos.org/shiba-stable

  if [[ "$OTA_VERSION" == 'latest' ]]; then
    OTA_VERSION=$(curl --fail -sL "$OTA_BASE_URL/$DEVICE_ID-$OTA_CHANNEL" | head -n1 | awk '{print $1;}')
  fi
  GRAPHENE_TYPE=${GRAPHENE_TYPE:-'ota_update'} # Other option: factory
  OTA_TARGET="$DEVICE_ID-$GRAPHENE_TYPE-$OTA_VERSION"
  OTA_URL="$OTA_BASE_URL/$OTA_TARGET.zip"
  # e.g.  shiba-ota_update-2023121200
  print "OTA target: $OTA_TARGET; OTA URL: $OTA_URL"
}

function downloadAvBroot() {
  resolveLatest AVB_ROOT_VERSION chenxiaolong/avbroot v
  downloadAndVerifyFromChenxiaolong 'avbroot' "$AVB_ROOT_VERSION"
}

function downloadAndVerifyFromChenxiaolong() {
  local repo="$1"
  local version="$2"
  local artifact="${3:-$1}" # optional: If not set, use repo name
  
  local url="https://github.com/chenxiaolong/${repo}/releases/download/v${version}/${artifact}-${version}-x86_64-unknown-linux-gnu.zip"
  local downloadedZipFile
  downloadedZipFile="$(mktemp)"
  
  mkdir -p .tmp

  if ! ls ".tmp/${artifact}" >/dev/null 2>&1; then
    curl --fail -sL "${url}" > "${downloadedZipFile}"
    curl --fail -sL "${url}.sig" > "${downloadedZipFile}.sig"
    
    # Validate against author's public key
    ssh-keygen -Y verify -I chenxiaolong -f <(echo "chenxiaolong $CHENXIAOLONG_PK") -n file \
      -s "${downloadedZipFile}.sig" < "${downloadedZipFile}"
    
    echo N | unzip "${downloadedZipFile}" -d .tmp
    rm "${downloadedZipFile}"*
    chmod +x ".tmp/${artifact}" # e.g. .tmp/custota-tool
  fi
}

# Puts .tmp/my-avbroot-setup on the commit to patch with. The patch script runs with the signing keys in reach,
# and a branch can be moved by whoever gets into the GitHub account, so "latest" goes no further than the newest
# commit that carries the author's own signature. That signature covers everything the commit is built on.
function checkoutPatchScript() {
  local repo=.tmp/my-avbroot-setup signers=.tmp/chenxiaolong.signers commit='' candidate

  if [[ "$PATCH_PY_COMMIT" != 'latest' ]]; then
    git -C "$repo" checkout --quiet "$PATCH_PY_COMMIT"
    return
  fi

  echo "chenxiaolong $CHENXIAOLONG_PK" >"$signers"
  for candidate in $(git -C "$repo" rev-list -n 50 HEAD); do
    if git -C "$repo" -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$PWD/$signers" \
      verify-commit "$candidate" >/dev/null 2>&1; then
      commit=$candidate
      break
    fi
  done
  if [[ -z "$commit" ]]; then
    printRed "None of the last 50 commits of my-avbroot-setup is signed by its author. Not using it."
    exit 1
  fi
  git -C "$repo" checkout --quiet "$commit"
  print "Patch script: my-avbroot-setup at $commit"
}

function githubApi() {
  local params=("-H" "Accept: application/vnd.github+json")

  if [[ -n "${GITHUB_TOKEN}" ]]; then
    params+=("-H" "Authorization: token ${GITHUB_TOKEN}")
  fi

  curl --fail -sL "${params[@]}" "https://api.github.com/$1"
}

# Prints the SHA-256 of the certificate an APK is signed with. Prints nothing if the APK does not verify,
# or is signed by more than one certificate.
function apkCertDigest() {
  local output digests

  # apksigner's exit code is not reliable across versions, so only its output is trusted
  output=$(apksigner verify --verbose --print-certs "$1" 2>/dev/null </dev/null || true)
  if ! grep -qx 'Verifies' <<<"$output"; then
    return
  fi

  digests=$(sed -n 's/.*certificate SHA-256 digest: \([0-9a-f]\{64\}\)$/\1/p' <<<"$output" | sort -u)
  if [[ -n "$digests" && "$(wc -l <<<"$digests")" -eq 1 ]]; then
    echo "$digests"
  fi
}

# Downloads the latest stable release of every app in preinstall/apps.conf. Versions float, the signer does not:
# an APK only goes into the OTA if it is signed with the certificate pinned in apps.conf.
function downloadPreinstallApps() {
  PREINSTALL_ARGS=()

  if [[ "$SKIP_PREINSTALL" == 'true' ]]; then
    printGreen "SKIP_PREINSTALL set, not adding apps or overlays to the OTA"
    return
  fi

  if ! command -v apksigner >/dev/null; then
    printRed "apksigner is needed to verify the apps in preinstall/apps.conf"
    exit 1
  fi

  mkdir -p .tmp/preinstall

  local name repo pattern cert release tag url file actual overlay
  while read -r name repo pattern cert <&3; do
    if [[ -z "$name" || "$name" == \#* ]]; then
      continue
    fi

    release=$(githubApi "repos/$repo/releases/latest")
    tag=$(jq -r '.tag_name' <<<"$release")
    url=$(jq -r --arg pattern "$pattern" \
      '[.assets[] | select(.name | test($pattern))] | if length == 1 then .[0].browser_download_url else empty end' <<<"$release")
    if [[ -z "$url" ]]; then
      printRed "Release $tag of $repo does not have exactly one asset matching $pattern"
      exit 1
    fi

    file=".tmp/preinstall/$name-$tag.apk"
    if [[ ! -f "$file" ]]; then
      curl --fail -sLo "$file.part" "$url"
      mv "$file.part" "$file"
    fi

    actual=$(apkCertDigest "$file")
    if [[ "$actual" != "$cert" ]]; then
      printRed "$name $tag is signed by '${actual}', expected $cert. Not adding it to the OTA."
      exit 1
    fi

    print "Preinstalling $name $tag from $repo"
    PREINSTALL_ARGS+=("--preinstall-app" "$name=$file")
  done 3<preinstall/apps.conf

  for overlay in preinstall/overlay/*.apk; do
    print "Preinstalling overlay $overlay"
    PREINSTALL_ARGS+=("--preinstall-overlay" "$overlay")
  done
}

function patchOTAs() {

  downloadAvBroot
  resolveLatest AFSR_VERSION chenxiaolong/afsr v
  downloadAndVerifyFromChenxiaolong 'afsr' "$AFSR_VERSION"
  # The patch script checks both of these zips against their .sig before it uses them
  resolveLatest CUSTOTA_VERSION chenxiaolong/Custota v
  if ! ls ".tmp/custota.zip" >/dev/null 2>&1; then
    curl --fail -sL "https://github.com/chenxiaolong/Custota/releases/download/v${CUSTOTA_VERSION}/Custota-${CUSTOTA_VERSION}-release.zip" > .tmp/custota.zip
    curl --fail -sL "https://github.com/chenxiaolong/Custota/releases/download/v${CUSTOTA_VERSION}/Custota-${CUSTOTA_VERSION}-release.zip.sig" > .tmp/custota.zip.sig
  fi
  resolveLatest OEMUNLOCKONBOOT_VERSION chenxiaolong/OEMUnlockOnBoot v
  if ! ls ".tmp/oemunlockonboot.zip" >/dev/null 2>&1; then
    curl --fail -sL "https://github.com/chenxiaolong/OEMUnlockOnBoot/releases/download/v${OEMUNLOCKONBOOT_VERSION}/OEMUnlockOnBoot-${OEMUNLOCKONBOOT_VERSION}-release.zip" > .tmp/oemunlockonboot.zip
    curl --fail -sL "https://github.com/chenxiaolong/OEMUnlockOnBoot/releases/download/v${OEMUNLOCKONBOOT_VERSION}/OEMUnlockOnBoot-${OEMUNLOCKONBOOT_VERSION}-release.zip.sig" > .tmp/oemunlockonboot.zip.sig
  fi
  if ! ls ".tmp/my-avbroot-setup" >/dev/null 2>&1; then
    git clone https://github.com/chenxiaolong/my-avbroot-setup .tmp/my-avbroot-setup
    checkoutPatchScript
  fi

  downloadPreinstallApps

  base642key

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local targetFile=".tmp/${POTENTIAL_ASSETS[$flavor]}"

    if ls "$targetFile" >/dev/null 2>&1; then
      printGreen "File $targetFile already exists locally, not patching."
    else
      local args=()

      args+=("--output" "$targetFile")
      args+=("--input" ".tmp/$OTA_TARGET.zip")
      args+=("--sign-key-avb" "$KEY_AVB")
      args+=("--sign-key-ota" "$KEY_OTA")
      args+=("--sign-cert-ota" "$CERT_OTA")
      local magiskApk=''
      if [[ "$flavor" == 'magisk' ]]; then
        magiskApk=".tmp/magisk-$MAGISK_VERSION.apk"
      fi
      if [[ "$flavor" == 'pixincreate' ]]; then
        magiskApk=".tmp/pixincreate-$PIXINCREATE_VERSION.apk"
      fi
      if [[ -n "$magiskApk" ]]; then
        args+=("--patch-arg=--magisk" "--patch-arg" "$magiskApk")
        args+=("--patch-arg=--magisk-preinit-device" "--patch-arg" "$MAGISK_PREINIT_DEVICE")
        # The same file the boot image is patched with, so the app on the phone always matches the Magisk underneath
        if [[ "$SKIP_PREINSTALL" != 'true' ]]; then
          args+=("--preinstall-magisk-app" "$magiskApk")
        fi
      fi

      # If env vars not set, passphrases will be queried interactively
      if [ -v PASSPHRASE_AVB ]; then
        args+=("--pass-avb-env-var" "PASSPHRASE_AVB")
      fi

      if [ -v PASSPHRASE_OTA ]; then
        args+=("--pass-ota-env-var" "PASSPHRASE_OTA")
      fi

      if [[ "${SKIP_MODULES}" != 'true' ]]; then
        args+=("--module-custota" ".tmp/custota.zip")
        args+=("--module-oemunlockonboot" ".tmp/oemunlockonboot.zip")
      fi
      # We create csig and device JSON for OTA later if necessary
      args+=("--skip-custota-tool")
      args+=("${PREINSTALL_ARGS[@]}")

      if [[ "$PATCH_NATIVE" == 'true' ]]; then
        PATH="$PWD/.tmp:$PATH" python3 preinstall/run_patch.py "${args[@]}"
      else
        # We need to add .tmp to PATH, but we can't use $PATH: because this would be the PATH of the host not the container
        # Python image is designed to run as root, so chown the files it creates back at the end
        # ... room for improvement 😐️
        # shellcheck disable=SC2046
        docker run --rm -i $(tty &>/dev/null && echo '-t') \
      -v "$PWD:/app" \
      -w /app \
      -e PATH='/bin:/usr/local/bin:/sbin:/usr/bin:/app/.tmp' \
      --env-file <(env) \
      "python:${PYTHON_VERSION}@${PYTHON_DIGEST}" sh -c "set -e && \
          apk add --no-cache openssh uv && \
          uv sync --locked --project .tmp/my-avbroot-setup && \
          uv run --project .tmp/my-avbroot-setup \
              preinstall/run_patch.py ${args[*]} && \
          chown -R $(id -u):$(id -g) .tmp"
      fi

      local size
      size=$(stat -c %s "$targetFile")
      if ((size > MAX_ASSET_BYTES)); then
        printRed "$targetFile is $size bytes. GitHub only takes release assets below 2 GiB."
        exit 1
      fi

      printGreen "Finished patching file ${targetFile} ($size bytes)"
    fi
    
  done
}

function base642key() {
  set +x # Don't expose secrets to log
  if [ -n "$KEY_AVB_BASE64" ]; then
    echo "$KEY_AVB_BASE64" | base64 -d >.tmp/$KEY_AVB
    KEY_AVB=.tmp/$KEY_AVB
  fi

  if [ -n "$KEY_OTA_BASE64" ]; then
    echo "$KEY_OTA_BASE64" | base64 -d >.tmp/$KEY_OTA
    KEY_OTA=.tmp/$KEY_OTA
  fi

  if [ -n "$CERT_OTA_BASE64" ]; then
    echo "$CERT_OTA_BASE64" | base64 -d >.tmp/$CERT_OTA
    CERT_OTA=.tmp/$CERT_OTA
  fi

  if [[ -n "${DEBUG}" ]]; then set -x; fi
}

function releaseOta() {

  createReleaseIfNecessary
  
  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local assetName="${POTENTIAL_ASSETS[$flavor]}"
    uploadFile ".tmp/$assetName" "$assetName" "application/zip"
  done
}

function createReleaseIfNecessary() {
  checkMandatoryVariable 'GITHUB_REPO' 'GITHUB_TOKEN'

  local response changelog src_repo current_commit 

  if [[ -z "$RELEASE_ID" ]]; then
    src_repo=$(extractGithubRepo "$(git config --get remote.origin.url)")

    # Security-preview releases end in suffix 01,but anchor links on release page always end in 00
    # e.g. 25092501 -> 25092500
    OTA_VERSION_ANCHOR="${OTA_VERSION/%01/00}"
    if [[ "${GITHUB_REPO}" == "${src_repo}" ]]; then
      changelog=$(curl -sL -X POST -H "Authorization: token $GITHUB_TOKEN" \
        -d "{
                \"tag_name\": \"$OTA_VERSION\",
                \"target_commitish\": \"main\"
              }" \
        "https://api.github.com/repos/$GITHUB_REPO/releases/generate-notes" | jq -r '.body // empty')
      # Replace \n by \\n to keep them as chars
      changelog="Update to [GrapheneOS ${OTA_VERSION}](https://grapheneos.org/releases#${OTA_VERSION_ANCHOR}).\n\n$(echo "${changelog}" | sed ':a;N;$!ba;s/\n/\\n/g')"
    else 
      # When pushing to different repo's GH pages, generating notes does not make too much sense. Refer to the used repo's "version" instead. 
      current_commit=$(git rev-parse --short HEAD)
      changelog="Update to [GrapheneOS ${OTA_VERSION}](https://grapheneos.org/releases#${OTA_VERSION_ANCHOR}).\n\nRelease created using ${src_repo}@${current_commit}. See [Changelog](https://github.com/${src_repo}/blob/${current_commit}/README.md#notable-changelog)."
    fi
    
    response=$(curl -sL -X POST -H "Authorization: token $GITHUB_TOKEN" \
      -d "{
              \"tag_name\": \"$OTA_VERSION\",
              \"target_commitish\": \"main\",
              \"name\": \"$OTA_VERSION\",
              \"body\": \"${changelog}\"
            }" \
      "https://api.github.com/repos/$GITHUB_REPO/releases")
    RELEASE_ID=$(echo "${response}" | jq -r '.id // empty')
    if [[ -n "${RELEASE_ID}" ]]; then
      printGreen "Release created successfully with ID: ${RELEASE_ID}"
    elif echo "${response}" | jq -e '.status == "422"' > /dev/null; then
      # In case release has been created in the meantime (e.g. matrix job for multiple devices concurrently)
      RELEASE_ID=$(curl -sL \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/${GITHUB_REPO}/releases" | \
            jq -r --arg release_tag "${OTA_VERSION}" '.[] | select(.tag_name == $release_tag) | .id // empty')
      if [[ -n "${RELEASE_ID}" ]]; then
        printGreen "Cannot create release but found existing release for ${OTA_VERSION}. ID=$RELEASE_ID"
      else
        printRed "Cannot create release for ${OTA_VERSION} because it seems to exist but still cannot find ID."
        exit 1
      fi
    else
      errors=$(echo "${response}" | jq -r '.errors')
      printRed "Failed to create release for ${OTA_VERSION}. Errors: ${errors}"
      exit 1
    fi
  fi
}

function uploadFile() {
  local sourceFileName="$1"
  local targetFileName="$2"
  local contentType="$3"

  # Note that --data-binary might lead to out of memory
  curl --fail -X POST -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: $contentType" \
    --upload-file "$sourceFileName" \
    "https://uploads.github.com/repos/$GITHUB_REPO/releases/$RELEASE_ID/assets?name=$targetFileName"
}

function createOtaServerData() {
  downloadCusotaTool

  for flavor in "${!POTENTIAL_ASSETS[@]}"; do
    local POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
    local targetFile=".tmp/${POTENTIAL_ASSET_NAME}"
    
    local args=()
  
    args+=("--input" "${targetFile}")
    args+=("--output" "${targetFile}.csig")
    args+=("--key" "$KEY_OTA")
    args+=("--cert" "$CERT_OTA")
  
    # If env vars not set, passphrases will be queried interactively
    if [ -v PASSPHRASE_OTA ]; then
      args+=("--passphrase-env-var" "PASSPHRASE_OTA")
    fi
  
    .tmp/custota-tool gen-csig "${args[@]}"
  
    mkdir -p ".tmp/${flavor}"
    
    local args=()
    args+=("--file" ".tmp/${flavor}/${DEVICE_ID}.json")
    # e.g. https://github.com/schnatterer/rooted-graphene/releases/download/2023121200-v26.4-e54c67f/oriole-ota_update-2023121200.zip
    # Instead of constructing the location we could also parse it from the upload response
    args+=("--location" "https://github.com/$GITHUB_REPO/releases/download/$OTA_VERSION/$POTENTIAL_ASSET_NAME")
  
    .tmp/custota-tool gen-update-info "${args[@]}"
  done
}

function downloadCusotaTool() {
  resolveLatest CUSTOTA_VERSION chenxiaolong/Custota v
  downloadAndVerifyFromChenxiaolong 'Custota' "$CUSTOTA_VERSION" 'custota-tool'
}

function uploadOtaServerData() {

  # Update OTA server (github pages)
  local current_branch current_commit base_dir src_repo
  current_commit=$(git rev-parse --short HEAD)
  folderPrefix=''
  
  if [[ "${UPLOAD_TEST_OTA}" == 'true' ]]; then
    folderPrefix='test/'
  fi

  (
    base_dir="$(pwd)"
    src_repo=$(extractGithubRepo "$(git config --get remote.origin.url)")
    if [[ -n "${PAGES_REPO_FOLDER}" ]]; then
      cd "${PAGES_REPO_FOLDER}"
    fi
    
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    git checkout gh-pages
    
    for flavor in "${!POTENTIAL_ASSETS[@]}"; do
      local POTENTIAL_ASSET_NAME="${POTENTIAL_ASSETS[$flavor]}"
      local targetFile="${folderPrefix}${flavor}/${DEVICE_ID}.json"
  
      uploadFile "${base_dir}/.tmp/${POTENTIAL_ASSET_NAME}.csig" "$POTENTIAL_ASSET_NAME.csig" "application/octet-stream"
      
      mkdir -p "${folderPrefix}${flavor}"
      # update only, if current $DEVICE_ID.json does not contain $OTA_VERSION
      # We don't want to trigger users to upgrade on new commits from this repo or new magisk versions
      # They can manually upgrade by downloading the OTAs from the releases and "adb sideload" them
      if ! grep -q "$OTA_VERSION" "${targetFile}" || [[ "$FORCE_OTA_SERVER_UPLOAD" == 'true' ]] && [[ "$SKIP_OTA_SERVER_UPLOAD" != 'true' ]]; then
        cp "${base_dir}/.tmp/${flavor}/$DEVICE_ID.json" "${targetFile}"
        git add "${targetFile}"
      elif grep -q "${OTA_VERSION}" "${targetFile}"; then
        printGreen "Skipping update of OTA server, because ${OTA_VERSION} already in ${folderPrefix}${flavor}/${DEVICE_ID}.json and FORCE_OTA_SERVER_UPLOAD is false."
      else
        printGreen "Skipping update of OTA server, because SKIP_OTA_SERVER_UPLOAD is true."
      fi
    done
    
    if ! git diff-index --quiet HEAD; then
      # Commit and push only when there are changes
      git config user.name "GitHub Actions" && git config user.email "actions@github.com"
      git commit \
          --message "Update device ${DEVICE_ID} basing on ${src_repo}@${current_commit}" \
    
      gitPushWithRetries
    fi
  
    # Switch back to the original branch
    git checkout "$current_branch"
  )
}

extractGithubRepo() {
  # Works for both HTTPS and SSH, e.g.
  # https://github.com/schnatterer/rooted-graphene
  # git@github.com:schnatterer/rooted-graphene.git

  local remote_url="$1"
  local repo

  # Remove the protocol and .git suffix
  remote_url=$(echo "$remote_url" | sed -e 's/.*:\/\/\|.*@//' -e 's/\.git$//')

  # Extract the owner/repo part
  repo=$(echo "$remote_url" | sed -e 's/.*[:\/]\([^\/]*\/[^\/]*\)$/\1/')

  echo "$repo"
}

function gitPushWithRetries() {
  local count=0

  while [ $count -lt $GIT_PUSH_RETRIES ]; do
    git pull --rebase
    if git push origin gh-pages; then
      break
    else
      count=$((count + 1))
      printGreen "Retry $count/$GIT_PUSH_RETRIES failed. Retrying..."
      sleep 2
    fi
  done
  
  if [ $count -eq $GIT_PUSH_RETRIES ]; then
    printRed "Failed to push to gh-pages after $GIT_PUSH_RETRIES attempts."
    exit 1
  fi
}

function print() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S'): $*"
}

function printGreen() {
  if [[ -z "${NO_COLOR}" ]]; then
    echo -e "\e[32m$(date '+%Y-%m-%d %H:%M:%S'): $*\e[0m"
  else
      print "$@"
  fi
}

function printRed() {
  if [[ -z "${NO_COLOR}" ]]; then
   echo -e "\e[31m$(date '+%Y-%m-%d %H:%M:%S'): $*\e[0m"
  else
      print "$@"
  fi
}
