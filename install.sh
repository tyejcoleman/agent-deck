#!/bin/sh
# Installs the `deck` CLI (a single Python 3 file) into ~/.local/bin or $DECK_BIN.
set -eu

VERSION="${DECK_VERSION:-v0.4.0}"
EXPECTED_SHA256="${DECK_SHA256:-a2a0820a3beabb322d99364ad10592e06b9a467d0386eb3e24e8b05b3dfe9b2e}"
BIN="${DECK_BIN:-$HOME/.local/bin}"
URL="${DECK_URL:-https://raw.githubusercontent.com/tyejcoleman/agent-deck/$VERSION/deck}"
TMP="$BIN/.deck-install.$$"

command -v python3 >/dev/null 2>&1 || { echo "deck needs python3 (3.8+)" >&2; exit 1; }
mkdir -p "$BIN"
umask 077
trap 'rm -f "$TMP"' 0 HUP INT TERM

SCRIPT_DIR=""
if [ -f "$0" ]; then
  SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
fi

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/deck" ]; then
  cp "$SCRIPT_DIR/deck" "$TMP"
else
  command -v curl >/dev/null 2>&1 || { echo "deck install needs curl" >&2; exit 1; }
  curl -fsSL "$URL" -o "$TMP"
fi

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP" | awk '{print $1}')
else
  echo "deck install needs sha256sum or shasum" >&2
  exit 1
fi

if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "deck checksum mismatch" >&2
  echo "expected: $EXPECTED_SHA256" >&2
  echo "actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

chmod 0755 "$TMP"
mv "$TMP" "$BIN/deck"
trap - 0 HUP INT TERM
echo "installed $BIN/deck ($("$BIN/deck" --version), sha256 $ACTUAL_SHA256)"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "add to PATH: export PATH=\"$BIN:\$PATH\"";; esac
