#!/usr/bin/env bash

# First install on a Pixel 8. One stage per run, in this order:
#
#   fetch, bootloader, stock, patched, lock
#
# "sideload" is optional, between patched and lock: it rehearses an update
# through recovery. "status" reports what the phone is doing right now. Output
# from the tools goes to the log, so the terminal only carries what needs hearing.

set -euo pipefail

if ! command -v fastboot >/dev/null || ! command -v adb >/dev/null; then
  exec nix shell nixpkgs#android-tools -c "$0" "$@"
fi

here=$(dirname "$(realpath "$0")")
project=$(dirname "$here")

DEVICE=shiba
FLAVOR=${FLAVOR:-pixincreate}
REPO=${REPO:-Mudb0y/rooted-graphene-shiba}
WORK=${WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/rooted-graphene}
LOG="$WORK/install.log"
AVB_KEY="$project/public/avb_pkmd.bin"
OTA_CERT="$project/public/ota.crt"
# From https://grapheneos.org/install/cli
GRAPHENEOS_SIGNER='contact@grapheneos.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIUg/m5CoP83b0rfSCzYSVA4cw4ir49io5GPoxbgxdJE'
# avbroot's fastboot set only covers what avbroot itself patches, which leaves out vendor and product. The build
# changes both, and a slot that mixes them with the stock images fails verity before Android starts. Flashing
# everything else verified boot covers from the patched update too leaves the slot exactly as a sideload would,
# so locking does not depend on one, and an unlocked bootloader cannot hide a mismatch until the lock.
STATIC=(dtbo pvmfw vendor_kernel_boot)
DYNAMIC=(product vendor system_ext system_dlkm vendor_dlkm)

mkdir -p "$WORK"

# USE_SUDO=1 is for a machine whose udev rules do not hand the phone to this user.
# GrapheneOS's flash-all.sh finds fastboot on PATH, so the wrappers have to live there.
if [[ -n "${USE_SUDO:-}" && -z "${ROOTED_GRAPHENE_WRAPPED:-}" ]]; then
  mkdir -p "$WORK/bin"
  for tool in adb fastboot; do
    printf '#!/bin/sh\nexec sudo %s "$@"\n' "$(command -v "$tool")" >"$WORK/bin/$tool"
    chmod +x "$WORK/bin/$tool"
  done
  export PATH="$WORK/bin:$PATH" ROOTED_GRAPHENE_WRAPPED=1
fi

log() {
  printf '%s %s\n' "$(date +%T)" "$*" >>"$LOG"
}

quiet() {
  log "+ $*"
  "$@" >>"$LOG" 2>&1
}

fail() {
  echo "error: $*"
  echo "The full output is in $LOG"
  exit 1
}

confirm() {
  read -r -p "$1 Press Enter to go on, or Control C to stop. "
}

# fastboot waits forever when no phone answers, hence the timeout
fb_var() {
  timeout 15 fastboot getvar "$1" 2>&1 | sed -n "s/^$1: *//p" | head -n1
}

# One of: bootloader, fastbootd, device, unauthorized, recovery, sideload, rescue, offline, denied, none
mode() {
  local listing

  listing=$(fastboot devices 2>&1 || true)
  if [[ "$listing" == *'no permissions'* ]]; then
    echo denied
    return
  fi
  if [[ -n "$listing" ]]; then
    if [[ "$(fb_var is-userspace)" == yes ]]; then echo fastbootd; else echo bootloader; fi
    return
  fi

  listing=$(adb devices 2>&1 || true)
  if [[ "$listing" == *'no permissions'* ]]; then
    echo denied
    return
  fi
  awk 'NR > 1 && NF == 2 { print $2; found = 1; exit } END { if (!found) print "none" }' <<<"$listing"
}

# wait_mode <seconds> <mode>...
wait_mode() {
  local deadline=$((SECONDS + $1)) current want
  shift

  while ((SECONDS < deadline)); do
    current=$(mode)
    if [[ "$current" == denied ]]; then
      fail "This user may not open the phone over USB. Run the stage again with USE_SUDO=1 in front."
    fi
    for want in "$@"; do
      if [[ "$current" == "$want" ]]; then
        return 0
      fi
    done
    sleep 2
  done

  return 1
}

adb_prop() {
  adb shell getprop "$1" 2>/dev/null | tr -d '\r'
}

wait_booted() {
  local deadline=$((SECONDS + $1))

  while ((SECONDS < deadline)); do
    if [[ "$(mode)" == device && "$(adb_prop sys.boot_completed)" == 1 ]]; then
      return 0
    fi
    sleep 3
  done

  return 1
}

