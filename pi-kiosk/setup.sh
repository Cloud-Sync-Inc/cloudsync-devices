#!/bin/bash
# CloudSync Raspberry Pi Kiosk Setup Script v3.7
# Works on Raspberry Pi OS 64-bit (desktop) and 32-bit Legacy.
# Identical script for every clinic deployment.
# Safe to run more than once on the same Pi. Works under any username.
#
# One-command install (sets token, zoom, locks read-only, then reboots):
#   curl -fsSL <SCRIPT_URL> | bash -s -- TOKEN ZOOM
# Or from a local copy:
#   bash cloudsync-pi-setup.sh TOKEN ZOOM
# Without arguments it sets everything up but leaves the token
# alone, does not lock, and does not reboot.
#
# READ-ONLY MODE: once locked, nothing is written to the SD card.
# Anything saved on the Pi is lost at reboot. To change a token,
# zoom, or staff messages:
#   1) bash ~/kiosk-unlock.sh               (reboots)
#   2) bash ~/update-clinic.sh TOKEN ZOOM   (or edit ~/kiosk/messages.js)
#   3) bash ~/kiosk-lock.sh                 (reboots)
#
# v3.7: read-only SD card (overlay) with kiosk-lock / kiosk-unlock
#       helpers; automatic OS updates off; journal in RAM only;
#       Chromium cache capped at 50MB; watchdog log only records
#       restarts; hardware watchdog relaxed to 60s; power check
# v3.6: staff message strip along the bottom, 100 messages,
#       5 minute rotation picked from the clock
# v3.5: hardware watchdog handed to systemd (the separate
#       watchdog program could not open the device on new OS)
# v3.4: wrapped in main() so a partial download never runs half a
#       script; refuses to run as root; finds the boot folder on any
#       image; Pi-safe watchdog timeout; cron watchdog can reach X
# v3.3: optional TOKEN ZOOM arguments + automatic reboot
# v3.2 changes:
#   - apt update before any installs (fresh images fail without it)
#   - installs cron explicitly (not guaranteed on newer images)
#   - forces 1080p via cmdline.txt (KMS ignores hdmi_group/hdmi_mode)
#   - Chromium pinned to X11 and basic password store (no keyring popup)

set -u

