#!/bin/sh
# Installs the `deck` CLI (a single Python 3 file) into ~/.local/bin or $DECK_BIN.
set -eu
BIN="${DECK_BIN:-$HOME/.local/bin}"
URL="${DECK_URL:-https://raw.githubusercontent.com/tyejcoleman/agent-deck/main/deck}"
command -v python3 >/dev/null 2>&1 || { echo "deck needs python3 (3.8+)"; exit 1; }
mkdir -p "$BIN"
if [ -f "$(dirname "$0")/deck" ]; then
  cp "$(dirname "$0")/deck" "$BIN/deck"
else
  curl -fsSL "$URL" -o "$BIN/deck"
fi
chmod +x "$BIN/deck"
echo "installed $BIN/deck ($("$BIN/deck" --version))"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "add to PATH: export PATH=\"$BIN:\$PATH\"";; esac