# Waits for the person to finish the setup wizard and switch on USB debugging
wait_authorized() {
  local deadline=$((SECONDS + $1)) asked=''

  while ((SECONDS < deadline)); do
    case "$(mode)" in
      device)
        return 0
        ;;
      unauthorized)
        if [[ -z "$asked" ]]; then
          echo "The phone is asking whether to allow USB debugging from this computer. Tick always allow, then choose Allow."
          asked=1
        fi
        ;;
    esac
    sleep 3
  done

  return 1
}

need_files() {
  if [[ ! -f "$WORK/version" || ! -f "$WORK/ota" || ! -d "$WORK/extracted-rest" ]]; then
    fail "Run the fetch stage first."
  fi
  VERSION=$(<"$WORK/version")
  OTA=$(<"$WORK/ota")
  FACTORY="$WORK/$DEVICE-install-$VERSION"
}

need_unlocked_bootloader() {
  local product

  if [[ "$(mode)" != bootloader ]]; then
    fail "The phone is not in the bootloader. Run the bootloader stage first."
  fi
  product=$(fb_var product)
  if [[ "$product" != "$DEVICE" ]]; then
    fail "This is a '$product', not a $DEVICE. Nothing was changed."
  fi
  if [[ "$(fb_var unlocked)" != yes ]]; then
    fail "The bootloader is locked. Run the bootloader stage first."
  fi
}

download() {
  if [[ ! -f "$2" ]]; then
    quiet curl --fail -sSL -o "$2.part" "$1" || fail "Could not download $1"
    mv "$2.part" "$2"
  fi
}

stage_fetch() {
  local info url version factory partition extract=()

  echo "start: downloading and checking the install files, about four gigabytes"

  info=$(curl --fail -sL "https://raw.githubusercontent.com/$REPO/gh-pages/$FLAVOR/$DEVICE.json") ||
    fail "The update server has no $FLAVOR build for $DEVICE yet."
  url=$(jq -r '.full.location_ota' <<<"$info")
  version=$(basename "$url" | cut -d- -f2)
  if [[ ! "$version" =~ ^[0-9]{10}$ ]]; then
    fail "Could not read the GrapheneOS version from $url"
  fi
  factory="$DEVICE-install-$version"

  download "$url" "$WORK/$(basename "$url")"
  download "https://releases.grapheneos.org/$factory.zip" "$WORK/$factory.zip"
  download "https://releases.grapheneos.org/$factory.zip.sig" "$WORK/$factory.zip.sig"

  quiet ssh-keygen -Y verify -f <(echo "$GRAPHENEOS_SIGNER") -I contact@grapheneos.org -n 'factory images' \
    -s "$WORK/$factory.zip.sig" <"$WORK/$factory.zip" ||
    fail "The GrapheneOS factory image does not carry GrapheneOS's signature."

  # Same pinned, signature-checked avbroot the build uses
  if [[ ! -x "$WORK/.tmp/avbroot" ]]; then
    # shellcheck disable=SC2016
    (cd "$WORK" && quiet bash -c '. "$1" && downloadAvBroot' _ "$project/rooted-ota.sh") ||
      fail "Could not download avbroot."
  fi

  quiet "$WORK/.tmp/avbroot" ota verify --input "$WORK/$(basename "$url")" \
    --public-key-avb "$AVB_KEY" --cert-ota "$OTA_CERT" ||
    fail "The patched update is not signed with the keys in $project/public."

  rm -rf "${WORK:?}/$factory" "$WORK/extracted" "$WORK/extracted-rest"
  quiet unzip -q "$WORK/$factory.zip" -d "$WORK"
  quiet "$WORK/.tmp/avbroot" ota extract --input "$WORK/$(basename "$url")" \
    --directory "$WORK/extracted" --fastboot
  for partition in "${STATIC[@]}" "${DYNAMIC[@]}"; do
    extract+=(--partition "$partition")
  done
  quiet "$WORK/.tmp/avbroot" ota extract --input "$WORK/$(basename "$url")" \
    --directory "$WORK/extracted-rest" "${extract[@]}"

  echo "$version" >"$WORK/version"
  echo "$WORK/$(basename "$url")" >"$WORK/ota"

  echo "result: GrapheneOS $version and the $FLAVOR update are downloaded and verified"
}

stage_bootloader() {
  local product

  echo "start: getting the phone into the bootloader"

  case "$(mode)" in
    bootloader) ;;
    device)
      quiet adb reboot bootloader
      ;;
    *)
      echo "Hold power and volume down together and keep holding. This reports as soon as the bootloader answers, which can take twenty seconds."
      ;;
  esac

  wait_mode 300 bootloader || fail "No bootloader answered within five minutes."

  product=$(fb_var product)
  if [[ "$product" != "$DEVICE" ]]; then
    fail "This is a '$product', not a $DEVICE. Nothing was changed."
  fi

  if [[ "$(fb_var unlocked)" == yes ]]; then
    echo "result: the phone is in the bootloader and already unlocked"
    return
  fi

  confirm "The bootloader is locked. Unlocking it erases the phone."
  quiet fastboot flashing unlock || fail "The phone refused to unlock. OEM unlocking has to be on in developer options."
  echo "On the phone, press one volume button once, then press power."

  local deadline=$((SECONDS + 180))
  while ((SECONDS < deadline)); do
    if [[ "$(mode)" == bootloader && "$(fb_var unlocked)" == yes ]]; then
      echo "result: the bootloader is unlocked"
      return
    fi
    sleep 2
  done

  fail "The bootloader is still locked after three minutes. Run this stage again to retry."
}

