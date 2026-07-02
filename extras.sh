#!/bin/bash
# =============================================================================
# VPS Security Extras v1.0
# Companion to vps-hardening v5.0
# Supports: Ubuntu 20.04, 22.04, 24.04
# Usage: sudo ./extras.sh [--no-color] [--dry-run] [--verbose]
# =============================================================================

set -euo pipefail

# =============================================================================
# VERSION & PATHS
# =============================================================================

EXTRAS_VERSION="1.0.0"
VPS_STATE_DIR="/var/lib/vps-hardening"
VPS_LOG_DIR="/var/log/vps-hardening"
EXTRAS_LOG="${VPS_LOG_DIR}/extras.log"
EXTRAS_STATE="${VPS_STATE_DIR}/extras-state"

# =============================================================================
# CLI FLAGS
# =============================================================================

NO_COLOR=${NO_COLOR:-0}
DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-color) NO_COLOR=1 ;;
        --dry-run)  DRY_RUN=true ;;
        --verbose)  VERBOSE=true ;;
        --help|-h)
            echo "Usage: sudo ./extras.sh [--no-color] [--dry-run] [--verbose]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# =============================================================================
# COLORS
# =============================================================================

if [[ -t 1 ]] && [[ "$NO_COLOR" != "1" ]] && [[ "${TERM:-}" != "dumb" ]]; then
    _COLOR=1
else
    _COLOR=0
fi

_c() { [[ "$_COLOR" -eq 1 ]] && echo -ne "\033[${1}m" || true; }

RED="$(_c '0;31')"    YELLOW="$(_c '1;33')"  GREEN="$(_c '0;32')"
BLUE="$(_c '0;34')"   CYAN="$(_c '0;36')"    MAGENTA="$(_c '0;35')"
WHITE="$(_c '1;37')"  BOLD="$(_c '1')"        DIM="$(_c '2')"
ITALIC="$(_c '3')"    NC="$(_c '0')"

SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

# =============================================================================
# LOGGING
# =============================================================================

mkdir -p "$VPS_LOG_DIR" "$VPS_STATE_DIR"
chmod 700 "$VPS_STATE_DIR"

[[ -f "$EXTRAS_LOG" ]] && \
    mv "$EXTRAS_LOG" "${EXTRAS_LOG}.$(date +%Y%m%d-%H%M%S)"

exec > >(tee -a "$EXTRAS_LOG") 2>&1

_log_raw() {
    local LEVEL="$1" MSG="$2"
    echo "$(date '+%Y-%m-%dT%H:%M:%S') [${LEVEL}] ${MSG}" \
        >> "$EXTRAS_LOG" 2>/dev/null || true
}

log_ok()      { echo -e "  ${GREEN}✓${NC}  $1"; _log_raw "OK"    "$1"; }
log_warn()    { echo -e "  ${YELLOW}⚠${NC}  $1"; _log_raw "WARN"  "$1"; }
log_error()   { echo -e "  ${RED}✗${NC}  $1" >&2; _log_raw "ERROR" "$1"; }
log_info()    { echo -e "  ${BLUE}ℹ${NC}  $1"; _log_raw "INFO"  "$1"; }
log_step()    { echo -e "  ${CYAN}→${NC}  $1"; _log_raw "STEP"  "$1"; }
log_tip()     { echo -e "  ${MAGENTA}💡${NC} $1"; _log_raw "TIP"   "$1"; }
log_verbose() { [[ "$VERBOSE" == "true" ]] && echo -e "  ${DIM}   $1${NC}" || true; }

die() {
    log_error "${1:-Fatal error}"
    exit "${2:-1}"
}

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

extras_set() {
    local KEY="$1" VAL="$2"
    local TMP; TMP=$(mktemp)
    grep -v "^${KEY}=" "$EXTRAS_STATE" 2>/dev/null > "$TMP" || true
    echo "${KEY}=${VAL}" >> "$TMP"
    mv "$TMP" "$EXTRAS_STATE"
    chmod 600 "$EXTRAS_STATE"
}

extras_get() {
    grep "^${1}=" "$EXTRAS_STATE" 2>/dev/null | tail -1 | cut -d= -f2-
}

extras_done()     { extras_set "mod_${1}" "done"; }
extras_complete() { [[ "$(extras_get "mod_${1}")" == "done" ]]; }

# =============================================================================
# SPINNER / RUN_SILENT
# =============================================================================

