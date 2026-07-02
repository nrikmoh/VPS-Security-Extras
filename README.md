# VPS Hardening Scripts

Production-grade server security for Ubuntu 20.04 / 22.04 / 24.04.

## Scripts

- `harden.sh` — Baseline hardening (run first)
- `extras.sh` — Advanced security modules (run after harden.sh)

## Usage

```bash
# One-liner install
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/vps-hardening/main/harden.sh)
