#!/bin/bash
# Sets up a Mac for working on Peak: Xcode, the code, Claude Code and the GitHub
# command-line tool. Then it starts Claude Code in the project to do the rest: signing,
# building, installing on your iPhone and the desk benchmark. Run it in Terminal with:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Fry19/peak/main/Tools/setup-mac.sh)"
#
# Running it again is safe: whatever is already set up is skipped. It stops for the few
# things only you can do: your Mac password, the App Store, and signing in.
set -euo pipefail

REPO_URL=https://github.com/Fry19/peak.git
DIR="$HOME/peak"
XCODE="${XCODE:-/Applications/Xcode.app}"
XCODEBUILD="$XCODE/Contents/Developer/usr/bin/xcodebuild"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
pause() { read -r -p "    $* Press Return to carry on. " _ < /dev/tty; }

# Puts Homebrew on the PATH if it's installed; fails if it isn't.
load_brew() {
  local brew
  for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$brew" ]]; then
      eval "$("$brew" shellenv)"
      return 0
    fi
  done
  return 1
}

# Adds a line to ~/.zprofile (read by new Terminal windows) unless it's there already.
remember() {
  if ! grep -qF "$1" "$HOME/.zprofile" 2>/dev/null; then
    printf '%s\n' "$1" >> "$HOME/.zprofile"
  fi
}

if [[ "$(uname)" != Darwin ]]; then
  echo "This script is for macOS."
  exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
  note "This Mac has an Intel processor. Peak builds on it, but the iPhone Duo simulator needs Apple silicon."
fi

step "Command line developer tools"
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install 2>/dev/null || true
  note "A window asks to install them: click Install. This waits until they're in."
  until xcode-select -p >/dev/null 2>&1; do sleep 10; done
fi
note "Done."

step "Homebrew"
if ! command -v brew >/dev/null 2>&1 && ! load_brew; then
  note "It asks for your Mac password (nothing shows as you type)."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  load_brew
fi
remember "eval \"\$($(command -v brew) shellenv)\""
note "Done."

step "GitHub command-line tool"
command -v gh >/dev/null 2>&1 || brew install gh
note "Done."

step "Peak's code in $DIR"
if [[ -d "$DIR/.git" ]]; then
  git -C "$DIR" pull --ff-only || note "Couldn't update it (changes made here?); leaving it as it is."
else
  git clone "$REPO_URL" "$DIR"
fi
note "Done."

step "Xcode"
if [[ ! -x "$XCODEBUILD" ]]; then
  note "Opening Xcode in the App Store: click Get, and sign in with your Apple ID if asked."
  note "It's a big download (often 30–60 minutes). This waits and carries on when it's installed."
  open "macappstore://apps.apple.com/app/xcode/id497799835"
  until [[ -x "$XCODEBUILD" ]]; do sleep 30; done
  sleep 30   # let the App Store finish putting it in place
fi
note "Setting it up; it may ask for your Mac password."
sudo xcode-select --switch "$XCODE/Contents/Developer"
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
note "$(xcodebuild -version | head -1) is ready."

step "Claude Code"
export PATH="$HOME/.local/bin:$PATH"
if ! command -v claude >/dev/null 2>&1; then
  curl -fsSL https://claude.ai/install.sh | bash
fi
# shellcheck disable=SC2016  # written to ~/.zprofile as is, expanded there
remember 'export PATH="$HOME/.local/bin:$PATH"'
note "Done."

step "Sign in to GitHub, so changes made on this Mac reach the repo"
if gh auth status >/dev/null 2>&1; then
  note "Already signed in."
else
  note "Answer yes to authenticating Git, then finish in the browser."
  gh auth login --hostname github.com --git-protocol https --web
fi

step "Your part"
cat <<'EOF'
    Three things only you can do:
     1. In Xcode (opening now): Xcode > Settings > Accounts, click + and sign in with
        your Apple ID.
     2. Plug your iPhone into this Mac and tap Trust on it. Developer Mode should still be
        on from sideloading; if not, turn it on in Settings > Privacy & Security >
        Developer Mode and restart the iPhone.
     3. Delete the sideloaded Peak from the iPhone: a free Apple ID allows only 3 apps.
EOF
open -a Xcode
pause "When those are done,"

step "Starting Claude Code in $DIR"
note "The first time, it asks you to log in through your browser."
cd "$DIR"
exec claude "This Mac was just set up for Peak with Tools/setup-mac.sh. My iPhone is plugged in and my Apple ID is signed in to Xcode. Build Peak signed with my personal team, install it on the iPhone and open it. Then fetch the DEM tiles and run the desk benchmark once to check everything works."