spin() {
    local MSG="$1" PID="$2" EXIT_FILE="$3"
    local i=0 LEN=${#SPINNER_CHARS}
    if [[ "$_COLOR" -eq 1 ]]; then
        echo -ne "  ${CYAN}${SPINNER_CHARS:0:1}${NC}  $MSG"
        while kill -0 "$PID" 2>/dev/null; do
            i=$(( (i+1) % LEN ))
            echo -ne "\r  ${CYAN}${SPINNER_CHARS:$i:1}${NC}  $MSG"
            sleep 0.1
        done
        echo -ne "\r"
    else
        echo -n "  …  $MSG"
    fi
    wait "$PID" 2>/dev/null || true
    local CODE; CODE=$(cat "$EXIT_FILE" 2>/dev/null || echo 1)
    if [[ "$CODE" -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC}  $MSG"
        _log_raw "OK" "$MSG"
    else
        echo -e "  ${RED}✗${NC}  $MSG ${DIM}(see $EXTRAS_LOG)${NC}"
        _log_raw "FAIL" "$MSG"
    fi
    return "$CODE"
}

run_silent() {
    local MSG="$1"; shift
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN]${NC}  $MSG"
        return 0
    fi
    local EXIT_FILE STDERR_FILE
    EXIT_FILE=$(mktemp); STDERR_FILE=$(mktemp)
    ( DEBIAN_FRONTEND=noninteractive "$@" \
        > /dev/null 2>"$STDERR_FILE"
      echo $? > "$EXIT_FILE" ) &
    local PID=$!
    spin "$MSG" "$PID" "$EXIT_FILE"
    local CODE=$?
    if [[ "$CODE" -ne 0 ]]; then
        echo "--- stderr: $* ---" >> "$EXTRAS_LOG"
        cat "$STDERR_FILE"        >> "$EXTRAS_LOG"
        echo "--- end ---"        >> "$EXTRAS_LOG"
    fi
    rm -f "$EXIT_FILE" "$STDERR_FILE"
    return "$CODE"
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "$@" > /dev/null 2>&1
}

policy_block()  { echo "exit 101" > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d; }
policy_allow()  { rm -f /usr/sbin/policy-rc.d; }

service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

wait_for_service() {
    local SVC="$1" MAX="${2:-20}" E=0
    while ! service_active "$SVC"; do
        sleep 1; E=$((E+1))
        [[ "$E" -ge "$MAX" ]] && return 1
    done
}

get_public_ip() {
    local IP
    for EP in "https://ifconfig.me" "https://icanhazip.com" "https://api.ipify.org"; do
        IP=$(curl -s --max-time 5 "$EP" 2>/dev/null) || continue
        [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$IP"; return; }
    done
    echo "YOUR_SERVER_IP"
}

# =============================================================================
# PRECONDITIONS
# =============================================================================

[[ $EUID -ne 0 ]] && die "Root required. Run: sudo ./extras.sh"

OS_ID=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
OS_VERSION=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')

CURRENT_USER="${SUDO_USER:-root}"
[[ -z "$CURRENT_USER" ]] && CURRENT_USER="root"
PUBLIC_IP=$(get_public_ip)

# Try to inherit config from harden.sh state
HARDEN_STATE="${VPS_STATE_DIR}/state"
ADMIN_USER=""
SSH_PORT="22"
HOSTNAME_VAL=""
if [[ -f "$HARDEN_STATE" ]]; then
    ADMIN_USER=$(grep "^ADMIN_USER=" "$HARDEN_STATE" 2>/dev/null | cut -d= -f2 || true)
    SSH_PORT=$(grep   "^SSH_PORT="   "$HARDEN_STATE" 2>/dev/null | cut -d= -f2 || echo "22")
    HOSTNAME_VAL=$(grep "^HOSTNAME=" "$HARDEN_STATE" 2>/dev/null | cut -d= -f2 || true)
fi
[[ -z "$ADMIN_USER" ]] && ADMIN_USER="$CURRENT_USER"
[[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL=$(hostname -s)

# =============================================================================
# UI HELPERS
# =============================================================================

print_banner() {
    clear
    echo ""
    if [[ "$_COLOR" -eq 1 ]]; then
        echo -e "\033[0;35m"
        echo "  ╔══════════════════════════════════════════════════════════╗"
        echo "  ║                                                          ║"
        echo "  ║   \033[1;37m🔒  VPS SECURITY EXTRAS  v${EXTRAS_VERSION}\033[0;35m                  ║"
        echo "  ║   \033[2m    Companion to vps-hardening v5.0\033[0;35m                   ║"
        echo "  ║                                                          ║"
        echo "  ╚══════════════════════════════════════════════════════════╝"
        echo -e "\033[0m"
    else
        echo "  ╔══════════════════════════════════════════════════════════╗"
        echo "  ║   VPS SECURITY EXTRAS v${EXTRAS_VERSION}                        ║"
        echo "  ╚══════════════════════════════════════════════════════════╝"
    fi
    [[ "$DRY_RUN" == "true" ]] && echo -e "  ${YELLOW}⚠  DRY-RUN MODE — no changes${NC}"
    echo ""
}

print_section() {
    local TITLE="$1" DESC="${2:-}"
    echo ""
    echo -e "  ${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}${WHITE}  $TITLE${NC}"
    [[ -n "$DESC" ]] && echo -e "  ${DIM}  $DESC${NC}"
    echo -e "  ${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_box() {
    local TITLE="$1" COLOR="${2:-$YELLOW}"
    echo ""
    echo -e "  ${BOLD}${COLOR}┌──────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${BOLD}${COLOR}│${NC}  ${BOLD}$TITLE"
    echo -e "  ${BOLD}${COLOR}└──────────────────────────────────────────────────────┘${NC}"
    echo ""
}

print_divider() {
    echo ""
    echo -e "  ${DIM}┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈${NC}"
    echo ""
}

print_code() {
    # Print a command block with indentation
    echo ""
    while IFS= read -r line; do
        echo -e "    ${CYAN}$line${NC}"
    done <<< "$1"
    echo ""
}

pause() {
    echo ""
    echo -ne "  ${DIM}Press ENTER to continue ▶${NC} "
    read -r
}

ask_yes() {
    # ask_yes "Question" → returns 0 for yes, 1 for no
    local PROMPT="$1"
    local ANSWER
    echo -ne "  ${YELLOW}?${NC}  $PROMPT ${DIM}(yes/no)${NC}: "
    read -r ANSWER
    [[ "${ANSWER,,}" == "yes" || "${ANSWER,,}" == "y" ]]
}

badge() {
    local LABEL="$1" TEXT="$2" COLOR="${3:-$CYAN}"
    echo -e "    ${COLOR}${BOLD}[${LABEL}]${NC} $TEXT"
}

impact_bar() {
    # impact_bar HIGH|MED|LOW "label"
    local LEVEL="$1" TEXT="$2"
    case "$LEVEL" in
        HIGH) echo -e "  ${RED}${BOLD}▐███████░░░${NC} ${BOLD}$TEXT${NC}" ;;
        MED)  echo -e "  ${YELLOW}${BOLD}▐█████░░░░░${NC} ${BOLD}$TEXT${NC}" ;;
        LOW)  echo -e "  ${GREEN}${BOLD}▐███░░░░░░░${NC} ${BOLD}$TEXT${NC}" ;;
    esac
}

time_badge() {
    echo -e "    ${DIM}⏱  Estimated time: ${BOLD}$1${NC}"
}

# =============================================================================
# MODULE SELECTION MENU
# =============================================================================

declare -A SELECTED
declare -A MOD_LABELS

MOD_LABELS=(
    [01]="Two-Factor Authentication (TOTP)"
    [02]="WireGuard VPN"
    [03]="AIDE File Integrity (full system)"
    [04]="Prometheus + Grafana Monitoring"
    [05]="rkhunter + chkrootkit Rootkit Detection"
    [06]="Restic Encrypted Backups"
    [07]="Lynis Security Audit"
    [08]="Nginx / Caddy Security Headers"
    [09]="Systemd Service Hardening"
    [10]="GeoIP + ASN Blocking"
    [11]="Service User Isolation"
    [12]="ClamAV Malware Scanner"
)

ORDERED_KEYS=(01 02 03 04 05 06 07 08 09 10 11 12)

for K in "${ORDERED_KEYS[@]}"; do SELECTED[$K]=false; done

show_menu() {
    clear
    print_banner

    echo -e "  ${BOLD}${WHITE}Select modules to install:${NC}"
    echo -e "  ${DIM}Type numbers separated by spaces, or 'all', then press ENTER${NC}"
    echo -e "  ${DIM}Example:  1 2 5   or   all${NC}"
    echo ""

    echo -e "  ${BOLD}${CYAN}  TIER 1 — Highest Security Impact${NC}"
    echo ""
    echo -e "  ${RED}  ▌${NC} ${BOLD}1${NC}  ${MOD_LABELS[01]}"
    echo -e "        ${DIM}3FA: key + passphrase + phone. Leaked keys become useless.${NC}"
    echo -e "        ${DIM}⏱ 30 min   Impact: ████████████ CRITICAL${NC}"
    echo ""
    echo -e "  ${RED}  ▌${NC} ${BOLD}2${NC}  ${MOD_LABELS[02]}"
    echo -e "        ${DIM}SSH disappears from the internet. Only VPN peers can reach it.${NC}"
    echo -e "        ${DIM}⏱ 45 min   Impact: ████████████ CRITICAL${NC}"
    echo ""
    echo -e "  ${RED}  ▌${NC} ${BOLD}3${NC}  ${MOD_LABELS[03]}"
    echo -e "        ${DIM}Cryptographic fingerprint of entire filesystem. Detects rootkits.${NC}"
    echo -e "        ${DIM}⏱ 15 min (+10 min baseline)   Impact: ██████████ HIGH${NC}"
    echo ""

    echo -e "  ${BOLD}${YELLOW}  TIER 2 — Strong Operational Security${NC}"
    echo ""
    echo -e "  ${YELLOW}  ▌${NC} ${BOLD}4${NC}  ${MOD_LABELS[04]}"
    echo -e "        ${DIM}Grafana dashboards: CPU, disk, SSH fails, bans — real-time.${NC}"
    echo -e "        ${DIM}⏱ 20 min   Impact: ████████ HIGH (visibility)${NC}"
    echo ""
    echo -e "  ${YELLOW}  ▌${NC} ${BOLD}5${NC}  ${MOD_LABELS[05]}"
    echo -e "        ${DIM}Two independent rootkit scanners. Daily automated scans.${NC}"
    echo -e "        ${DIM}⏱ 10 min   Impact: ███████ HIGH${NC}"
    echo ""
    echo -e "  ${YELLOW}  ▌${NC} ${BOLD}6${NC}  ${MOD_LABELS[06]}"
    echo -e "        ${DIM}Client-side encrypted backups to cloud. Deduped + versioned.${NC}"
    echo -e "        ${DIM}⏱ 30 min   Impact: ██████████ CRITICAL (disaster recovery)${NC}"
    echo ""
    echo -e "  ${YELLOW}  ▌${NC} ${BOLD}7${NC}  ${MOD_LABELS[07]}"
    echo -e "        ${DIM}200+ item automated security audit. Hardening score + fixes.${NC}"
    echo -e "        ${DIM}⏱ 5 min    Impact: ██████ MED (find gaps)${NC}"
    echo ""

    echo -e "  ${BOLD}${GREEN}  TIER 3 — Operational Excellence${NC}"
    echo ""
    echo -e "  ${GREEN}  ▌${NC} ${BOLD}8${NC}  ${MOD_LABELS[08]}"
    echo -e "        ${DIM}HSTS, CSP, X-Frame, nosniff, Referrer-Policy + A+ rating.${NC}"
    echo -e "        ${DIM}⏱ 10 min   Impact: █████ MED (web security)${NC}"
    echo ""
    echo -e "  ${GREEN}  ▌${NC} ${BOLD}9${NC}  ${MOD_LABELS[09]}"
    echo -e "        ${DIM}systemd sandboxing: PrivateTmp, NoNewPrivileges, ProtectSystem.${NC}"
    echo -e "        ${DIM}⏱ 15 min   Impact: ██████ MED (blast radius reduction)${NC}"
    echo ""
    echo -e "  ${GREEN}  ▌${NC} ${BOLD}10${NC} ${MOD_LABELS[10]}"
    echo -e "        ${DIM}Block high-attack-volume countries/ASNs at kernel level.${NC}"
    echo -e "        ${DIM}⏱ 20 min   Impact: █████ MED (noise reduction)${NC}"
    echo ""
    echo -e "  ${GREEN}  ▌${NC} ${BOLD}11${NC} ${MOD_LABELS[11]}"
    echo -e "        ${DIM}One system user per service. Breach blast radius contained.${NC}"
    echo -e "        ${DIM}⏱ 15 min   Impact: █████ MED (containment)${NC}"
    echo ""
    echo -e "  ${GREEN}  ▌${NC} ${BOLD}12${NC} ${MOD_LABELS[12]}"
    echo -e "        ${DIM}Daily malware, web shell, and miner detection.${NC}"
    echo -e "        ${DIM}⏱ 10 min   Impact: ████ MED${NC}"
    echo ""

    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -rp "  Your selection: " RAW_SELECTION
    echo ""

    if [[ "${RAW_SELECTION,,}" == "all" ]]; then
        for K in "${ORDERED_KEYS[@]}"; do SELECTED[$K]=true; done
        return
    fi

    for TOKEN in $RAW_SELECTION; do
        # Normalize: 1 → 01, 2 → 02 etc
        local PADDED
        printf -v PADDED "%02d" "$TOKEN" 2>/dev/null || continue
        if [[ -n "${SELECTED[$PADDED]+x}" ]]; then
            SELECTED[$PADDED]=true
        fi
    done
}

confirm_selection() {
    echo -e "  ${BOLD}${CYAN}Selected modules:${NC}"
    echo ""
    local ANY=false
    for K in "${ORDERED_KEYS[@]}"; do
        if [[ "${SELECTED[$K]}" == "true" ]]; then
            echo -e "    ${GREEN}✓${NC}  ${MOD_LABELS[$K]}"
            ANY=true
        fi
    done
    if [[ "$ANY" == "false" ]]; then
        log_warn "Nothing selected — exiting."
        exit 0
    fi
    echo ""
    if ! ask_yes "Proceed with installation?"; then
        log_warn "Aborted."
        exit 0
    fi
}

# =============================================================================
# MODULE 01 — TOTP / 2FA
# =============================================================================

mod_01_totp() {
    print_section "Module 01" "Two-Factor Authentication (TOTP)"

    if extras_complete "01"; then
        log_ok "TOTP already installed — skipping"
        return 0
    fi

    echo -e "  ${BOLD}What this does:${NC}"
    echo ""
    impact_bar HIGH "CRITICAL — Even a stolen key cannot log in without your phone"
    echo ""
    echo -e "  Login will require ${BOLD}ALL THREE${NC}:"
    echo ""
    badge "HAVE"  "Your private key file"
    badge "KNOW"  "Your key passphrase"
    badge "OWN"   "Your phone (Google Authenticator / Authy / 1Password)"
    echo ""
    time_badge "30 minutes"
    echo ""

    echo -e "  ${BOLD}How it works:${NC}"
    echo -e "  ${DIM}  libpam-google-authenticator generates a shared secret.${NC}"
    echo -e "  ${DIM}  You scan the QR code with your phone once.${NC}"
    echo -e "  ${DIM}  Every login, SSH prompts for the 6-digit rolling code.${NC}"
    echo ""

    print_box "REQUIREMENTS" "$CYAN"
    echo -e "  ${DIM}• Auth type must be SSH key (not password-only)${NC}"
    echo -e "  ${DIM}• You need a TOTP app on your phone before proceeding${NC}"
    echo -e "  ${DIM}• Run google-authenticator as your ADMIN USER, not root${NC}"
    echo ""
    echo -e "  ${BOLD}TOTP apps:${NC}"
    badge "iOS"     "Authy, Google Authenticator, 1Password, Raivo"
    badge "Android" "Authy, Google Authenticator, Aegis"
    echo ""

    if ! ask_yes "Do you have a TOTP app installed on your phone?"; then
        log_warn "Install a TOTP app first, then re-run."
        return 1
    fi

    print_divider
    echo -e "  ${BOLD}Step 1 of 4 — Install package${NC}"
    echo ""

    run_silent "Updating apt cache" bash -c 'apt-get update -qq'
    run_silent "Installing libpam-google-authenticator" \
        bash -c 'apt-get install -y -qq libpam-google-authenticator'

    log_ok "libpam-google-authenticator installed"

    print_divider
    echo -e "  ${BOLD}Step 2 of 4 — Configure PAM${NC}"
    echo ""
    echo -e "  ${DIM}Backing up /etc/pam.d/sshd${NC}"

    if [[ "$DRY_RUN" != "true" ]]; then
        cp /etc/pam.d/sshd /etc/pam.d/sshd.backup.extras
        # Prepend google-authenticator to PAM SSH stack
        if ! grep -q "pam_google_authenticator" /etc/pam.d/sshd; then
            sed -i '1s/^/auth required pam_google_authenticator.so nullok\n/' \
                /etc/pam.d/sshd
        fi
        log_ok "PAM /etc/pam.d/sshd updated"
    else
        echo -e "  ${DIM}[DRY-RUN] Would prepend pam_google_authenticator to /etc/pam.d/sshd${NC}"
    fi

    print_divider
    echo -e "  ${BOLD}Step 3 of 4 — Update SSH config${NC}"
    echo ""

    local SSH_CONF="/etc/ssh/sshd_config.d/99-hardened.conf"
    [[ ! -f "$SSH_CONF" ]] && SSH_CONF="/etc/ssh/sshd_config"

    if [[ "$DRY_RUN" != "true" ]]; then
        # Remove old AuthenticationMethods line and add updated one
        sed -i '/^AuthenticationMethods/d' "$SSH_CONF"
        sed -i '/^KbdInteractiveAuthentication/d' "$SSH_CONF"
        sed -i '/^ChallengeResponseAuthentication/d' "$SSH_CONF"
        sed -i '/^UsePAM/d' "$SSH_CONF"

        cat >> "$SSH_CONF" << 'EOF'

# TOTP 2FA — added by vps-security-extras
AuthenticationMethods publickey,keyboard-interactive
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
UsePAM yes
EOF
        log_ok "SSH config updated for 2FA"

        if ! sshd -t 2>/dev/null; then
            log_error "SSH config error — restoring backup"
            cp /etc/pam.d/sshd.backup.extras /etc/pam.d/sshd
            sed -i \
                '/# TOTP 2FA/,+4d' "$SSH_CONF"
            return 1
        fi
    fi

    print_divider
    echo -e "  ${BOLD}Step 4 of 4 — Generate QR code for your admin user${NC}"
    echo ""
    print_box "CRITICAL — DO THIS NOW" "$RED"
    echo -e "  Run this as ${BOLD}${GREEN}${ADMIN_USER}${NC} (your admin user, NOT root):"
    echo ""
    print_code "su - ${ADMIN_USER} -c 'google-authenticator -t -d -f -r 3 -R 30 -w 3'"
    echo ""
    echo -e "  ${BOLD}When prompted:${NC}"
    echo -e "    ${CYAN}1)${NC} A QR code will appear in your terminal"
    echo -e "    ${CYAN}2)${NC} Open your TOTP app → Add account → Scan QR code"
    echo -e "    ${CYAN}3)${NC} Answer: yes, yes, no, yes to the questions"
    echo -e "    ${CYAN}4)${NC} Save the emergency scratch codes somewhere safe!"
    echo ""
    echo -e "  ${DIM}Emergency scratch codes let you in if you lose your phone.${NC}"
    echo -e "  ${DIM}Store them in a password manager or print them offline.${NC}"
    echo ""

    if ask_yes "Open another terminal and run google-authenticator as ${ADMIN_USER} now?"; then
        echo ""
        echo -e "  Switching to ${BOLD}${ADMIN_USER}${NC} to run google-authenticator..."
        echo ""
        if [[ "$DRY_RUN" != "true" ]]; then
            su - "$ADMIN_USER" -c 'google-authenticator -t -d -f -r 3 -R 30 -w 3' \
                || log_warn "google-authenticator exited with error — check output above"
        else
            echo -e "  ${DIM}[DRY-RUN] Would run google-authenticator as $ADMIN_USER${NC}"
        fi
    fi

    print_box "TEST BEFORE RESTARTING SSH" "$YELLOW"
    echo -e "  Open a NEW terminal and test login with 2FA:"
    print_code "ssh -p ${SSH_PORT} ${ADMIN_USER}@${PUBLIC_IP}"
    echo -e "  You should be prompted for the 6-digit code AFTER the key."
    echo ""
    echo -e "  ${RED}Keep THIS session open until test succeeds!${NC}"
    echo ""

    if ask_yes "2FA test login succeeded?"; then
        if [[ "$DRY_RUN" != "true" ]]; then
            run_silent "Restarting SSH" systemctl restart ssh
        fi
        log_ok "TOTP 2FA is active — three-factor authentication enabled"
        log_tip "If you lose your phone: use an emergency scratch code to log in"
        extras_done "01"
    else
        log_warn "2FA test failed. SSH NOT restarted — current config preserved."
        log_info "Check: journalctl -u ssh -n 30"
        log_info "Revert PAM: cp /etc/pam.d/sshd.backup.extras /etc/pam.d/sshd"
    fi
}

# =============================================================================
# MODULE 02 — WIREGUARD VPN
# =============================================================================

mod_02_wireguard() {
    print_section "Module 02" "WireGuard VPN"

    if extras_complete "02"; then
        log_ok "WireGuard already installed — skipping"
        return 0
    fi

    echo -e "  ${BOLD}What this does:${NC}"
    echo ""
    impact_bar HIGH "CRITICAL — SSH becomes invisible to the entire internet"
    echo ""
    echo -e "  ${BOLD}Attack surface change:${NC}"
    echo ""
    echo -e "    ${RED}Before:${NC}  4,294,967,296 IPs can reach your SSH port"
    echo -e "    ${GREEN}After:${NC}   Only your WireGuard peers can reach SSH"
    echo ""
    echo -e "  ${DIM}Port scanners see nothing. Bots see nothing.${NC}"
    echo -e "  ${DIM}fail2ban becomes almost unnecessary.${NC}"
    echo ""
    echo -e "  ${BOLD}Architecture:${NC}"
    echo -e "    ${CYAN}Your laptop${NC} → WireGuard UDP:51820 → VPS → SSH on ${SSH_PORT}"
    echo ""
    time_badge "45 minutes"
    echo ""

    print_box "REQUIREMENTS" "$CYAN"
    echo -e "  ${DIM}• WireGuard must also be installed on your laptop/desktop${NC}"
    echo -e "  ${DIM}• You need your laptop's WireGuard public key ready${NC}"
    echo -e "  ${DIM}• Port 51820/udp must be allowed in cloud firewall${NC}"
    echo ""

    # Collect config
    print_divider
    echo -e "  ${BOLD}Configuration${NC}"
    echo ""

    read -rp "  WireGuard server IP (VPN internal) [10.0.0.1]: " WG_SERVER_IP
    WG_SERVER_IP="${WG_SERVER_IP:-10.0.0.1}"

    read -rp "  WireGuard peer IP (your laptop) [10.0.0.2]: " WG_CLIENT_IP
    WG_CLIENT_IP="${WG_CLIENT_IP:-10.0.0.2}"

    read -rp "  WireGuard listen port [51820]: " WG_PORT
    WG_PORT="${WG_PORT:-51820}"

    read -rp "  WireGuard interface name [wg0]: " WG_IFACE
    WG_IFACE="${WG_IFACE:-wg0}"

    echo ""
    echo -e "  ${BOLD}Your laptop's WireGuard public key:${NC}"
    echo -e "  ${DIM}Generate on your laptop:${NC}"
    print_code "wg genkey | tee ~/.wireguard/laptop-private.key | wg pubkey > ~/.wireguard/laptop-public.key
cat ~/.wireguard/laptop-public.key"
    echo ""
    read -rp "  Paste laptop public key: " WG_PEER_PUBKEY
    while [[ -z "$WG_PEER_PUBKEY" || ${#WG_PEER_PUBKEY} -lt 40 ]]; do
        log_warn "Public key looks too short — WireGuard keys are 44 base64 chars."
        read -rp "  Paste laptop public key: " WG_PEER_PUBKEY
    done

    print_divider
    echo -e "  ${BOLD}Installing WireGuard${NC}"
    echo ""

    run_silent "Updating apt cache" bash -c 'apt-get update -qq'
    run_silent "Installing wireguard + tools" \
        bash -c 'apt-get install -y -qq wireguard wireguard-tools'

    if [[ "$DRY_RUN" != "true" ]]; then
        # Generate server keys
        mkdir -p /etc/wireguard
        chmod 700 /etc/wireguard

        run_silent "Generating server WireGuard keys" bash -c '
            wg genkey | tee /etc/wireguard/private.key | \
            wg pubkey > /etc/wireguard/public.key
            chmod 600 /etc/wireguard/private.key'

        local WG_PRIV; WG_PRIV=$(cat /etc/wireguard/private.key)
        local WG_PUB;  WG_PUB=$(cat /etc/wireguard/public.key)

        # Detect main network interface
        local MAIN_IF
        MAIN_IF=$(ip route | grep default | awk '{print $5}' | head -1)

        cat > "/etc/wireguard/${WG_IFACE}.conf" << EOF
# WireGuard VPN — vps-security-extras v${EXTRAS_VERSION}
# Generated: $(date)

[Interface]
Address    = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${WG_PRIV}

# Enable IP forwarding for VPN routing
PostUp   = sysctl -w net.ipv4.ip_forward=1
PostDown = sysctl -w net.ipv4.ip_forward=0

# NAT for VPN clients (optional — enables internet access through VPN)
# PostUp   = iptables -t nat -A POSTROUTING -o ${MAIN_IF} -j MASQUERADE
# PostDown = iptables -t nat -D POSTROUTING -o ${MAIN_IF} -j MASQUERADE

[Peer]
# Your laptop
PublicKey  = ${WG_PEER_PUBKEY}
AllowedIPs = ${WG_CLIENT_IP}/32
EOF
        chmod 600 "/etc/wireguard/${WG_IFACE}.conf"
        log_ok "WireGuard server config written"

        # UFW rules
        run_silent "Opening WireGuard port in UFW" \
            bash -c "ufw allow ${WG_PORT}/udp comment 'WireGuard VPN' > /dev/null 2>&1"

        # Lock SSH to WireGuard interface only
        echo ""
        if ask_yes "Lock SSH to WireGuard interface only? (recommended — hides SSH from internet)"; then
            # Remove existing SSH allow rules and re-add for wg0 only
            ufw delete allow "${SSH_PORT}/tcp" > /dev/null 2>&1 || true
            ufw delete limit "${SSH_PORT}/tcp" > /dev/null 2>&1 || true
            ufw allow in on "${WG_IFACE}" to any port "${SSH_PORT}" proto tcp \
                comment "SSH via WireGuard only" > /dev/null 2>&1
            log_ok "SSH locked to ${WG_IFACE} interface — invisible from internet"
            log_warn "You MUST connect via WireGuard to reach SSH after this"
        fi

        # Enable service
        run_silent "Enabling wg-quick@${WG_IFACE}" \
            systemctl enable "wg-quick@${WG_IFACE}"
        run_silent "Starting WireGuard" \
            systemctl start "wg-quick@${WG_IFACE}"

        echo ""
        echo -e "  ${BOLD}Server WireGuard Public Key:${NC}"
        echo -e "    ${CYAN}${WG_PUB}${NC}"
        echo ""
        echo -e "  ${DIM}Copy this — you need it for your laptop config.${NC}"
        echo ""

        # Save server public key for reference
        extras_set "WG_SERVER_PUBKEY" "$WG_PUB"
        extras_set "WG_SERVER_IP"     "$WG_SERVER_IP"
        extras_set "WG_PORT"          "$WG_PORT"
        extras_set "WG_IFACE"         "$WG_IFACE"
    fi

    print_divider
    echo -e "  ${BOLD}Laptop / Client Configuration${NC}"
    echo ""
    echo -e "  Create this file on your ${BOLD}laptop${NC}:"
    echo ""
    echo -e "  ${DIM}~/.wireguard/${WG_IFACE}.conf   (Mac/Linux)${NC}"
    echo -e "  ${DIM}%APPDATA%\\WireGuard\\${WG_IFACE}.conf  (Windows)${NC}"
    echo ""
    if [[ "$DRY_RUN" != "true" ]]; then
        local WG_PUB_SHOW; WG_PUB_SHOW=$(cat /etc/wireguard/public.key 2>/dev/null || echo "YOUR_SERVER_PUBLIC_KEY")
        print_code "[Interface]
Address    = ${WG_CLIENT_IP}/32
PrivateKey = <your-laptop-private-key>
DNS        = 1.1.1.1

[Peer]
PublicKey  = ${WG_PUB_SHOW}
Endpoint   = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = ${WG_SERVER_IP}/32
PersistentKeepalive = 25"
    else
        print_code "[Interface]
Address    = ${WG_CLIENT_IP}/32
PrivateKey = <your-laptop-private-key>
DNS        = 1.1.1.1

[Peer]
PublicKey  = <server-public-key-shown-above>
Endpoint   = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = ${WG_SERVER_IP}/32
PersistentKeepalive = 25"
    fi

    echo -e "  ${BOLD}Start VPN on laptop:${NC}"
    print_code "sudo wg-quick up ${WG_IFACE}
# Verify:
ping ${WG_SERVER_IP}"

    echo ""
    echo -e "  ${BOLD}Once connected, SSH via VPN IP:${NC}"
    print_code "ssh -p ${SSH_PORT} ${ADMIN_USER}@${WG_SERVER_IP}"

    echo ""
    print_box "CLOUD PROVIDER REMINDER" "$YELLOW"
    echo -e "  Open port ${BOLD}${WG_PORT}/UDP${NC} in your cloud firewall:"
    echo -e "  ${DIM}Oracle: VCN → Security List → Ingress → UDP ${WG_PORT}${NC}"
    echo -e "  ${DIM}AWS: Security Group → Inbound → UDP ${WG_PORT}${NC}"
    echo -e "  ${DIM}GCP: VPC → Firewall → Ingress → UDP ${WG_PORT}${NC}"
    echo -e "  ${DIM}Azure: NSG → Inbound → UDP ${WG_PORT}${NC}"
    echo ""

    if [[ "$DRY_RUN" != "true" ]]; then
        extras_done "02"
    fi
    log_ok "WireGuard installed — SSH is now hidden from the internet"
    log_tip "Connect via VPN first, then SSH to ${WG_SERVER_IP}"
}

# =============================================================================
# MODULE 03 — AIDE
# =============================================================================

mod_03_aide() {
    print_section "Module 03" "AIDE File Integrity"

    if extras_complete "03"; then
        log_ok "AIDE already installed — skipping"
        return 0
    fi

    echo -e "  ${BOLD}What this does:${NC}"
    echo ""
    impact_bar HIGH "Cryptographic fingerprint of your entire filesystem"
    echo ""
    echo -e "  ${DIM}Detects rootkits that modify /bin/ls, /bin/ps, /usr/sbin/sshd${NC}"
    echo -e "  ${DIM}Detects backdoors in /etc/cron.d/ or /etc/sudoers${NC}"
    echo -e "  ${DIM}Detects new SUID binaries, tampered kernel modules${NC}"
    echo -e "  ${DIM}Any change to any tracked file triggers an alert${NC}"
    echo ""
    time_badge "15 min install + 10 min baseline build"
    echo ""

    run_silent "Updating apt cache" bash -c 'apt-get update -qq'
    policy_block
    run_silent "Installing AIDE" \
        bash -c 'apt-get install -y -qq aide aide-common'
    policy_allow

    if [[ "$DRY_RUN" != "true" ]]; then
        # Write a hardened AIDE config
        cat > /etc/aide/aide.conf.d/99-vps-hardening.conf << 'EOF'
# VPS Hardening AIDE rules
# Critical system binaries
/bin     CONTENT_EX
/sbin    CONTENT_EX
/usr/bin CONTENT_EX
/usr/sbin CONTENT_EX
/lib     CONTENT_EX
/usr/lib CONTENT_EX
/lib64   CONTENT_EX

# Configuration
/etc     CONTENT_EX

# Boot
/boot    CONTENT_EX

# Exclude noisy paths
!/var/log
!/var/cache
!/var/run
!/var/lib/aide
!/tmp
!/proc
!/sys
!/dev
!/run
!/snap
EOF
        log_ok "AIDE config written"

        echo ""
        log_step "Building AIDE baseline — this takes 5–10 minutes..."
        echo -e "  ${DIM}Hashing every file on your system. Go make a coffee. ☕${NC}"
        echo ""

        if aideinit 2>&1 | tail -5; then
            mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db 2>/dev/null || true
            log_ok "AIDE baseline built"
        else
            log_warn "aideinit returned non-zero — check /var/log/aide/aide.log"
        fi

        # Daily check cron
        cat > /etc/cron.d/vps-aide << 'EOF'
# AIDE daily integrity check — vps-security-extras
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 6 * * * root aide --check >> /var/log/vps-hardening/aide.log 2>&1 && \
    grep -q "changed\|added\|removed" /var/log/vps-hardening/aide.log && \
    logger -t aide -p auth.alert "AIDE: Filesystem changes detected — check /var/log/vps-hardening/aide.log"
EOF
        chmod 644 /etc/cron.d/vps-aide
        log_ok "AIDE daily check: 06:00 via cron"

        # Update helper
        cat > /usr/local/sbin/aide-update << 'EOF'
#!/bin/bash
# Run after intentional system changes to re-baseline AIDE
echo "Updating AIDE database..."
aide --update 2>&1 | tail -5
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
echo "Done. New baseline active."
EOF
        chmod 750 /usr/local/sbin/aide-update
        log_ok "Update helper: /usr/local/sbin/aide-update (run after system changes)"
    fi

    echo ""
    log_tip "After intentional changes (apt upgrade etc), run: sudo aide-update"
    log_tip "Query: sudo aide --check  |  sudo ausearch -k aide (if auditd enabled)"

    extras_done "03"
    log_ok "AIDE installed — full filesystem integrity monitoring active"
}

# =============================================================================
# MODULE 04 — PROMETHEUS + GRAFANA
# =============================================================================

mod_04_monitoring() {
    print_section "Module 04" "Prometheus + Grafana Monitoring"

    if extras_complete "04"; then
        log_ok "Monitoring stack already installed — skipping"
        return 0
    fi

    echo -e "  ${BOLD}What this does:${NC}"
    echo ""
    impact_bar MED "Real-time dashboards: CPU, disk, SSH fails, fail2ban bans"
    echo ""
    echo -e "  ${BOLD}Components:${NC}"
    badge "Prometheus"      "Time-series metrics database"
    badge "Node Exporter"   "System metrics (CPU, disk, network, memory)"
    badge "Grafana"         "Dashboards and alerting UI"
    echo ""
    echo -e "  ${BOLD}Access:${NC} Via SSH tunnel — never exposed to internet"
    echo ""
    time_badge "20 minutes"
    echo ""

    print_box "SECURITY NOTE" "$YELLOW"
    echo -e "  Grafana (3000) and Prometheus (9090) bind to ${BOLD}localhost only${NC}."
    echo -e "  Access via SSH tunnel:"
    print_code "ssh -L 3000:localhost:3000 -L 9090:localhost:9090 -p ${SSH_PORT} ${ADMIN_USER}@${PUBLIC_IP}"
    echo -e "  Then open http://localhost:3000 in your browser."
    echo ""

    local INSTALL_GRAFANA=true
    if ! ask_yes "Install Grafana? (No = Node Exporter + Prometheus only)"; then
        INSTALL_GRAFANA=false
    fi

    run_silent "Updating apt cache" bash -c 'apt-get update -qq'

    # Node Exporter
    run_silent "Installing prometheus-node-exporter" \
        bash -c 'apt-get install -y -qq prometheus-node-exporter'

    if [[ "$DRY_RUN" != "true" ]]; then
        # Bind node exporter to localhost
        mkdir -p /etc/systemd/system/prometheus-node-exporter.service.d
        cat > /etc/systemd/system/prometheus-node-exporter.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/prometheus-node-exporter \
    --web.listen-address="127.0.0.1:9100" \
    --collector.systemd \
    --collector.processes
EOF
        systemctl daemon-reload
        systemctl enable prometheus-node-exporter
        systemctl restart prometheus-node-exporter
        log_ok "Node Exporter: localhost:9100"
    fi

    # Prometheus
    run_silent "Installing prometheus" \
        bash -c 'apt-get install -y -qq prometheus'

    if [[ "$DRY_RUN" != "true" ]]; then
        cat > /etc/prometheus/prometheus.yml << EOF
# Prometheus config — vps-security-extras
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
        labels:
          instance: '${HOSTNAME_VAL}'

  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOF
        # Bind to localhost
        sed -i 's/--web.listen-address=.*/--web.listen-address="127.0.0.1:9090"/' \
            /etc/default/prometheus 2>/dev/null || true

        systemctl enable prometheus
        systemctl restart prometheus
        log_ok "Prometheus: localhost:9090"
    fi

    if [[ "$INSTALL_GRAFANA" == "true" ]]; then
        run_silent "Installing Grafana" \
            bash -c 'apt-get install -y -qq grafana'

        if [[ "$DRY_RUN" != "true" ]]; then
            # Bind Grafana to localhost
            sed -i 's/^;http_addr.*/http_addr = 127.0.0.1/' \
                /etc/grafana/grafana.ini 2>/dev/null || true
            sed -i 's/^http_addr.*/http_addr = 127.0.0.1/' \
                /etc/grafana/grafana.ini 2>/dev/null || true

            systemctl enable grafana-server
            systemctl start grafana-server
            wait_for_service grafana-server 30 || \
                log_warn "Grafana slow to start"
            log_ok "Grafana: localhost:3000 (default login: admin/admin)"
        fi
    fi

    print_divider
    echo -e "  ${BOLD}Recommended Grafana Dashboards${NC} ${DIM}(import by ID)${NC}"
    echo ""
    badge "1860"  "Node Exporter Full — system metrics"
    badge "7587"  "fail2ban metrics"
    badge "9965"  "UFW firewall metrics"
    echo ""
    echo -e "  ${BOLD}Import steps:${NC}"
    echo -e "  ${DIM}  1. Open Grafana → + → Import${NC}"
    echo -e "  ${DIM}  2. Enter dashboard ID → Load${NC}"
    echo -e "  ${DIM}  3. Select Prometheus datasource → Import${NC}"
    echo ""
    echo -e "  ${BOLD}Suggested Alerts to configure:${NC}"
    echo ""
    badge "Disk"    "> 80% → alert"
    badge "Memory"  "> 90% → alert"
    badge "Load"    "> $(nproc) → alert"
    badge "SSH"     "> 100 failures/hr → alert"
    badge "Service" "Down → alert"
    echo ""

    log_ok "Connect: ssh -L 3000:localhost:3000 -p ${SSH_PORT} ${ADMIN_USER}@${PUBLIC_IP}"
    extras_done "04"
}

# =============================================================================
# MODULE 05 — RKHUNTER + CHKROOTKIT
# =============================================================================

mod_05_rkhunter() {
    print_section "Module 05" "rkhunter + chkrootkit Rootkit Detection"

    if extras_complete "05"; then
        log_ok "Rootkit scanners already installed — skipping"
        return 0
    fi

    echo -e "  ${BOLD}What this does:${NC}"
    echo ""
    impact_bar HIGH "Two independent rootkit detection engines — daily automated scans"
    echo ""
    echo -e "  ${BOLD}How they differ:${NC}"
    badge "rkhunter"    "Checks file properties, hidden files, suspicious strings"
    badge "chkrootkit"  "Different detection engine — catches different rootkit families"
    echo ""
    echo -e "  ${DIM}Run both because they catch different things.${NC}"
    echo -e "  ${DIM}False positives are common — learn your baseline.${NC}"
    echo ""
    time_badge "10 minutes"
    echo ""

    run_silent "Updating apt cache" bash -c 'apt-get update -qq'
    run_silent "Installing rkhunter + chkrootkit" \
        bash -c 'apt-get install -y -qq rkhunter chkrootkit'

    if [[ "$DRY_RUN" != "true" ]]; then
        run_silent "Updating rkhunter signature database" \
            bash -c 'rkhunter --update > /dev/null 2>&1 || true'
        run_silent "Setting rkhunter property baseline" \
            bash -c 'rkhunter --propupd > /dev/null 2>&1 || true'

        # rkhunter daily script
        cat > /etc/cron.daily/vps-rkhunter << 'EOF'
#!/bin/bash
LOGFILE="/var/log/vps-hardening/rkhunter.log"
rkhunter --check \
         --skip-keypress \
         --report-warnings-only \
         --logfile "$LOGFILE" 2>/dev/null
# Alert on warnings
WARNS=$(grep -c "Warning" "$LOGFILE" 2>/dev/null || echo 0)
[[ "$WARNS" -gt 0 ]] && \
    logger -t rkhunter -p auth.alert \
        "rkhunter: $WARNS warning(s) — check $LOGFILE"
EOF
        chmod +x /etc/cron.daily/vps-rkhunter

        # chkrootkit daily script
        cat > /etc/cron.daily/vps-chkrootkit << 'EOF'
#!/bin/bash
LOGFILE="/var/log/vps-hardening/chkrootkit.log"
{
    echo "=== $(date '+%Y-%m-%d %H:%M') ==="
    chkrootkit 2>/dev/null \
        | grep -v "not infected" \
        | grep -v "nothing found" \
        | grep -v "^$"
} >> "$LOGFILE"
EOF
        chmod +x /etc/cron.daily/vps-chkrootkit

        log_ok "rkhunter: daily scan + alerting via logger"
        log_ok "chkrootkit: daily scan"

        echo ""
        echo -e "  ${BOLD}Running initial rkhunter scan${NC} ${DIM}(may take a minute)${NC}"
        echo ""
        rkhunter --check --skip-keypress --report-warnings-only 2>/dev/null || true
        echo ""

        log_tip "rkhunter warnings about /dev/.udev or /etc/.java are usually false positives"
        log_tip "After system changes: rkhunter --propupd  (rebaseline)"
    fi

    echo ""
    echo -e "  ${BOLD}Useful commands:${NC}"
    print_code "sudo rkhunter --check --skip-keypress     # manual scan
sudo rkhunter --propupd                    # rebaseline after changes
sudo chkrootkit                            # manual chkrootkit scan
sudo cat /var/log/vps-hardening/rkhunter.log"

    extras_done "05"
    log_ok "rkhunter + chkrootkit installed — daily scans active"
}

# =============================================================================
# MODULE 06 — RESTIC ENCRYPTED BACKUPS
# =============================================================================

mod_06_restic() {
    print_section "Module 06" "Restic Encrypted Backups"

    if extras_complete "06"; then
        log_ok "Restic already configured — skipping"
        return 0
    fi

    echo -e "  ${BOLD}What this does:${NC}"
    echo ""
    impact_bar HIGH "Client-side encrypted backups — cloud cannot read your data"
    echo ""
    echo -e "  ${BOLD}Properties:${NC}"
    badge "Encrypted"    "AES-256 client-side — cloud provider sees ciphertext only"
    badge "Deduplicated" "Only changed blocks uploaded — fast + cheap"
    badge "Versioned"    "Restore any point in time"
    badge "Verified"     "Built-in integrity checking"
    echo ""
    time_badge "30 minutes"
    echo ""

    echo -e "  ${BOLD}Backend options:${NC}"
    echo ""
    echo -e "    ${CYAN}1)${NC}  Backblaze B2    ${DIM}~\$0.006/GB/month — cheapest${NC}"
    echo -e "    ${CYAN}2)${NC}  AWS S3          ${DIM}~\$0.023/GB/month${NC}"
    echo -e "    ${CYAN}3)${NC}  SFTP/SSH        ${DIM}Another server you control${NC}"
    echo -e "    ${CYAN}4)${NC}  Local path      ${DIM}External drive / mounted volume${NC}"
    echo -e "    ${CYAN}5)${NC}  Skip backend    ${DIM}Install restic only, configure later${NC}"
    echo ""
    read -rp "  Backend (1-5): " BACKEND_CHOICE

    run_silent "Updating apt cache" bash -c 'apt-get update -qq'
    run_silent "Installing restic" \
        bash -c 'apt-get install -y -qq restic'

    if [[ "$DRY_RUN" != "true" ]]; then
        run_silent "Updating restic to latest version" \
            bash -c 'restic self-update > /dev/null 2>&1 || true'
    fi

    local REPO_STRING=""
    local ENV_FILE="/root/.restic-env"
    local PASS_FILE="/root/.restic-password"

    if [[ "$DRY_RUN" != "true" ]]; then
        case "$BACKEND_CHOICE" in
            1)  # Backblaze B2
                echo ""
                echo -e "  ${BOLD}Backblaze B2 Setup${NC}"
                echo -e "  ${DIM}Create account at backblaze.com → Buckets → Create bucket${NC}"
                echo ""
                read -rp "  B2 Account ID:  " B2_ACCT
                read -rp "  B2 Account Key: " B2_KEY
                read -rp "  B2 Bucket name: " B2_BUCKET

                REPO_STRING="b2:${B2_BUCKET}"
                cat > "$ENV_FILE" << EOF
export RESTIC_REPOSITORY="${REPO_STRING}"
export B2_ACCOUNT_ID="${B2_ACCT}"
export B2_ACCOUNT_KEY="${B2_KEY}"
EOF
                ;;
            2)  # AWS S3
                echo ""
                echo -e "  ${BOLD}AWS S3 Setup${NC}"
                read -rp "  AWS Access Key ID:     " AWS_KEY_ID
                read -rp "  AWS Secret Access Key: " AWS_SECRET
                read -rp "  S3 Bucket name:        " S3_BUCKET
                read -rp "  AWS Region [us-east-1]:" AWS_REGION
                AWS_REGION="${AWS_REGION:-us-east-1}"

                REPO_STRING="s3:s3.amazonaws.com/${S3_BUCKET}"
                cat > "$ENV_FILE" << EOF
export RESTIC_REPOSITORY="${REPO_STRING}"
export AWS_ACCESS_KEY_ID="${AWS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
EOF
                ;;
            3)  # SFTP
                echo ""
                echo -e "  ${BOLD}SFTP Setup${NC}"
                read -rp "  SFTP host:        " SFTP_HOST
                read -rp "  SFTP user:        " SFTP_USER
                read -rp "  SFTP path:        " SFTP_PATH

                REPO_STRING="sftp:${SFTP_USER}@${SFTP_HOST}:${SFTP_PATH}"
                cat > "$ENV_FILE" << EOF
export RESTIC_REPOSITORY="${REPO_STRING}"
EOF
                ;;
            4)  # Local
                echo ""
                read -rp "  Local backup path [/mnt/backup/restic]: " LOCAL_PATH
                LOCAL_PATH="${LOCAL_PATH:-/mnt/backup/restic}"
                mkdir -p "$LOCAL_PATH"
                REPO_STRING="$LOCAL_PATH"
                cat > "$ENV_FILE" << EOF
export RESTIC_REPOSITORY="${REPO_STRING}"
EOF
                ;;
            5)  # Skip
                log_info "Skipping backend config — restic installed, configure manually"
                extras_done "06"
                return 0
                ;;
        esac

        chmod 600 "$ENV_FILE"

        # Generate strong password
        echo ""
        echo -e "  ${BOLD}Encryption Password${NC}"
        echo -e "  ${DIM}This encrypts your backup. LOSING IT = LOSING YOUR BACKUP.${NC}"
        echo ""
        echo -e "    ${CYAN}1)${NC}  Generate a strong password automatically"
        echo -e "    ${CYAN}2)${NC}  Enter my own password"
        echo ""
        read -rp "  Choice (1/2): " PASS_CHOICE

        if [[ "$PASS_CHOICE" == "1" ]]; then
            local GENERATED_PASS
            GENERATED_PASS=$(openssl rand -base64 32)
            echo "$GENERATED_PASS" > "$PASS_FILE"
            chmod 400 "$PASS_FILE"
            echo ""
            print_box "SAVE THIS PASSWORD NOW — YOU CANNOT RECOVER IT" "$RED"
            echo -e "  ${BOLD}${RED}${GENERATED_PASS}${NC}"
            echo ""
            echo -e "  ${DIM}Stored in: $PASS_FILE${NC}"
            echo -e "  ${DIM}Copy it to your password manager before continuing.${NC}"
            echo ""
            pause
        else
            read -srp "  Password: " USER_PASS
            echo ""
            read -srp "  Confirm:  " USER_PASS2
            echo ""
            [[ "$USER_PASS" != "$USER_PASS2" ]] && die "Passwords don't match"
            echo "$USER_PASS" > "$PASS_FILE"
            chmod 400 "$PASS_FILE"
        fi

        echo "export RESTIC_PASSWORD_FILE='${PASS_FILE}'" >> "$ENV_FILE"

        # Initialize repository
        run_silent "Initializing restic repository" bash -c "
            source '${ENV_FILE}'
            restic init 2>&1 | tail -3" || \
            log_warn "Repository init failed — may already exist, continuing"

        # Backup script
        cat > /usr/local/sbin/vps-backup << BACKUP_EOF
