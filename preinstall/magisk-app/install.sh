#!/system/bin/sh

# Magisk only accepts its app as a user app under /data/app, and the app refuses to run as a system app, so it
# cannot be built in the way the other apps are. Left alone, Magisk installs a placeholder that is meant to
# download the real app, and the fork's placeholder asks for a release that does not exist.

PKG=com.topjohnwu.magisk
APK=/system/etc/magisk-app/magisk.apk
TAG=magisk_app

magisk=$(command -v magisk || echo /debug_ramdisk/magisk)

# The APK next to this script is the one the boot image was patched with, so Magisk's version is its version
if ! want=$("$magisk" -V) || ! hidden=$("$magisk" --sqlite "SELECT value FROM strings WHERE key='requester'"); then
  log -p e -t "$TAG" "Magisk did not answer, leaving its app alone"
  exit 1
fi
case "$want" in
  '' | *[!0-9]*)
    log -p e -t "$TAG" "Magisk reported version '$want', leaving its app alone"
    exit 1
    ;;
esac

# A hidden Magisk app runs under another package name, and installing this one next to it would unhide it
if [ -n "$hidden" ]; then
  exit 0
fi

installed() {
  pm list packages --user 0 --show-versioncode "$PKG" | while read -r name code; do
    if [ "$name" = "package:$PKG" ]; then
      echo "${code#versionCode:}"
    fi
  done
}

# Magisk sorts out its app at this same moment: it removes one signed for another Magisk and puts its placeholder
# there, and a placeholder that was already queued lands on top of a fresh install. So only stop once the app has
# been right twice, some seconds apart.
installs=0
right=0
while :; do
  have=$(installed)
  if [ -n "$have" ] && [ "$have" -ge "$want" ]; then
    right=$((right + 1))
    if [ "$right" -ge 2 ]; then
      exit 0
    fi
  elif [ "$installs" -ge 3 ]; then
    log -p e -t "$TAG" "Magisk app is at ${have:-nothing} instead of $want after $installs installs"
    exit 1
  else
    right=0
    installs=$((installs + 1))
    log -t "$TAG" "Installing Magisk app $want over ${have:-nothing}: $(pm install -g -r "$APK" 2>&1)"
  fi
  sleep 15
done