# Everything runs inside main(), which is only called on the last
# line. If the download is cut off, bash never reaches that line
# and nothing runs.
main() {

ARG_TOKEN="${1:-}"
ARG_ZOOM="${2:-1.5}"

if [ "$(id -u)" -eq 0 ]; then
    echo "Do not run this with sudo or as root. Run it as the normal Pi user."
    exit 1
fi

# Running setup while locked would look like it worked, then
# lose everything at the next reboot.
if [ "$(findmnt -n -o FSTYPE /)" = "overlay" ]; then
    echo "This Pi is in read-only mode. Changes would be lost at reboot."
    echo "Run: bash ~/kiosk-unlock.sh   then run this script again."
    exit 1
fi

# Newer images use /boot/firmware, older ones use /boot
if [ -f /boot/firmware/config.txt ]; then
    BOOTDIR=/boot/firmware
else
    BOOTDIR=/boot
fi

echo "=== CloudSync Kiosk Setup v3.7 Starting ==="
echo "User: $(whoami)   Home: $HOME   Arch: $(uname -m)   Boot: $BOOTDIR"
echo ""

# Ask for the sudo password once, up front. Reads from the
# keyboard even when this script is piped in from curl.
sudo -v < /dev/tty || { echo "sudo password failed, stopping."; exit 1; }
# Keep sudo unlocked until the script finishes
( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill $SUDO_KEEPALIVE 2>/dev/null' EXIT

# =============================================
# STEP 0 -- Package lists and base tools
# =============================================
echo "Updating package lists..."
sudo apt update
sudo apt install -y cron unclutter xdotool
# Read-only mode support. Newer images need this package; older
# Legacy images handle it inside raspi-config instead.
sudo apt install -y overlayroot 2>/dev/null || echo "overlayroot package not available, raspi-config will handle read-only mode"

# =============================================
# STEP 0b -- No automatic OS updates
# Kiosks get updated on purpose, one Pi at a time,
# never on their own. Manual apt still works.
# =============================================
echo "Disabling automatic updates..."
sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null
sudo systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null
if dpkg -s unattended-upgrades > /dev/null 2>&1; then
    sudo apt purge -y unattended-upgrades
fi
printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "0";\n' \
    | sudo tee /etc/apt/apt.conf.d/99cloudsync-no-auto-updates > /dev/null

# =============================================
# STEP 1 -- Create config file
# Does NOT overwrite an existing config, so re-running
# this script will never wipe a live clinic's token.
# =============================================
if [ -f "$HOME/cloudsync-kiosk.conf" ]; then
    echo "Config already exists, leaving it alone:"
    cat "$HOME/cloudsync-kiosk.conf"
else
    echo "Creating config file..."
    cat > "$HOME/cloudsync-kiosk.conf" << 'EOF'
# CloudSync Kiosk Configuration
# Set with: bash ~/update-clinic.sh TOKEN ZOOM
# After editing run: bash ~/kiosk-lock.sh

TOKEN=UNCONFIGURED
ZOOM=1.5
EOF
    echo "Config created at $HOME/cloudsync-kiosk.conf (token not yet set)"
fi

# =============================================
# STEP 2 -- Create kiosk launcher script
# Cache is capped at 50MB. In read-only mode Chromium's cache
# lives in RAM, so an uncapped cache would slowly eat memory.
# =============================================
echo "Creating kiosk launcher script..."
cat > "$HOME/launch-kiosk.sh" << 'EOF'
#!/bin/bash
# CloudSync Kiosk Launcher

CONFIG="__HOME__/cloudsync-kiosk.conf"
LOG="__HOME__/watchdog.log"

if [ -f "$CONFIG" ]; then
    source "$CONFIG"
else
    echo "$(date): Config file not found -- using defaults" >> "$LOG"
    TOKEN="UNCONFIGURED"
    ZOOM="1.5"
fi

if [ "$TOKEN" = "UNCONFIGURED" ]; then
    echo "$(date): TOKEN is UNCONFIGURED -- run update-clinic.sh" >> "$LOG"
fi

# chromium-browser on older images, chromium on newer ones
if command -v chromium-browser > /dev/null; then
    BROWSER=chromium-browser
else
    BROWSER=chromium
fi

# Local page: board on top, staff message strip on the bottom
URL="file://__HOME__/kiosk/kiosk.html?t=${TOKEN}"

echo "$(date): Launching $BROWSER with token ${TOKEN:0:8}..." >> "$LOG"

DISPLAY=:0 $BROWSER \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --no-first-run \
    --ozone-platform=x11 \
    --password-store=basic \
    --disk-cache-size=52428800 \
    --force-device-scale-factor=${ZOOM} \
    "${URL}" &
EOF
chmod +x "$HOME/launch-kiosk.sh"

# =============================================
# STEP 2b -- Message strip page and staff messages
# The kiosk opens a local page: room board on top, a strip of
# rotating staff messages along the bottom. Re-running this
# script rewrites both files from the copies below.
# =============================================
echo "Creating message strip page..."
mkdir -p "$HOME/kiosk"
cat > "$HOME/kiosk/kiosk.html" << 'KIOSKHTML'
<!doctype html>
<html><head><meta charset="utf-8">
<style>
html,body{margin:0;height:100%;background:#000;overflow:hidden}
body{display:flex;flex-direction:column}
iframe{flex:1;border:0;width:100%}
#strip{height:8vh;display:flex;align-items:center;justify-content:center;
  background:#0f172a;color:#fff;font:600 3.4vh/1.2 system-ui,sans-serif;
  text-align:center;padding:0 3vw;transition:opacity .8s}
#strip.hide{opacity:0}
</style></head><body>
<iframe id="board"></iframe>
<div id="strip"></div>
<script>
var t = new URLSearchParams(location.search).get('t') || '';
document.getElementById('board').src = 'https://go.mycloudsync.app/kiosk/room-board/' + t;
var strip = document.getElementById('strip'), shown = null;
function load(cb){
  var s = document.createElement('script');
  s.src = 'messages.js?' + Date.now();
  s.onload = s.onerror = function(){ s.remove(); cb(); };
  document.head.appendChild(s);
}
// The message is picked from the clock, not a counter, so a reboot
// never restarts the list and every Pi shows the same message.
function tick(){
  load(function(){
    var m = window.KIOSK_MESSAGES || [];
    var period = (window.KIOSK_ROTATE_MINUTES || 5) * 60000;
    var now = Date.now();
    if (!m.length) {
      strip.style.display = 'none';
    } else {
      strip.style.display = 'flex';
      var text = m[Math.floor(now / period) % m.length];
      if (text !== shown) {
        shown = text;
        strip.classList.add('hide');
        setTimeout(function(){
          strip.textContent = text;
          strip.classList.remove('hide');
        }, 800);
      }
    }
    setTimeout(tick, period - (now % period) + 500);
  });
}
tick();
</script>
</body></html>
KIOSKHTML

echo "Writing staff messages..."
cat > "$HOME/kiosk/messages.js" << 'KIOSKMSGS'
// CloudSync staff messages. Edit freely; changes show at the next rotation.
// In read-only mode, run ~/kiosk-unlock.sh first or your edits are lost at reboot.
// Themes are interleaved so the same kind of message doesn't repeat back to back.
window.KIOSK_MESSAGES = [
  "Treat every patient like a loved one",
  "Smooth is fast",
  "We win or lose as a team",
  "Say it clearly the first time",
  "Details are the job",
  "Breathe. Then go.",
  "What we do matters to this town",
  "Every patient is someone's whole world",
  "Room the next patient before you're asked",
  "If you see it, own it",
  "Close the loop",
  "Double-check meds. Every time.",
  "Busy is not the same as productive",
  "This clinic is the community's front door to care",
  "Make eye contact. Use their name.",
  "An empty room is a waiting patient",
  "Ask for help early, not late",
  "If it isn't written down, it didn't happen",
  "Right patient. Right chart. Every time.",
  "One patient at a time",
  "You make this place work",
  "A warm hello changes the whole visit",
  "Check out right away. The board depends on it.",
  "Offer help before you're asked",
  "Over-communicate when it's busy",
  "Do the little things right",
  "Stay calm. Stay kind. Stay fast.",
  "Healthy patients, healthy community",
  "Patients remember how you made them feel",
  "Finish what you start before starting something new",
  "Nobody here works alone",
  "Questions are free. Mistakes aren't.",
  "Excellence is a habit, not an event",
  "You set the tone for the room",
  "Thank you for showing up today",
  "Nobody chooses to be sick. Be kind.",
  "Clean room, ready room",
  "Your teammate's rush is your rush",
  "Speak up if something feels off",
  "Own your mistakes. Fix them fast.",
  "Hard days build strong teams",
  "Listen to understand, not to reply",
  "Every minute in the waiting room counts",
  "Thank someone today",
  "Clear is kind",
  "Good enough rarely is",
  "Calm is contagious",
  "The waiting room is part of the visit",
  "Small delays add up. Fix them early.",
  "Assume good intent",
  "Tell the patient how long, then beat it",
  "Be proud of the work you hand off",
  "Solve the problem, not the blame",
  "Explain it like you'd want it explained to you",
  "Prep now saves panic later",
  "A good handoff is a gift to the next person",
  "No surprises for patients or teammates",
  "Consistency builds trust",
  "Progress over perfection",
  "A two-minute update beats a twenty-minute silence",
  "Know your next move before you finish this one",
  "Back each other up",
  "Repeat it back to get it right",
  "Do it right when no one is watching",
  "Bring your best to every room",
  "Small kindness, big difference",
  "Flow beats hustle",
  "Celebrate the small wins",
  "Every task is part of a patient's experience",
  "Patience is part of patient care",
  "Every complaint is a chance to win someone back",
  "Fast feels rushed. Smooth feels cared for.",
  "Leave it better than you found it",
  "Standards are what we do on busy days",
  "Today is a fresh start",
  "Assume the patient is scared, not difficult",
  "If it's on the board, it's real",
  "Make your teammate look good",
  "Follow up like you said you would",
  "Be the calm in the chaos",
  "Ask: is there anything else I can do for you today?",
  "Keep the board honest",
  "One team, one board",
  "Better every day",
  "Grace under pressure",
  "Walk them out like a guest",
  "Stock the room before you need it",
  "Hand off like it matters, because it does",
  "Pride in the details",
  "Energy is a choice",
  "Comfort first. Paperwork second.",
  "Done right beats done twice",
  "Be the reason someone's bad day got better",
  "Look at the board. Who's been waiting longest?",
  "Patients trust us with their worst days",
  "Quiet moment? Get ahead.",
  "Never let a patient wonder what happens next",
  "Don't let the next patient wait on this one's paperwork",
  "Greet everyone who walks in",
  "A strong morning makes a smooth afternoon"
];
window.KIOSK_ROTATE_MINUTES = 5;
KIOSKMSGS

# =============================================
# STEP 3 -- Boot to desktop automatically
# =============================================
echo "Setting boot behaviour..."
sudo raspi-config nonint do_boot_behaviour B4

# =============================================
# STEP 4 -- Display config
# hdmi_force_hotplug stays for firmware detection.
# The KMS driver ignores hdmi_group/hdmi_mode, so 1080p60
# is also forced through cmdline.txt (must stay ONE line).
# =============================================
echo "Configuring HDMI display..."
if grep -q "hdmi_force_hotplug=1" "$BOOTDIR"/config.txt; then
    echo "HDMI config already present, skipping"
else
    sudo tee -a "$BOOTDIR"/config.txt << 'EOF'

[all]
hdmi_force_hotplug=1
hdmi_group=2
hdmi_mode=82
EOF
fi

if grep -q "video=HDMI-A-1" "$BOOTDIR"/cmdline.txt; then
    echo "cmdline video mode already present, skipping"
else
    sudo sed -i '1 s/$/ video=HDMI-A-1:1920x1080@60D/' "$BOOTDIR"/cmdline.txt
fi

# =============================================
# STEP 5 -- Chromium kiosk autostart
# =============================================
echo "Creating Chromium kiosk autostart..."
mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/chromium-kiosk.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Chromium Kiosk
Exec=bash __HOME__/launch-kiosk.sh
X-GNOME-Autostart-enabled=true
EOF

# =============================================
# STEP 6 -- Switch to X11
# Everything below (xdotool, unclutter, xset) needs X11.
# =============================================
echo "Switching to X11..."
sudo raspi-config nonint do_wayland W1

# =============================================
# STEP 7 -- Unclutter and mouse position
# =============================================
echo "Configuring cursor hiding..."
cat > "$HOME/.config/autostart/unclutter.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Unclutter
Exec=bash -c "sleep 6 && export DISPLAY=:0 && eval $(xdotool getdisplaygeometry --shell) && xdotool mousemove $((WIDTH-1)) $((HEIGHT-1)) && unclutter -idle 0.1 -root"
X-GNOME-Autostart-enabled=true
EOF

# =============================================
# STEP 8 -- Disable screensaver and blanking
# =============================================
echo "Disabling screensaver..."
cat > "$HOME/.config/autostart/screensaver-off.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Disable Screensaver
Exec=bash -c "sleep 5 && export DISPLAY=:0 && xset s off && xset -dpms && xset s noblank"
X-GNOME-Autostart-enabled=true
EOF

# =============================================
# STEP 9 -- Hardware watchdog (handled by systemd)
# systemd drives the Pi's hardware watchdog directly. The old
# separate "watchdog" program fights it for the device, so it
# is switched off if present. 60s gives a slow Pi 3B+ room to
# get through heavy moments without a needless hard reset.
# =============================================
echo "Setting up hardware watchdog..."
sudo mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nRuntimeWatchdogSec=60\n' | sudo tee /etc/systemd/system.conf.d/cloudsync-watchdog.conf > /dev/null
if systemctl list-unit-files watchdog.service > /dev/null 2>&1; then
    sudo systemctl disable --now watchdog 2>/dev/null
fi
sudo systemctl daemon-reexec

# =============================================
# STEP 10 -- Journal in RAM only (saves SD card wear)
# Also undoes persistent logging on Pis set up with
# older versions of this script.
# =============================================
echo "Setting journal to RAM only..."
sudo sed -i '/^Storage=persistent/d' /etc/systemd/journald.conf
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=30M\n' | sudo tee /etc/systemd/journald.conf.d/cloudsync.conf > /dev/null
sudo rm -rf /var/log/journal
sudo systemctl restart systemd-journald

# =============================================
# STEP 11 -- Chromium watchdog script
# Only writes to the log when it actually restarts Chromium.
# =============================================
echo "Creating Chromium watchdog script..."
cat > "$HOME/chromium-watchdog.sh" << 'EOF'
#!/bin/bash
export DISPLAY=:0
# cron has no X session; without this Chromium can't open the screen
export XAUTHORITY="__HOME__/.Xauthority"

LOG="__HOME__/watchdog.log"

# Match the actual kiosk process, not this script's own command line
if ! pgrep -f "chromium.*--kiosk" > /dev/null; then
    echo "$(date): Chromium not running -- restarting" >> "$LOG"
    pkill -f "chromium.*--kiosk" 2>/dev/null
    sleep 2
    bash __HOME__/launch-kiosk.sh
fi
EOF
chmod +x "$HOME/chromium-watchdog.sh"

# =============================================
# STEP 12 -- Cron jobs (replace, never append)
# =============================================
echo "Setting up cron jobs..."
sudo systemctl enable --now cron
( crontab -l 2>/dev/null | grep -v 'chromium-watchdog.sh' ; \
  echo "*/5 * * * * $HOME/chromium-watchdog.sh" ) | crontab -
( sudo crontab -l 2>/dev/null | grep -v '/sbin/shutdown -r now' ; \
  echo "0 3 * * * /sbin/shutdown -r now" ) | sudo crontab -

# =============================================
# STEP 13 -- Log rotation
# =============================================
echo "Setting up log rotation..."
sudo tee /etc/logrotate.d/chromium-watchdog << EOF
$HOME/watchdog.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF

# =============================================
# STEP 14 -- Create clinic update helper
# =============================================
echo "Creating clinic update helper..."
cat > "$HOME/update-clinic.sh" << 'EOF'
#!/bin/bash
# CloudSync Clinic Updater
# Usage: bash update-clinic.sh TOKEN ZOOM
#
# 43 INCH TV zoom settings:
#   .88 = 10 rooms
#   1.1 = 7 rooms
#   1.4 = 5 rooms
#
# The message strip takes ~8% of the screen, so a clinic needs
# about one step smaller with it on (Humboldt: 1.0 without, 0.9 with)

CONFIG="__HOME__/cloudsync-kiosk.conf"

if [ "$(findmnt -n -o FSTYPE /)" = "overlay" ]; then
    echo "This Pi is in read-only mode. A change made now would be lost at reboot."
    echo "  1) bash ~/kiosk-unlock.sh               (reboots)"
    echo "  2) bash ~/update-clinic.sh TOKEN ZOOM"
    echo "  3) bash ~/kiosk-lock.sh                 (reboots)"
    exit 1
fi

if [ -z "${1:-}" ]; then
    echo "Usage: bash update-clinic.sh TOKEN ZOOM"
    echo "Example: bash update-clinic.sh myTokenHere .88"
    echo ""
    echo "Current config:"
    cat "$CONFIG" 2>/dev/null || echo "(no config file yet)"
    exit 1
fi

TOKEN=$1
ZOOM=${2:-1.5}

cat > "$CONFIG" << CONF
# CloudSync Kiosk Configuration
# Updated: $(date)

TOKEN=${TOKEN}
ZOOM=${ZOOM}
CONF

echo "Config updated:"
cat "$CONFIG"
echo ""
echo "Next: bash ~/kiosk-lock.sh   (locks read-only and reboots)"
EOF
chmod +x "$HOME/update-clinic.sh"

# =============================================
# STEP 14b -- Read-only lock / unlock helpers
# Locked: the SD card is read-only and every write goes to RAM,
# so power loss, hard resets and card wear stop mattering.
# Both helpers reboot, because the switch takes effect at boot.
# =============================================
echo "Creating read-only lock and unlock helpers..."
cat > "$HOME/kiosk-lock.sh" << 'EOF'
#!/bin/bash
# Turns read-only mode ON, then reboots.
if [ "$(findmnt -n -o FSTYPE /)" = "overlay" ]; then
    echo "Already locked (read-only)."
    exit 0
fi
echo "Turning on read-only mode (this can take a minute)..."
if ! sudo raspi-config nonint do_overlayfs 0; then
    echo "Could not turn on read-only mode. Not rebooting."
    exit 1
fi
sudo raspi-config nonint enable_bootro 2>/dev/null || echo "Boot partition left writable on this OS version."
echo "Locked. Rebooting in 10 seconds (Ctrl+C to cancel)..."
sleep 10
sudo reboot
EOF
chmod +x "$HOME/kiosk-lock.sh"

cat > "$HOME/kiosk-unlock.sh" << 'EOF'
#!/bin/bash
# Turns read-only mode OFF, then reboots so changes can be saved.
if [ "$(findmnt -n -o FSTYPE /)" != "overlay" ]; then
    echo "Already unlocked. Make your changes, then run: bash ~/kiosk-lock.sh"
    exit 0
fi
echo "Turning off read-only mode..."
sudo raspi-config nonint disable_bootro 2>/dev/null
if ! sudo raspi-config nonint do_overlayfs 1; then
    echo "Could not turn off read-only mode. Not rebooting."
    exit 1
fi
echo "Unlocked. After the reboot, make your changes, then run: bash ~/kiosk-lock.sh"
echo "Rebooting in 10 seconds (Ctrl+C to cancel)..."
sleep 10
sudo reboot
EOF
chmod +x "$HOME/kiosk-unlock.sh"

# =============================================
# STEP 15 -- Resolve the __HOME__ placeholder
# =============================================
echo "Resolving home path in generated files..."
sed -i "s|__HOME__|$HOME|g" \
    "$HOME/launch-kiosk.sh" \
    "$HOME/chromium-watchdog.sh" \
    "$HOME/update-clinic.sh" \
    "$HOME/.config/autostart/chromium-kiosk.desktop"

# =============================================
# VERIFICATION
# =============================================
echo ""
echo "=== Setup Complete ==="
echo ""
echo "--- Files in home ---"
ls -la "$HOME" | grep -E 'clinic|kiosk|watchdog'
echo ""
echo "--- Message Strip (expect kiosk.html and messages.js) ---"
ls -la "$HOME/kiosk"
echo ""
echo "--- Config File ---"
cat "$HOME/cloudsync-kiosk.conf"
echo ""
echo "--- Chromium Kiosk Autostart ---"
cat "$HOME/.config/autostart/chromium-kiosk.desktop"
echo ""
echo "--- User Cron Jobs (expect ONE watchdog line) ---"
crontab -l
echo ""
echo "--- Root Cron Jobs (expect ONE shutdown line) ---"
sudo crontab -l
echo ""
echo "--- Hardware Watchdog (expect 1min) ---"
systemctl show -p RuntimeWatchdogUSec
echo ""
echo "--- Auto Updates (expect masked or disabled) ---"
systemctl is-enabled apt-daily-upgrade.timer apt-daily.timer 2>/dev/null
echo ""
echo "--- Journal (expect Storage=volatile) ---"
cat /etc/systemd/journald.conf.d/cloudsync.conf
echo ""
echo "--- HDMI Config (expect ONE block) ---"
grep -n hdmi "$BOOTDIR"/config.txt
echo ""
echo "--- cmdline.txt (expect ONE video= entry, single line) ---"
cat "$BOOTDIR"/cmdline.txt
echo ""
echo "--- Power (expect throttled=0x0) ---"
if command -v vcgencmd > /dev/null; then
    THROTTLED=$(vcgencmd get_throttled)
    echo "$THROTTLED"
    if [ "$THROTTLED" != "throttled=0x0" ]; then
        echo "!!! WARNING: this Pi has had low power since boot."
        echo "!!! Use an official 5V 2.5A Pi power supply, not a TV USB port."
        echo "!!! Low power corrupts SD cards."
    fi
else
    echo "vcgencmd not found, could not check power"
fi
echo ""
if [ -n "$ARG_TOKEN" ]; then
    echo "Setting clinic token..."
    bash "$HOME/update-clinic.sh" "$ARG_TOKEN" "$ARG_ZOOM"
    echo ""
    # Locks read-only and reboots
    bash "$HOME/kiosk-lock.sh"
else
    echo "================================================"
    echo "NEXT: set the clinic token, then lock and reboot"
    echo "  bash ~/update-clinic.sh YOUR_TOKEN_HERE .88"
    echo "  bash ~/kiosk-lock.sh"
    echo "================================================"
fi

}

main "$@"