stage_stock() {
  need_files
  need_unlocked_bootloader

  confirm "This erases the phone and installs plain GrapheneOS $VERSION."
  echo "start: flashing GrapheneOS, about ten minutes, leave the phone alone"

  (cd "$FACTORY" && quiet bash flash-all.sh) ||
    fail "Flashing GrapheneOS failed. The phone is still unlocked, so this stage can be run again."
  wait_mode 120 bootloader ||
    fail "GrapheneOS was flashed, but the phone did not come back to the bootloader."

  echo "result: GrapheneOS $VERSION is flashed and the phone is waiting in the bootloader. Run the patched stage next."
}

report_app() {
  local path

  path=$(adb shell pm path "$2" 2>/dev/null | tr -d '\r')
  if [[ "$path" == "package:/system/app/$1/"* ]]; then
    echo "$1 is built in: yes"
  else
    echo "$1 is built in: NO, pm path says '${path}'"
  fi
}

stage_patched() {
  local partition

  need_files

  if [[ "$(mode)" == device ]]; then
    quiet adb reboot bootloader
    wait_mode 120 bootloader || fail "The phone did not reach the bootloader."
  fi
  need_unlocked_bootloader

  echo "start: flashing the patched system, about five minutes, leave the phone alone"

  for partition in "${STATIC[@]}"; do
    quiet fastboot flash "$partition" "$WORK/extracted-rest/$partition.img" ||
      fail "Flashing $partition failed. The phone is still unlocked. The stock stage puts plain GrapheneOS back."
  done
  ANDROID_PRODUCT_OUT="$WORK/extracted" quiet fastboot flashall --skip-reboot ||
    fail "Flashing the patched system failed. The phone is still unlocked. The stock stage puts plain GrapheneOS back."
  # Dynamic partitions can only be written from the fastboot that runs inside recovery
  if [[ "$(mode)" != fastbootd ]]; then
    quiet fastboot reboot fastboot
    wait_mode 120 fastbootd || fail "The phone did not enter the second fastboot mode."
  fi
  for partition in "${DYNAMIC[@]}"; do
    quiet fastboot flash "$partition" "$WORK/extracted-rest/$partition.img" ||
      fail "Flashing $partition failed. The phone is still unlocked. The stock stage puts plain GrapheneOS back."
  done
  quiet fastboot reboot-bootloader
  wait_mode 120 bootloader || fail "The phone did not come back to the bootloader."
  quiet fastboot erase avb_custom_key
  quiet fastboot flash avb_custom_key "$AVB_KEY" || fail "Could not store the signing key in the bootloader."
  quiet fastboot reboot

  echo "The patched system is starting, which takes a few minutes the first time."
  echo "At the setup wizard, start the screen reader with both volume keys, the way you started TalkBack before. This time SandFly should answer."
  echo "Then finish the wizard. On its last screen, untick the box about OEM unlocking, so that OEM unlocking stays allowed."
  echo "Then open Settings, About phone, and activate Build number seven times. Go back, open System, Developer options, and turn on USB debugging."
  echo "This waits up to an hour and reports as soon as USB debugging answers."

  if ! wait_authorized 3600; then
    if [[ "$(mode)" == bootloader ]]; then
      fail "The patched system did not start and the phone fell back to the bootloader. It is still unlocked. The stock stage puts plain GrapheneOS back."
    fi
    fail "USB debugging did not answer within an hour. Run the status stage to hear what the phone is doing."
  fi

  wait_booted 120 || fail "The phone answers but has not finished starting."

  report_app SandFly io.github.aaron_gh.sandfly
  report_app OpenEVV com.mudb0y.openevv
  report_app Appletizer com.mudb0y.appletizer
  report_app Parroglott com.mudb0y.parroglott
  echo "The accessibility shortcut points at: $(adb shell cmd overlay lookup android android:string/config_defaultAccessibilityService 2>&1 | tr -d '\r')"
  echo "Installed build: $(adb_prop ro.build.version.incremental), slot $(adb_prop ro.boot.slot_suffix)"

  echo "result: the patched system runs. If SandFly and your voices work, run the lock stage next."
}