#!/bin/bash
# vps-backup — vps-security-extras v${EXTRAS_VERSION}
set -euo pipefail

LOGFILE="/var/log/vps-hardening/backup.log"
TS=\$(date '+%Y-%m-%dT%H:%M:%S')

log() { echo "\${TS} \$*" | tee -a "\$LOGFILE"; }

source "${ENV_FILE}" 2>/dev/null || { log "ERROR: env file missing"; exit 1; }

log "=== Backup started ==="

# Backup
restic backup \\
    /etc \\
    /home \\
    /root \\
    /var/lib/vps-hardening \\
    /opt \\
    /usr/local/sbin \\
    /usr/local/bin \\
    --exclude /var/cache \\
    --exclude /tmp \\
    --exclude /var/tmp \\
    --exclude /proc \\
    --exclude /sys \\
    --exclude /dev \\
    --exclude /run \\
    --tag "vps-${HOSTNAME_VAL}" \\
    2>&1 | tee -a "\$LOGFILE"

log "Backup complete — applying retention policy"

# Retention: 7 daily, 4 weekly, 12 monthly
restic forget \\
    --keep-daily 7 \\
    --keep-weekly 4 \\
    --keep-monthly 12 \\
    --prune \\
    2>&1 | tee -a "\$LOGFILE"

