#!/bin/zsh
# Installs dist/提醒条.app into the system Applications folder (/Applications). Every update goes there.
# Usage: Tools/install_dev_app.sh [--replace]      (--replace is needed once the app is already installed)
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
APP_NAME="提醒条"
APP_SOURCE="$ROOT/dist/$APP_NAME.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP_DEST="$INSTALL_DIR/$APP_NAME.app"
# Earlier versions were installed here. The system's "open at login" record still points at this path,
# so it stays as a link to the real app instead of a second copy.
LEGACY="$HOME/Applications/$APP_NAME.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
REPLACE=false

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--replace" ) ]]; then
  print -u2 "Usage: Tools/install_dev_app.sh [--replace]"
  exit 2
fi
if [[ $# -eq 1 ]]; then
  REPLACE=true
fi

if [[ ! -x "$APP_SOURCE/Contents/MacOS/RemindBar" ]]; then
  print -u2 "Build the app first with Tools/package_app.sh"
  exit 1
fi
if [[ ! -d "$INSTALL_DIR" || ! -w "$INSTALL_DIR" ]]; then
  print -u2 "$INSTALL_DIR is not writable for this user; installing there needs an administrator account."
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

if [[ -e "$APP_DEST" ]]; then
  if [[ "$REPLACE" != true ]]; then
    print -u2 "Refusing to overwrite existing app: $APP_DEST"
    print -u2 "Use --replace for an explicit development build upgrade."
    exit 1
  fi
fi

# A running copy would keep the old binary alive; a menu-bar-only app has no scripting dictionary, so stop the process.
pkill -x RemindBar >/dev/null 2>&1 || true
sleep 1

if [[ -e "$APP_DEST" ]]; then
  BACKUP="/tmp/$APP_NAME.previous.$STAMP.app"
  mv "$APP_DEST" "$BACKUP"
  print "Previous app moved to: $BACKUP"
fi
ditto "$APP_SOURCE" "$APP_DEST"

# The copy must be the very same build: the system's permissions (Reminders, microphone…) are tied to its signature.
codesign --verify --deep --strict "$APP_DEST"
if [[ "$(cdhash "$APP_SOURCE")" != "$(cdhash "$APP_DEST")" ]]; then
  print -u2 "The installed copy does not match the build (signature differs)."
  exit 1
fi

# Move an old ~/Applications copy out of the way and leave a link to the real app in its place.
if [[ "$INSTALL_DIR" != "$HOME/Applications" ]]; then
  if [[ -e "$LEGACY" && ! -L "$LEGACY" ]]; then
    LEGACY_BACKUP="/tmp/$APP_NAME.legacy.$STAMP.app"
    mv "$LEGACY" "$LEGACY_BACKUP"
    print "Old copy in ~/Applications moved to: $LEGACY_BACKUP"
    "$LSREGISTER" -u "$LEGACY_BACKUP" >/dev/null 2>&1 || true
  fi
  if [[ ! -e "$LEGACY" || -L "$LEGACY" ]]; then
    mkdir -p "$HOME/Applications"
    ln -sfn "$APP_DEST" "$LEGACY"
  fi
fi

# Make the system know the installed app, and forget the build copies so a notification never opens one of those.
"$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$APP_SOURCE" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$ROOT/dist/previous/$APP_NAME.app" >/dev/null 2>&1 || true

print "Installed local development app at: $APP_DEST (signature $(cdhash "$APP_DEST" | cut -c1-12)…)"
print "Launch with: open '$APP_DEST'"
