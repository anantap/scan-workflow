#!/bin/bash
# Zet scan-inbox aan als achtergrondtaak: elke nieuwe scan in de inbox-map wordt vanzelf omgezet.
#
#   automation/install.sh                     inbox ~/Scans/Inbox
#   automation/install.sh ~/Scans/Inbox --zw  eigen map en opties (zie scan-inbox.mjs --help)
#   automation/install.sh --verwijder         uitzetten
set -euo pipefail
cd "$(dirname "$0")"

LABEL="nl.ananta.scan-inbox"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/scan-inbox.log"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "--verwijder" ]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "scan-inbox staat uit. De inbox-map en de omgezette foto's blijven staan."
  exit 0
fi

INBOX="$HOME/Scans/Inbox"
if [ $# -gt 0 ] && [ "${1:0:1}" != "-" ]; then INBOX="$1"; shift; fi
INBOX="${INBOX/#\~/$HOME}"
case "$INBOX" in /*) ;; *) INBOX="$(pwd)/$INBOX" ;; esac

# Op een externe schijf: die moet nu aangesloten zijn om de map te maken
case "$INBOX" in
  /Volumes/*)
    VOLUME="$(printf '%s' "$INBOX" | cut -d/ -f1-3)"
    if [ ! -d "$VOLUME" ]; then
      echo "$VOLUME is niet aangesloten. Sluit de schijf aan en probeer het opnieuw."
      exit 1
    fi ;;
esac

# macOS laat achtergrondtaken niet zonder toestemming in deze mappen
case "$INBOX" in
  "$HOME/Desktop"*|"$HOME/Documents"*|"$HOME/Downloads"*|"$HOME/Library/Mobile Documents"*)
    echo "Kies een inbox buiten Bureaublad, Documenten, Downloads en iCloud Drive,"
    echo "bijvoorbeeld ~/Scans/Inbox: daar mag een achtergrondtaak niet zomaar in."
    exit 1 ;;
esac

NODE="$(command -v node || true)"
for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
  [ -z "$NODE" ] && [ -x "$candidate" ] && NODE="$candidate"
done
if [ -z "$NODE" ]; then
  echo "Node ontbreekt. Installeer het eerst met:  brew install node"
  exit 1
fi

SCRIPT="$(pwd)/scan-inbox.mjs"
mkdir -p "$INBOX" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
ARGS="    <string>$(xml "$NODE")</string>
    <string>$(xml "$SCRIPT")</string>
    <string>$(xml "$INBOX")</string>"
for extra in "$@"; do ARGS="$ARGS
    <string>$(xml "$extra")</string>"; done

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
$ARGS
  </array>
  <!-- Start zodra er iets in de inbox verandert, en elke minuut, zodat een afgeronde rol ook in balans komt. -->
  <key>WatchPaths</key>
  <array>
    <string>$(xml "$INBOX")</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>LowPriorityIO</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml "$LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml "$LOG")</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST" >/dev/null
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "scan-inbox staat aan."
echo "  Inbox:     $INBOX"
echo "  Positief:  $INBOX/Positief"
echo "  Logboek:   $LOG"
echo
echo "Zet in VueScan de uitvoermap op de inbox (zie de tab Omzetten op de site)."
case "$INBOX" in
  /Volumes/*)
    echo
    echo "Externe schijf: macOS laat een achtergrondtaak daar alleen met toestemming in."
    echo "Geef node volledige schijftoegang: Systeeminstellingen > Privacy en beveiliging >"
    echo "Volledige schijftoegang > + > Cmd-Shift-G > plak dit pad > Open:"
    echo "  $(readlink -f "$NODE" 2>/dev/null || echo "$NODE")" ;;
esac
open "$INBOX"