log "Verifying repository integrity"
restic check 2>&1 | tail -5 | tee -a "\$LOGFILE"

log "=== Backup finished ==="
BACKUP_EOF
        chmod 700 /usr/local/sbin/vps-backup

        # Cron
        cat > /etc/cron.d/vps-backup << EOF
# Restic encrypted backup — vps-security-extras
SHELL=/bin/bash
0 2 * * * root /usr/local/sbin/vps-backup >> /var/log/vps-hardening/backup.log 2>&1
EOF
        chmod 644 /etc/cron.d/vps-backup
        log_ok "Backup cron: daily 02:00"

        # Run first backup
        echo ""
        if ask_yes "Run initial backup now? (recommended — confirms config works)"; then
            log_step "Running initial backup..."
            source "$ENV_FILE"
            restic backup \
                /etc /home /root \
                /var/lib/vps-hardening \
                --tag "initial-$(hostname -s)" \
                2>&1 | tail -10 || \
                log_warn "Backup had errors — check $ENV_FILE credentials"
        fi
    fi

    print_divider
    echo -e "  ${BOLD}Useful commands:${NC}"
    print_code "sudo vps-backup                        # run backup now
source /root/.restic-env
restic snapshots                       # list backups
restic restore latest --target /tmp/r  # restore to /tmp/r
restic restore latest \\
  --include /etc/ssh \\
  --target /tmp/ssh-restore             # restore specific path"

    echo ""
    log_warn "TEST YOUR RESTORE MONTHLY — an untested backup is not a backup"
    extras_done "06"
    log_ok "Restic encrypted backups configured — daily 02:00"
}

