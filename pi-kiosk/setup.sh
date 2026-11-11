#!/bin/bash
# CloudSync Raspberry Pi Kiosk Setup Script v3.5
# Works on Raspberry Pi OS 64-bit (desktop) and 32-bit Legacy.
# Identical script for every clinic deployment.
# Safe to run more than once on the same Pi. Works under any username.
#
# One-command install (sets token, zoom, then reboots):
#   curl -fsSL <SCRIPT_URL> | bash -s -- TOKEN ZOOM
# Or from a local copy:
#   bash cloudsync-pi-setup.sh TOKEN ZOOM
# Without arguments it sets everything up but leaves the token
# alone and does not reboot.
#
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

# Newer images use /boot/firmware, older ones use /boot
if [ -f /boot/firmware/config.txt ]; then
    BOOTDIR=/boot/firmware
else
    BOOTDIR=/boot
fi

echo "=== CloudSync Kiosk Setup v3.5 Starting ==="
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
# After editing run: sudo reboot

TOKEN=UNCONFIGURED
ZOOM=1.5
EOF
    echo "Config created at $HOME/cloudsync-kiosk.conf (token not yet set)"
fi

# =============================================
# STEP 2 -- Create kiosk launcher script
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

URL="https://go.mycloudsync.app/kiosk/room-board/${TOKEN}"

echo "$(date): Launching $BROWSER with token ${TOKEN:0:8}..." >> "$LOG"

DISPLAY=:0 $BROWSER \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --no-first-run \
    --ozone-platform=x11 \
    --password-store=basic \
    --force-device-scale-factor=${ZOOM} \
    "${URL}" &
EOF
chmod +x "$HOME/launch-kiosk.sh"

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
# is switched off if present and systemd's timer is set to 15s.
# =============================================
echo "Setting up hardware watchdog..."
sudo mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nRuntimeWatchdogSec=15\n' | sudo tee /etc/systemd/system.conf.d/cloudsync-watchdog.conf > /dev/null
if systemctl list-unit-files watchdog.service > /dev/null 2>&1; then
    sudo systemctl disable --now watchdog 2>/dev/null
fi
sudo systemctl daemon-reexec

# =============================================
# STEP 10 -- Persistent journal logging (guarded)
# =============================================
echo "Enabling persistent journal logging..."
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
if grep -q "^Storage=persistent" /etc/systemd/journald.conf; then
    echo "Journal persistence already set, skipping"
else
    echo "Storage=persistent" | sudo tee -a /etc/systemd/journald.conf
fi
sudo systemctl restart systemd-journald

# =============================================
# STEP 11 -- Chromium watchdog script
# =============================================
echo "Creating Chromium watchdog script..."
cat > "$HOME/chromium-watchdog.sh" << 'EOF'
#!/bin/bash
export DISPLAY=:0
# cron has no X session; without this Chromium can't open the screen
export XAUTHORITY="__HOME__/.Xauthority"

LOG="__HOME__/watchdog.log"

# Match the actual kiosk process, not this script's own command line
if pgrep -f "chromium.*--kiosk" > /dev/null; then
    echo "$(date): Chromium OK" >> "$LOG"
else
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

CONFIG="__HOME__/cloudsync-kiosk.conf"

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
echo "Reboot to apply: sudo reboot"
EOF
chmod +x "$HOME/update-clinic.sh"

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
echo "--- Hardware Watchdog (expect 15s) ---"
systemctl show -p RuntimeWatchdogUSec
echo ""
echo "--- HDMI Config (expect ONE block) ---"
grep -n hdmi "$BOOTDIR"/config.txt
echo ""
echo "--- cmdline.txt (expect ONE video= entry, single line) ---"
cat "$BOOTDIR"/cmdline.txt
echo ""
if [ -n "$ARG_TOKEN" ]; then
    echo "Setting clinic token..."
    bash "$HOME/update-clinic.sh" "$ARG_TOKEN" "$ARG_ZOOM"
    echo ""
    echo "Rebooting in 10 seconds (Ctrl+C to cancel)..."
    sleep 10
    sudo reboot
else
    echo "================================================"
    echo "NEXT: set the clinic token"
    echo "  bash ~/update-clinic.sh YOUR_TOKEN_HERE .88"
    echo "  sudo reboot"
    echo "================================================"
fi

}

main "$@"
