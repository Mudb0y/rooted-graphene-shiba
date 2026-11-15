#!/usr/bin/env bash

# Puts the collected Pixel sounds on the phone's shared storage, under Ringtones/Pixel, Alarms/Pixel and
# Notifications/Pixel. Files are overwritten in place, so a sound that is already picked as the ringtone stays
# picked.

set -euo pipefail

BUILT=${1:-$HOME/.cache/rooted-graphene/pixel-sounds}

if ! command -v adb >/dev/null; then
  exec nix shell nixpkgs#android-tools -c "$0" "$@"
fi

if [[ "$(adb get-state 2>/dev/null)" != device ]]; then
  echo "error: the phone does not answer over USB"
  exit 1
fi

total=0
for folder in Ringtones Alarms Notifications; do
  if [[ ! -d "$BUILT/$folder" ]]; then
    echo "error: $BUILT/$folder does not exist; sounds/pixel_sounds.py collect makes it"
    exit 1
  fi
  total=$((total + $(find "$BUILT/$folder" -name '*.ogg' | wc -l)))
done
echo "start: $total sounds to the phone"

removed=0
for folder in Ringtones Alarms Notifications; do
  remote=/sdcard/$folder/Pixel
  adb shell "mkdir -p '$remote'"
  # adb reports its progress on the error stream, so that is only worth printing when the copy fails
  if ! output=$(adb push "$BUILT/$folder/." "$remote/" 2>&1); then
    echo "error: copying $folder to the phone failed: $output"
    exit 1
  fi

  # A sound that is no longer in the set would otherwise stay on the phone forever
  while IFS= read -r name; do
    name=${name%$'\r'}
    if [[ "$name" == *.ogg && ! -f "$BUILT/$folder/$name" ]]; then
      # Without its own input, adb would swallow the rest of the list
      adb shell "rm '$remote/${name//\'/\'\\\'\'}'" </dev/null
      removed=$((removed + 1))
    fi
  done < <(adb shell "ls '$remote'")

  # An overwritten file is left half-registered in the phone's media index, and the sound picker does not list
  # it until its folder has been scanned again
  adb shell "content call --uri content://media --method scan_file --arg '/storage/emulated/0/$folder/Pixel'" \
    >/dev/null
done

on_phone=0
listed=0
for folder in Ringtones Alarms Notifications; do
  on_phone=$((on_phone + $(adb shell "ls '/sdcard/$folder/Pixel'" | grep -c '\.ogg')))
  where="_data LIKE '/storage/emulated/0/$folder/Pixel/%' AND is_pending=0 AND _size>0"
  rows=$(adb shell "content query --uri content://media/external/audio/media --projection _id --where \"$where\"")
  listed=$((listed + $(grep -c '^Row' <<<"$rows" || true)))
done
if [[ $listed -ne $on_phone ]]; then
  echo "error: $on_phone sounds are on the phone, but its sound picker only lists $listed of them"
  exit 1
fi
echo "result: $on_phone sounds on the phone and in its sound picker, $removed stale ones removed"