# =============================================================================
# MODULE 07 — LYNIS
# =============================================================================

mod_07_lynis() {
    print_section "Module 07" "Lynis Security Audit"

    if extras_complete "07"; then
        log_ok "Lynis already installed — skipping"
        return 0
    fi

    echo -e "  ${BOLD}What this does:${NC}"
    echo ""
    impact_bar MED "200+ item automated security audit — hardening score + prioritised fixes"
    echo ""
    echo -e "  ${DIM}Checks: kernel, services, auth, network, file permissions,${NC}"
    echo -e "  ${DIM}SSL/TLS, software vulnerabilities, logging, and more.${NC}"
    echo -e "  ${DIM}Output: hardening score 0–100. Aim for > 80.${NC}"
    echo ""
    time_badge "5 minutes install + scan"
    echo ""

    run_silent "Updating apt cache" bash -c 'apt-get update -qq'
    run_silent "Installing lynis" \
        bash -c 'apt-get install -y -qq lynis'

    if [[ "$DRY_RUN" != "true" ]]; then
        # Monthly cron
        cat > /etc/cron.d/vps-lynis << 'EOF'
# Lynis monthly security audit — vps-security-extras
SHELL=/bin/bash
0 7 1 * * root lynis audit system --quiet \
    --logfile /var/log/vps-hardening/lynis.log \
    --report-file /var/log/vps-hardening/lynis-report.dat 2>&1
EOF
        chmod 644 /etc/cron.d/vps-lynis
        log_ok "Monthly Lynis audit scheduled: 1st of each month 07:00"

        # Run scan now
        echo ""
        if ask_yes "Run Lynis audit now? (~2 minutes)"; then
            echo ""
            log_step "Running lynis audit — output below:"
            echo ""
            lynis audit system 2>&1 | grep -E "^\[|\bWarning\b|\bSuggestion\b|Hardening index" \
                | tail -40 || true
            echo ""
            log_ok "Full report: /var/log/lynis.log"
            log_tip "Fix warnings first, then suggestions"
            log_tip "Re-run monthly: sudo lynis audit system"
        fi
    fi

    print_code "sudo lynis audit system                              # full scan
sudo lynis audit system --tests-category authentication # specific category
sudo grep Suggestion /var/log/lynis.log                # just suggestions
sudo grep Warning    /var/log/lynis.log                # just warnings"

    extras_done "07"
    log_ok "Lynis installed — monthly automated audit scheduled"
}

# =============================================================================
# MODULE 08 — NGINX / CADDY SECURITY HEADERS
# =============================================================================