stage_sideload() {
  local before after status attempt

  need_files

  if [[ "$(mode)" != device ]]; then
    fail "The phone has to be running with USB debugging on. Run the status stage to hear what it is doing."
  fi
  before=$(adb_prop ro.boot.slot_suffix)

  echo "start: sideloading the full update, about ten minutes, leave the phone alone"

  quiet adb reboot sideload-auto-reboot
  wait_mode 180 sideload || fail "The phone did not enter sideload mode."
  # adb reports an error when the phone reboots at the end, so the slot check below decides
  quiet adb sideload "$OTA" || true

  wait_booted 1500 ||
    fail "The phone did not come back within twenty five minutes. Run the status stage to hear what it is doing."
  after=$(adb_prop ro.boot.slot_suffix)
  if [[ "$after" == "$before" ]]; then
    fail "The phone is still on slot $before, so the update was not applied. Recovery's reason is on the phone's screen only."
  fi
  echo "The update is applied and the phone now runs from slot $after. Waiting for Android to finish merging it."

  # Locking wipes the phone, which must not happen in the middle of the merge.
  # The merge only runs while Android is up, and only the bootloader reports its state.
  for attempt in 1 2 3 4 5 6; do
    sleep 240
    quiet adb reboot bootloader
    wait_mode 120 bootloader || fail "The phone did not reach the bootloader."
    status=$(fb_var snapshot-update-status)
    log "snapshot-update-status: $status (attempt $attempt)"
    if [[ "$status" == none ]]; then
      echo "result: the update is fully applied and the phone is waiting in the bootloader. Run the lock stage next."
      return
    fi
    quiet fastboot reboot
    wait_booted 900 || fail "The phone did not start again."
  done

  fail "Android has not finished merging the update after half an hour."
}

stage_lock() {
  local ability status deadline current

  if [[ "$(mode)" == device ]]; then
    quiet adb reboot bootloader
    wait_mode 120 bootloader || fail "The phone did not reach the bootloader."
  fi
  need_unlocked_bootloader

  # Locking wipes the phone, which must not happen in the middle of a merge
  status=$(fb_var snapshot-update-status)
  if [[ "$status" != none ]]; then
    quiet fastboot reboot || true
    fail "An update is still being merged, state '$status'. The phone is starting again. Leave it running for ten minutes, then run this stage again."
  fi

  # With OEM unlocking off, a locked phone that fails to start cannot be rescued
  ability=$(timeout 15 fastboot flashing get_unlock_ability 2>&1 | sed -n 's/.*get_unlock_ability: *\([01]\).*/\1/p' | head -n1)
  if [[ "$ability" != 1 ]]; then
    fail "OEM unlocking is switched off, so locking now would be unsafe. Start the phone, turn OEM unlocking on in developer options, and try again."
  fi

  confirm "Locking the bootloader erases the phone one more time."
  quiet fastboot flashing lock || fail "The phone refused the lock command."
  echo "On the phone, press one volume button once, then press power."

  deadline=$((SECONDS + 180))
  while ((SECONDS < deadline)); do
    current=$(mode)
    if [[ "$current" == bootloader && "$(fb_var unlocked)" == no ]]; then
      quiet fastboot reboot
      break
    fi
    if [[ "$current" == none ]]; then
      # It left the bootloader on its own, which it only does once the lock is confirmed
      break
    fi
    sleep 2
  done
  if ((SECONDS >= deadline)); then
    fail "The bootloader is still unlocked after three minutes. Run this stage again to retry."
  fi

  echo "result: the bootloader is locked and the phone is erasing itself and starting"
  echo "It shows a warning screen for about ten seconds on every start from now on. That is expected and needs no key press."
  echo "At the setup wizard, start SandFly with both volume keys."
  echo "On the last screen of the wizard, untick the box about OEM unlocking. OEM unlocking must stay allowed for as long as the phone is rooted."
}

stage_status() {
  local current

  current=$(mode)
  echo "Phone state: $current"
  case "$current" in
    bootloader | fastbootd)
      echo "Model: $(fb_var product)"
      echo "Unlocked: $(fb_var unlocked)"
      echo "Active slot: $(fb_var current-slot)"
      echo "Update merge state: $(fb_var snapshot-update-status)"
      ;;
    device)
      echo "Build: $(adb_prop ro.build.version.incremental)"
      echo "Active slot: $(adb_prop ro.boot.slot_suffix)"
      echo "Finished starting: $(adb_prop sys.boot_completed)"
      echo "Verified boot state: $(adb_prop ro.boot.verifiedbootstate)"
      echo "OEM unlocking allowed: $(adb_prop sys.oem_unlock_allowed)"
      ;;
  esac
}

case "${1:-}" in
  fetch | bootloader | stock | patched | sideload | lock | status)
    log "=== stage $1"
    "stage_$1"
    ;;
  *)
    echo "usage: $0 fetch|bootloader|stock|patched|sideload|lock|status"
    exit 1
    ;;
esac
