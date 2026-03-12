# Bot Fleet — AI Workforce Infrastructure

## Overview
Automated provisioning of Ubuntu VMs on Hyper-V for running OpenClaw bots at scale.

## Architecture
```
Hyper-V Host (Windows Server)
├── fleet-manager VM (first bot — manages everything)
├── sales-bot-01 VM
├── sales-bot-02 VM
└── ...
```

## Components
- `New-BotVM.ps1` — PowerShell provisioner (run on Hyper-V host)
- `cloud-init/user-data` — Ubuntu auto-config (Node.js, OpenClaw, hardening)
- `cloud-init/meta-data` — VM identity
- `Create-CloudInitISO.ps1` — Generates cloud-init ISO per bot
- `SETUP-GUIDE.md` — Step-by-step for Kelly

## Quick Start
1. Run `New-BotVM.ps1` on the Hyper-V host
2. Wait ~3-5 minutes for VM to boot + configure
3. SSH in and finish OpenClaw setup (API keys, channels)

## Credentials
All stored in Bitwarden Secrets Manager under "Bot Fleet" project.
No passwords in files. Ever.