mod_08_webserver_headers() {
    print_section "Module 08" "Web Server Security Headers"

    if extras_complete "08"; then
        log_ok "Web security headers already configured — skipping"
        return 0
    fi

    echo -e "  ${BOLD}What this does:${NC}"
    echo ""
    impact_bar MED "HSTS, CSP, X-Frame, nosniff, Referrer-Policy → A+ security rating"
    echo ""
    echo -e "  ${DIM}Prevents: clickjacking, MIME sniffing, XSS, protocol downgrade${NC}"
    echo -e "  ${DIM}Test at: securityheaders.com | observatory.mozilla.org${NC}"
    echo ""
    time_badge "10 minutes"
    echo ""

    # Detect installed web servers
    local HAS_NGINX=false HAS_CADDY=false HAS_APACHE=false
    command -v nginx   > /dev/null 2>&1 && HAS_NGINX=true
    command -v caddy   > /dev/null 2>&1 && HAS_CADDY=true
    command -v apache2 > /dev/null 2>&1 && HAS_APACHE=true
    dpkg -l nginx   2>/dev/null | grep -q "^ii" && HAS_NGINX=true
    dpkg -l caddy   2>/dev/null | grep -q "^ii" && HAS_CADDY=true
    dpkg -l apache2 2>/dev/null | grep -q "^ii" && HAS_APACHE=true

    echo -e "  ${BOLD}Detected web servers:${NC}"
    [[ "$HAS_NGINX"  == "true" ]] && echo -e "    ${GREEN}✓${NC}  nginx"
    [[ "$HAS_CADDY"  == "true" ]] && echo -e "    ${GREEN}✓${NC}  caddy"
    [[ "$HAS_APACHE" == "true" ]] && echo -e "    ${GREEN}✓${NC}  apache2"
    [[ "$HAS_NGINX" == "false" && "$HAS_CADDY" == "false" && "$HAS_APACHE" == "false" ]] && \
        echo -e "    ${DIM}None detected — showing config snippets only${NC}"
    echo ""

    echo -e "  ${BOLD}Web server to configure:${NC}"
    echo -e "    ${CYAN}1)${NC}  Nginx"
    echo -e "    ${CYAN}2)${NC}  Caddy"
    echo -e "    ${CYAN}3)${NC}  Apache2"
    echo -e "    ${CYAN}4)${NC}  Show config snippets only (manual install)"
    echo ""
    read -rp "  Choice (1-4): " WEB_CHOICE

    # Common header block shown for all
    local COMMON_HEADERS
    COMMON_HEADERS='    # Security headers — vps-security-extras
    add_header X-Frame-Options              "SAMEORIGIN"                        always;
    add_header X-Content-Type-Options       "nosniff"                           always;
    add_header X-XSS-Protection             "1; mode=block"                     always;
    add_header Referrer-Policy              "strict-origin-when-cross-origin"   always;
    add_header Permissions-Policy           "camera=(), microphone=(), geolocation=()" always;
    add_header Strict-Transport-Security    "max-age=31536000; includeSubDomains; preload" always;
    add_header Content-Security-Policy      "default-src '"'"'self'"'"'; script-src '"'"'self'"'"'; style-src '"'"'self'"'"' '"'"'unsafe-inline'"'"'; img-src '"'"'self'"'"' data:; font-src '"'"'self'"'"'; frame-ancestors '"'"'none'"'"';" always;
    server_tokens off;'

    if [[ "$DRY_RUN" != "true" ]]; then
        case "$WEB_CHOICE" in
            1)  # Nginx
                if [[ "$HAS_NGINX" == "false" ]]; then
                    run_silent "Installing nginx" \
                        bash -c 'apt-get install -y -qq nginx'
                fi

                cat > /etc/nginx/conf.d/vps-security-headers.conf << 'NGINX_EOF'
# Security headers — vps-security-extras
# Include in your server{} block with:  include /etc/nginx/conf.d/vps-security-headers.conf;

add_header X-Frame-Options              "SAMEORIGIN"                               always;
add_header X-Content-Type-Options       "nosniff"                                  always;
add_header X-XSS-Protection             "1; mode=block"                            always;
add_header Referrer-Policy              "strict-origin-when-cross-origin"          always;
add_header Permissions-Policy           "camera=(), microphone=(), geolocation=()" always;

# HSTS — only enable AFTER confirming HTTPS works correctly
# add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

# CSP — customize for your application
add_header Content-Security-Policy     "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; frame-ancestors 'none';" always;

server_tokens off;

# Hide PHP version if applicable
fastcgi_hide_header X-Powered-By;
proxy_hide_header X-Powered-By;
NGINX_EOF
                nginx -t 2>/dev/null && \
                    systemctl reload nginx && \
                    log_ok "Nginx config valid — reloaded" || \
                    log_warn "Nginx config error — check: nginx -t"
                log_ok "Headers file: /etc/nginx/conf.d/vps-security-headers.conf"
                log_info "Add to your server{} block: include /etc/nginx/conf.d/vps-security-headers.conf;"
                ;;
            2)  # Caddy
                if [[ "$HAS_CADDY" == "false" ]]; then
                    log_info "Installing Caddy..."
                    bash -c 'apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https
                        curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" \
                            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
                        curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt" \
                            | tee /etc/apt/sources.list.d/caddy-stable.list
                        apt-get update -qq
                        apt-get install -y -qq caddy' > /dev/null 2>&1
                fi
                cat > /etc/caddy/security-headers.caddy << 'CADDY_EOF'
# Security headers snippet for Caddy — vps-security-extras
# Import in your Caddyfile block with:  import /etc/caddy/security-headers.caddy

header {
    X-Frame-Options              "SAMEORIGIN"
    X-Content-Type-Options       "nosniff"
    X-XSS-Protection             "1; mode=block"
    Referrer-Policy              "strict-origin-when-cross-origin"
    Permissions-Policy           "camera=(), microphone=(), geolocation=()"
    # Enable HSTS only after HTTPS is confirmed working:
    # Strict-Transport-Security  "max-age=31536000; includeSubDomains; preload"
    Content-Security-Policy      "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; frame-ancestors 'none';"
    -Server
    -X-Powered-By
}
CADDY_EOF
                log_ok "Caddy snippet: /etc/caddy/security-headers.caddy"
                log_info "In your Caddyfile: import /etc/caddy/security-headers.caddy"
                ;;
            3)  # Apache
                if [[ "$HAS_APACHE" == "false" ]]; then
                    run_silent "Installing apache2" \
                        bash -c 'apt-get install -y -qq apache2'
                fi
                a2enmod headers 2>/dev/null || true
                cat > /etc/apache2/conf-available/vps-security-headers.conf << 'APACHE_EOF'
# Security headers — vps-security-extras
Header always set X-Frame-Options             "SAMEORIGIN"
Header always set X-Content-Type-Options      "nosniff"
Header always set X-XSS-Protection            "1; mode=block"
Header always set Referrer-Policy             "strict-origin-when-cross-origin"
Header always set Permissions-Policy          "camera=(), microphone=(), geolocation=()"
# Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
Header always set Content-Security-Policy     "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; frame-ancestors 'none';"
Header unset Server
Header unset X-Powered-By
ServerTokens Prod
ServerSignature Off
APACHE_EOF
                a2enconf vps-security-headers 2>/dev/null || true
                apache2ctl configtest 2>/dev/null && \
                    systemctl reload apache2 && \
                    log_ok "Apache reloaded" || \
                    log_warn "Apache config error — check: apache2ctl configtest"
                ;;
            *)
                echo ""
                echo -e "  ${BOLD}Nginx snippet:${NC}"
                print_code "$COMMON_HEADERS"
                ;;
        esac
    fi

    echo ""
    echo -e "  ${BOLD}Test your headers:${NC}"
    print_code "curl -I https://yourdomain.com              # quick check
# Online tools:
# https://securityheaders.com
# https://observatory.mozilla.org
# Target: A+ rating"

    extras_done "08"
    log_ok "Web security headers configured"
}

# =============================================================================
# MODULE 09 — SYSTEMD SERVICE HARDENING
# =============================================================================

mod_09_systemd_hardening() {
    print_section "Module 09" "Systemd Service Hardening"

    if extras_complete "09"; then
        log_ok "Systemd hardening already applied — skipping"
        return 0
    fi

    echo -e "  ${BOLD}What this does:${NC}"
    echo ""
    impact_bar MED "Sandbox each service — breach blast radius contained"
    echo ""
    echo -e "  ${DIM}If nginx is compromised: attacker gets www-data${NC}"
    echo -e "  ${DIM}www-data cannot: read home dirs, write /etc, load modules${NC}"
    echo -e "  ${DIM}Each service gets its own isolated /tmp, /proc view${NC}"
    echo ""
    time_badge "15 minutes"
    echo ""

    # Detect running services
    local SERVICES=()
    for SVC in nginx caddy apache2 mysql postgresql redis-server \
               mongodb docker fail2ban; do
        systemctl list-unit-files "${SVC}.service" 2>/dev/null \
            | grep -q "${SVC}" && SERVICES+=("$SVC")
    done

    echo -e "  ${BOLD}Detected services:${NC}"
    if [[ ${#SERVICES[@]} -eq 0 ]]; then
        echo -e "    ${DIM}No common services found${NC}"
    else
        for S in "${SERVICES[@]}"; do
            local STATUS="stopped"
            service_active "$S" && STATUS="${GREEN}running${NC}"
            echo -e "    ${DIM}$S${NC} — $STATUS"
        done
    fi
    echo ""

    if [[ "$DRY_RUN" != "true" ]]; then
        # Write a reusable hardening template
        cat > /usr/local/share/vps-systemd-hardening.conf << 'TMPL_EOF'
# Systemd service hardening template — vps-security-extras
# Copy to /etc/systemd/system/<service>.service.d/hardening.conf
#
# IMPORTANT: Some directives break specific services.
# Test each one individually. Remove what causes issues.
#
[Service]
# ── Privilege ─────────────────────────────────────────────────────────
# No setuid/setgid — service cannot gain privileges
NoNewPrivileges=yes

# ── Filesystem ────────────────────────────────────────────────────────
# Own isolated /tmp — other services cannot see it
PrivateTmp=yes

# Mount / read-only except explicit ReadWritePaths
ProtectSystem=strict

# Cannot touch /home /root /run/user
ProtectHome=yes

# ── Kernel ────────────────────────────────────────────────────────────
# Cannot load/unload kernel modules
ProtectKernelModules=yes

# Cannot modify kernel tunables (sysctl)
ProtectKernelTunables=yes

# Cannot write to kernel logs
ProtectKernelLogs=yes

# ── Process isolation ─────────────────────────────────────────────────
# /proc shows only own processes
ProtectProc=invisible

# Cannot access control groups of other services
ProtectControlGroups=yes

# ── Device access ─────────────────────────────────────────────────────
# Only allow standard pseudo-devices
PrivateDevices=yes

# ── Capabilities ──────────────────────────────────────────────────────
# Remove all Linux capabilities (add back what you need)
CapabilityBoundingSet=
# For web servers binding port 80/443:
# CapabilityBoundingSet=CAP_NET_BIND_SERVICE
# AmbientCapabilities=CAP_NET_BIND_SERVICE

# ── System calls ──────────────────────────────────────────────────────
# Allow only safe system call set
SystemCallFilter=@system-service
SystemCallArchitectures=native

# ── Network ───────────────────────────────────────────────────────────
# Restrict to these socket families (add AF_UNIX if needed)
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# ── Resource limits ───────────────────────────────────────────────────
# Maximum processes (prevents fork bombs)
TasksMax=256

# Memory limit (adjust per service)
# MemoryMax=512M
TMPL_EOF
        log_ok "Template: /usr/local/share/vps-systemd-hardening.conf"

        # Apply hardening to detected services
        for SVC in "${SERVICES[@]}"; do
            echo ""
            if ask_yes "Apply hardening to ${SVC}?"; then
                local DROP_IN="/etc/systemd/system/${SVC}.service.d"
                mkdir -p "$DROP_IN"

                # Service-specific configs (safe subsets)
                case "$SVC" in
                    nginx|caddy|apache2)
                        cat > "${DROP_IN}/hardening.conf" << 'EOF'
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
PrivateDevices=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_CHOWN CAP_SETUID CAP_SETGID
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallFilter=@system-service
SystemCallArchitectures=native
TasksMax=512
EOF
                        ;;
                    mysql|postgresql)
                        cat > "${DROP_IN}/hardening.conf" << 'EOF'
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
PrivateDevices=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallArchitectures=native
TasksMax=256
EOF
                        ;;
                    redis-server)
                        cat > "${DROP_IN}/hardening.conf" << 'EOF'
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
PrivateDevices=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallFilter=@system-service
SystemCallArchitectures=native
TasksMax=128
EOF
                        ;;
                    *)
                        # Generic safe subset
                        cat > "${DROP_IN}/hardening.conf" << 'EOF'
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
PrivateDevices=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallArchitectures=native
TasksMax=256
EOF
                        ;;
                esac

                systemctl daemon-reload
                if systemctl restart "$SVC" 2>/dev/null; then
                    log_ok "$SVC: hardening applied + restarted"
                    # Show security score
                    local SCORE
                    SCORE=$(systemd-analyze security "$SVC" 2>/dev/null \
                        | grep "→" | awk '{print $NF}' || echo "?")
                    [[ -n "$SCORE" ]] && log_info "$SVC security score: $SCORE (lower = better)"
                else
                    log_warn "$SVC failed to restart — reverting hardening"
                    rm -f "${DROP_IN}/hardening.conf"
                    systemctl daemon-reload
                    systemctl start "$SVC" 2>/dev/null || true
                fi
            fi
        done

        echo ""
        echo -e "  ${BOLD}Check security scores:${NC}"
        print_code "systemd-analyze security nginx    # score per service
systemd-analyze security --all    # all services
# Score < 4.0 = well confined"
    fi

    extras_done "09"
    log_ok "Systemd hardening applied"
}

# =============================================================================
# MODULE 10 — GEOIP + ASN BLOCKING
# =============================================================================

mod_10_geoip() {
    print_section "Module 10" "GeoIP + ASN Blocking"

    if extras_complete "10"; then
        log_ok "GeoIP blocking already configured — skipping"
        return 0
    fi

    echo -e "  ${BOLD}What this does:${NC}"
    echo ""
    impact_bar MED "Block high-attack-volume countries/ASNs at kernel level — ipset O(1) matching"
    echo ""
    echo -e "  ${DIM}~80% of SSH brute force comes from a small number of ASNs.${NC}"
    echo -e "  ${DIM}ipset handles 100,000 IP ranges at wire speed — no performance cost.${NC}"
    echo ""
    echo -e "  ${BOLD}Two approaches:${NC}"
    badge "ASN blocking"     "Block specific Autonomous System Networks (precise)"
    badge "Country blocking" "Block entire countries (broader, more controversial)"
    echo ""
    time_badge "20 minutes"
    echo ""

    run_silent "Updating apt cache" bash -c 'apt-get update -qq'
    run_silent "Installing ipset" \
        bash -c 'apt-get install -y -qq ipset ipset-persistent'

    if [[ "$DRY_RUN" != "true" ]]; then
        # Create persistent ipset
        ipset create vps-blocked-ips hash:net 2>/dev/null || \
            ipset flush vps-blocked-ips 2>/dev/null || true

        echo ""
        echo -e "  ${BOLD}Blocking method:${NC}"
        echo ""
        echo -e "    ${CYAN}1)${NC}  Block known high-attack ASNs (recommended)"
        echo -e "    ${CYAN}2)${NC}  Block specific countries"
        echo -e "    ${CYAN}3)${NC}  Both"
        echo ""
        read -rp "  Choice (1-3): " GEO_CHOICE

        local BLOCK_ASNS=false BLOCK_COUNTRIES=false
        [[ "$GEO_CHOICE" == "1" || "$GEO_CHOICE" == "3" ]] && BLOCK_ASNS=true
        [[ "$GEO_CHOICE" == "2" || "$GEO_CHOICE" == "3" ]] && BLOCK_COUNTRIES=true

        if [[ "$BLOCK_ASNS" == "true" ]]; then
            echo ""
            echo -e "  ${BOLD}Known high-attack ASNs:${NC}"
            echo ""
            badge "AS4134"  "China Telecom — high attack volume"
            badge "AS4837"  "China Unicom — high attack volume"
            badge "AS9009"  "M247 Ltd — common VPS abuse"
            badge "AS16276" "OVH — frequently used for attacks"
            badge "AS14061" "DigitalOcean — frequent abuse source"
            badge "AS24940" "Hetzner — frequent abuse source"
            echo ""
            echo -e "  ${DIM}Note: Some of these also host legitimate traffic.${NC}"
            echo -e "  ${DIM}Inspect https://bgp.he.net to look up any ASN.${NC}"
            echo ""
            read -rp "  Enter ASNs to block (space-separated, e.g. 4134 9009): " ASN_INPUT

            for ASN in $ASN_INPUT; do
                echo ""
                log_step "Fetching IP ranges for AS${ASN}..."
                local RANGES
                RANGES=$(curl -s --max-time 30 \
                    "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${ASN}" \
                    2>/dev/null \
                    | grep -oP '"prefix":\s*"\K[^"]+' || true)

                if [[ -z "$RANGES" ]]; then
                    log_warn "No ranges found for AS${ASN} — skipping"
                    continue
                fi

                local COUNT=0
                while IFS= read -r RANGE; do
                    [[ -z "$RANGE" ]] && continue
                    ipset add vps-blocked-ips "$RANGE" 2>/dev/null || true
                    COUNT=$((COUNT+1))
                done <<< "$RANGES"
                log_ok "AS${ASN}: blocked $COUNT IP ranges"
            done
        fi

        if [[ "$BLOCK_COUNTRIES" == "true" ]]; then
            echo ""
            echo -e "  ${BOLD}Country blocking${NC}"
            echo -e "  ${DIM}Uses ipdeny.com country zone files (updated daily)${NC}"
            echo ""
            echo -e "  ${DIM}Enter 2-letter country codes (e.g. CN RU KP KR BR)${NC}"
            read -rp "  Countries to block: " COUNTRY_INPUT

            for CC in $COUNTRY_INPUT; do
                CC="${CC,,}"
                echo ""
                log_step "Fetching IP ranges for ${CC^^}..."
                local ZONE_URL="https://www.ipdeny.com/ipblocks/data/aggregated/${CC}-aggregated.zone"
                local RANGES
                RANGES=$(curl -s --max-time 30 "$ZONE_URL" 2>/dev/null || true)

                if [[ -z "$RANGES" ]]; then
                    log_warn "No ranges found for country '${CC}' — check code"
                    continue
                fi

                local COUNT=0
                while IFS= read -r RANGE; do
                    [[ -z "$RANGE" || "$RANGE" == \#* ]] && continue
                    ipset add vps-blocked-ips "$RANGE" 2>/dev/null || true
                    COUNT=$((COUNT+1))
                done <<< "$RANGES"
                log_ok "${CC^^}: blocked $COUNT IP ranges"
            done
        fi

        # Apply iptables rule
        local TOTAL_BLOCKED
        TOTAL_BLOCKED=$(ipset list vps-blocked-ips 2>/dev/null \
            | grep "Number of entries" | awk '{print $NF}' || echo 0)

        if [[ "$TOTAL_BLOCKED" -gt 0 ]]; then
            # Insert rule before other INPUT rules
            iptables -I INPUT 1 \
                -m set --match-set vps-blocked-ips src \
                -j DROP 2>/dev/null || true

            # Persist ipset across reboots
            mkdir -p /etc/ipset
            ipset save > /etc/ipset/vps-blocked.rules 2>/dev/null || true

            # Restore on boot via systemd
            cat > /etc/systemd/system/vps-ipset-restore.service << EOF
[Unit]
Description=Restore vps-hardening ipset rules
Before=network.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/sbin/ipset restore -! < /etc/ipset/vps-blocked.rules
ExecStartPost=/sbin/iptables -I INPUT 1 -m set --match-set vps-blocked-ips src -j DROP
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable vps-ipset-restore.service > /dev/null 2>&1

            # Daily refresh cron
            cat > /etc/cron.d/vps-geoip-refresh << 'EOF'
# GeoIP ipset refresh — vps-security-extras
SHELL=/bin/bash
0 3 * * * root /usr/local/sbin/vps-geoip-refresh >> /var/log/vps-hardening/geoip.log 2>&1
EOF

            cat > /usr/local/sbin/vps-geoip-refresh << 'REFRESH_EOF'
#!/bin/bash
# Reload ipset from saved rules (after ipdeny updates etc)
echo "$(date) Refreshing ipset..."
ipset flush vps-blocked-ips 2>/dev/null || true
ipset restore -! < /etc/ipset/vps-blocked.rules 2>/dev/null || true
echo "$(date) Done — $(ipset list vps-blocked-ips | grep 'Number of entries' | awk '{print $NF}') entries"
REFRESH_EOF
            chmod 750 /usr/local/sbin/vps-geoip-refresh
            chmod 644 /etc/cron.d/vps-geoip-refresh

            log_ok "Total blocked: $TOTAL_BLOCKED IP ranges (O(1) kernel matching)"
            log_ok "Persists across reboots via systemd unit"
        else
            log_warn "No IPs were added to the block list — nothing to activate"
        fi

        echo ""
        echo -e "  ${BOLD}Useful commands:${NC}"
        print_code "sudo ipset list vps-blocked-ips | head -20   # view blocked ranges
sudo ipset test vps-blocked-ips 1.2.3.4        # test a specific IP
sudo ipset del  vps-blocked-ips 1.2.3.4/24     # remove a range
sudo ipset add  vps-blocked-ips 1.2.3.4/24     # add a range
sudo iptables -L INPUT -n | grep DROP           # verify rule active"
    fi

    extras_done "10"
    log_ok "GeoIP / ASN blocking configured"
}

# =============================================================================
# MODULE 11 — SERVICE USER ISOLATION
# =============================================================================

mod_11_service_users() {
    print_section "Module 11" "Service User Isolation"

    if extras_complete "11"; then
        log_ok "Service user isolation already configured — skipping"
        return 0
    fi

    echo -e "  ${BOLD}What this does:${NC}"
    echo ""
    impact_bar MED "One system account per service — breach contained to that service only"
    echo ""
    echo -e "  ${DIM}If nginx is exploited: attacker has www-data${NC}"
    echo -e "  ${DIM}www-data cannot: read /home, write /etc, access DB files${NC}"
    echo -e "  ${DIM}Pattern: one service = one account = one set of permissions${NC}"
    echo ""
    time_badge "15 minutes"
    echo ""

    echo -e "  ${BOLD}What app/service do you want to isolate?${NC}"
    echo ""
    echo -e "    ${CYAN}1)${NC}  Generic web application"
    echo -e "    ${CYAN}2)${NC}  Node.js application"
    echo -e "    ${CYAN}3)${NC}  Python application"
    echo -e "    ${CYAN}4)${NC}  Custom service name"
    echo ""
    read -rp "  Choice (1-4): " APP_TYPE

    local APP_NAME="" APP_DIR=""
    case "$APP_TYPE" in
        1) APP_NAME="webapp";  APP_DIR="/var/www/webapp" ;;
        2) APP_NAME="nodeapp"; APP_DIR="/var/www/nodeapp" ;;
        3) APP_NAME="pyapp";   APP_DIR="/var/www/pyapp" ;;
        *)
            read -rp "  Service name (lowercase, no spaces): " APP_NAME
            read -rp "  App directory [/opt/${APP_NAME}]:    " APP_DIR
            APP_DIR="${APP_DIR:-/opt/${APP_NAME}}"
            ;;
    esac

    if [[ "$DRY_RUN" != "true" ]]; then
        # Create system user
        if id "$APP_NAME" > /dev/null 2>&1; then
            log_info "User $APP_NAME already exists"
        else
            adduser \
                --system \
                --no-create-home \
                --shell /usr/sbin/nologin \
                --group \
                "$APP_NAME" 2>/dev/null
            log_ok "System user created: $APP_NAME (no shell, no home)"
        fi

        mkdir -p "$APP_DIR"
        chown "${APP_NAME}:${APP_NAME}" "$APP_DIR"
        chmod 750 "$APP_DIR"
        log_ok "App directory: $APP_DIR (owned by $APP_NAME)"

        # Write systemd unit template
        local UNIT_FILE="/etc/systemd/system/${APP_NAME}.service"
        cat > "${UNIT_FILE}.template" << EOF
# Systemd unit for ${APP_NAME} — vps-security-extras
# Copy to ${UNIT_FILE} and customize ExecStart

[Unit]
Description=${APP_NAME} service
After=network.target
Wants=network.target

[Service]
Type=simple
User=${APP_NAME}
Group=${APP_NAME}
WorkingDirectory=${APP_DIR}

# Replace with your actual start command:
ExecStart=/usr/bin/your-app-binary --config ${APP_DIR}/config.yml

Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}

# ── Hardening ─────────────────────────────────────────────────────────
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
PrivateDevices=yes
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallFilter=@system-service
SystemCallArchitectures=native
TasksMax=256
ReadWritePaths=${APP_DIR}

[Install]
WantedBy=multi-user.target
EOF
        log_ok "Systemd template: ${UNIT_FILE}.template"

        # Nginx proxy snippet if nginx exists
        if command -v nginx > /dev/null 2>&1; then
            local NGINX_SNIPPET="/etc/nginx/sites-available/${APP_NAME}.conf"
            cat > "$NGINX_SNIPPET" << EOF
# Nginx reverse proxy for ${APP_NAME} — vps-security-extras
server {
    listen 80;
    server_name your-domain.com;

    # Security headers
    include /etc/nginx/conf.d/vps-security-headers.conf;

    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;

        # Rate limiting (define zones in nginx.conf)
        # limit_req zone=one burst=20 nodelay;
    }

    access_log  /var/log/nginx/${APP_NAME}-access.log;
    error_log   /var/log/nginx/${APP_NAME}-error.log;
}
EOF
            log_ok "Nginx proxy snippet: $NGINX_SNIPPET"
            log_info "Enable with: sudo ln -s $NGINX_SNIPPET /etc/nginx/sites-enabled/"
        fi

        echo ""
        echo -e "  ${BOLD}Summary:${NC}"
        echo ""
        badge "User"     "$APP_NAME (system, no shell)"
        badge "Group"    "$APP_NAME"
        badge "Dir"      "$APP_DIR (owned by $APP_NAME)"
        badge "Unit"     "${UNIT_FILE}.template (copy + edit)"
        echo ""
        echo -e "  ${BOLD}Next steps:${NC}"
        print_code "# Edit the unit file template:
cp ${UNIT_FILE}.template ${UNIT_FILE}
nano ${UNIT_FILE}

# Enable and start:
systemctl daemon-reload
systemctl enable ${APP_NAME}
systemctl start  ${APP_NAME}
systemctl status ${APP_NAME}

# Verify confinement score:
systemd-analyze security ${APP_NAME}"
    fi

    extras_done "11"
    log_ok "Service isolation configured for: ${APP_NAME:-example}"
}

# =============================================================================
# MODULE 12 — CLAMAV
# =============================================================================

mod_12_clamav() {
    print_section "Module 12" "ClamAV Malware Scanner"

    if extras_complete "12"; then
        log_ok "ClamAV already installed — skipping"
        return 0
    fi

    echo -e "  ${BOLD}What this does:${NC}"
    echo ""
    impact_bar MED "Daily malware, web shell, and cryptocurrency miner detection"
    echo ""
    echo -e "  ${DIM}Catches: web shells uploaded via vulnerable apps${NC}"
    echo -e "  ${DIM}Catches: cryptocurrency miners, common Linux backdoors${NC}"
    echo -e "  ${DIM}Different from AIDE — detects known-bad patterns, not file changes${NC}"
    echo ""
    time_badge "10 minutes install + signature download"
    echo ""

    run_silent "Updating apt cache" bash -c 'apt-get update -qq'
    policy_block
    run_silent "Installing ClamAV + daemon" \
        bash -c 'apt-get install -y -qq clamav clamav-daemon'
    policy_allow

    if [[ "$DRY_RUN" != "true" ]]; then
        run_silent "Stopping freshclam for initial update" \
            bash -c 'systemctl stop clamav-freshclam 2>/dev/null || true'
        run_silent "Downloading latest ClamAV signatures (~200MB)" \
            bash -c 'freshclam 2>&1 | tail -3'
        run_silent "Starting freshclam daemon" \
            bash -c 'systemctl start clamav-freshclam || true'
        run_silent "Enabling clamav-daemon" \
            bash -c 'systemctl enable clamav-daemon || true'

        cat > /etc/cron.daily/vps-clamav << 'EOF'
#!/bin/bash
# Daily ClamAV scan — vps-security-extras
LOGFILE="/var/log/vps-hardening/clamav.log"
DATE=$(date '+%Y-%m-%d %H:%M')

echo "=== ClamAV Scan: $DATE ===" >> "$LOGFILE"

clamscan -r \
    --exclude-dir=/proc \
    --exclude-dir=/sys \
    --exclude-dir=/dev \
    --exclude-dir=/run \
    --exclude-dir=/snap \
    --exclude-dir=/var/lib/clamav \
    --infected \
    --quiet \
    / >> "$LOGFILE" 2>&1

EXIT_CODE=$?

# Alert if infections found
if [[ "$EXIT_CODE" -eq 1 ]]; then
    FOUND=$(grep -c "FOUND" "$LOGFILE" 2>/dev/null || echo 0)
    logger -t clamav -p auth.alert \
        "MALWARE DETECTED: $FOUND infection(s) — check $LOGFILE"
fi

echo "Exit: $EXIT_CODE" >> "$LOGFILE"
EOF
        chmod +x /etc/cron.daily/vps-clamav
        log_ok "ClamAV daily scan configured"

        echo ""
        echo -e "  ${BOLD}Running quick test scan${NC} ${DIM}(/etc only — full scan runs nightly)${NC}"
        clamscan -r --quiet /etc 2>/dev/null \
            && log_ok "/etc scan clean" \
            || log_warn "ClamAV found something in /etc — check output above"
    fi

    echo ""
    echo -e "  ${BOLD}Useful commands:${NC}"
    print_code "sudo clamscan -r --infected /var/www    # scan web root
sudo clamscan -r --infected /home         # scan home dirs
sudo freshclam                            # update signatures
sudo cat /var/log/vps-hardening/clamav.log"

    extras_done "12"
    log_ok "ClamAV installed — daily full-system scan active"
}

# =============================================================================
# FINAL SUMMARY
# =============================================================================

print_final_summary() {
    local SCRIPT_END
    SCRIPT_END=$(date +%s)
    local ELAPSED=$(( SCRIPT_END - SCRIPT_START ))
    local MINUTES=$(( ELAPSED / 60 ))
    local SECS=$(( ELAPSED % 60 ))

    echo ""
    echo ""
    echo -e "${BOLD}${GREEN}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║                                                          ║"
    echo "  ║   🔒  VPS SECURITY EXTRAS COMPLETE                      ║"
    echo "  ║   Your defenses have been upgraded.                      ║"
    echo "  ║                                                          ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${DIM}Completed in ${MINUTES}m ${SECS}s${NC}"
    echo ""

    echo -e "  ${BOLD}${WHITE}Installed modules:${NC}"
    echo ""
    for K in "${ORDERED_KEYS[@]}"; do
        if extras_complete "$K"; then
            echo -e "  ${GREEN}✓${NC}  ${MOD_LABELS[$K]}"
        fi
    done
    echo ""

    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}${WHITE}Key commands:${NC}"
    echo ""

    extras_complete "01" && \
        echo -e "    ${CYAN}google-authenticator${NC}              ${DIM}Re-run 2FA setup${NC}"
    extras_complete "02" && \
        echo -e "    ${CYAN}wg show${NC}                           ${DIM}WireGuard status${NC}"
    extras_complete "03" && \
        echo -e "    ${CYAN}sudo aide --check${NC}                 ${DIM}Run AIDE integrity check${NC}"
    extras_complete "03" && \
        echo -e "    ${CYAN}sudo aide-update${NC}                  ${DIM}Rebaseline after changes${NC}"
    extras_complete "04" && \
        echo -e "    ${CYAN}ssh -L 3000:localhost:3000 ...${NC}    ${DIM}Access Grafana${NC}"
    extras_complete "05" && \
        echo -e "    ${CYAN}sudo rkhunter --check --skip-keypress${NC} ${DIM}Rootkit scan${NC}"
    extras_complete "06" && \
        echo -e "    ${CYAN}sudo vps-backup${NC}                   ${DIM}Run backup now${NC}"
    extras_complete "07" && \
        echo -e "    ${CYAN}sudo lynis audit system${NC}           ${DIM}Security audit${NC}"
    extras_complete "10" && \
        echo -e "    ${CYAN}sudo ipset list vps-blocked-ips | wc -l${NC} ${DIM}Blocked ranges${NC}"
    echo ""

    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}${WHITE}Key files:${NC}"
    echo ""
    extras_complete "01" && \
        echo -e "    ${DIM}TOTP backup codes${NC}  ~/google-authenticator (as $ADMIN_USER)"
    extras_complete "02" && \
        echo -e "    ${DIM}WireGuard config${NC}   /etc/wireguard/wg0.conf"
    extras_complete "02" && \
        echo -e "    ${DIM}WG server pubkey${NC}   /etc/wireguard/public.key"
    extras_complete "06" && \
        echo -e "    ${DIM}Backup env${NC}         /root/.restic-env"
    extras_complete "06" && \
        echo -e "    ${DIM}Backup password${NC}    /root/.restic-password ${RED}(BACK THIS UP)${NC}"
    echo -e "    ${DIM}Extras log${NC}         ${EXTRAS_LOG}"
    echo -e "    ${DIM}Extras state${NC}       ${EXTRAS_STATE}"
    echo ""

    echo -e "  ${BOLD}${WHITE}Suggested next steps:${NC}"
    echo ""

    local STEP=1

    if extras_complete "02"; then
        echo -e "  ${YELLOW}  $STEP.${NC}  ${BOLD}Test WireGuard${NC} — connect from your laptop, then SSH via VPN IP"
        STEP=$((STEP+1))
    fi

    if extras_complete "06"; then
        echo -e "  ${YELLOW}  $STEP.${NC}  ${BOLD}Test your backup restore${NC}"
        echo -e "       ${CYAN}source /root/.restic-env && restic restore latest --target /tmp/restore-test${NC}"
        STEP=$((STEP+1))
    fi

    if extras_complete "07"; then
        echo -e "  ${YELLOW}  $STEP.${NC}  ${BOLD}Review Lynis suggestions${NC}"
        echo -e "       ${CYAN}sudo grep Suggestion /var/log/lynis.log${NC}"
        STEP=$((STEP+1))
    fi

    if ! extras_complete "01"; then
        echo -e "  ${YELLOW}  $STEP.${NC}  ${BOLD}Consider TOTP 2FA${NC} — stops credential attacks completely"
        STEP=$((STEP+1))
    fi

    if ! extras_complete "02"; then
        echo -e "  ${YELLOW}  $STEP.${NC}  ${BOLD}Consider WireGuard${NC} — SSH disappears from the internet"
        STEP=$((STEP+1))
    fi

    echo ""
    echo -e "  ${BOLD}${MAGENTA}  Stay safe out there. 🛡️${NC}"
    echo ""
    echo -e "  ${DIM}Full log: ${EXTRAS_LOG}${NC}"
    echo ""

    _log_raw "COMPLETE" "extras finished in ${MINUTES}m ${SECS}s"
}

# =============================================================================
# MAIN
# =============================================================================

SCRIPT_START=$(date +%s)
_log_raw "START" "vps-security-extras ${EXTRAS_VERSION}"

print_banner

echo -e "  ${BOLD}Welcome to VPS Security Extras!${NC}"
echo ""
echo -e "  This companion script installs advanced security modules"
echo -e "  that go beyond the baseline vps-hardening v5.0 setup."
echo ""
echo -e "  ${DIM}Server:  ${PUBLIC_IP} | Admin: ${ADMIN_USER} | SSH: ${SSH_PORT}${NC}"
[[ "$DRY_RUN" == "true" ]] && echo -e "  ${YELLOW}DRY-RUN: no changes will be made${NC}"
echo ""
pause

show_menu
confirm_selection

# Execute selected modules
[[ "${SELECTED[01]}" == "true" ]] && mod_01_totp
[[ "${SELECTED[02]}" == "true" ]] && mod_02_wireguard
[[ "${SELECTED[03]}" == "true" ]] && mod_03_aide
[[ "${SELECTED[04]}" == "true" ]] && mod_04_monitoring
[[ "${SELECTED[05]}" == "true" ]] && mod_05_rkhunter
[[ "${SELECTED[06]}" == "true" ]] && mod_06_restic
[[ "${SELECTED[07]}" == "true" ]] && mod_07_lynis
[[ "${SELECTED[08]}" == "true" ]] && mod_08_webserver_headers
[[ "${SELECTED[09]}" == "true" ]] && mod_09_systemd_hardening
[[ "${SELECTED[10]}" == "true" ]] && mod_10_geoip
[[ "${SELECTED[11]}" == "true" ]] && mod_11_service_users
[[ "${SELECTED[12]}" == "true" ]] && mod_12_clamav

print_final_summary
