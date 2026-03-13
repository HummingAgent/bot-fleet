<#
.SYNOPSIS
    Provisions a new Ubuntu 24.04 VM on Hyper-V for running OpenClaw bots.

.DESCRIPTION
    Downloads Ubuntu cloud image (first run only), creates a cloud-init ISO,
    spins up a Gen 2 Hyper-V VM, and boots it. Cloud-init handles all
    post-boot configuration: user creation, SSH keys, Node.js, OpenClaw,
    security hardening.

.PARAMETER Name
    VM name (e.g., "phoenix", "sales-bot-01")

.PARAMETER RAM
    Memory in bytes. Default: 4GB

.PARAMETER CPUs
    Virtual processors. Default: 2

.PARAMETER DiskSizeGB
    OS disk size in GB. Default: 30

.PARAMETER VMPath
    Base path for VM files. Default: D:\BotFleet

.PARAMETER SwitchName
    Hyper-V virtual switch name.

.PARAMETER SSHPublicKey
    SSH public key for the admin user. If not provided, generates a new keypair.

.PARAMETER OpenClawConfig
    Path to an openclaw.json config file. If provided, the config is injected
    into the VM and the gateway is started automatically on first boot.

.PARAMETER StaticMemory
    Use static (fixed) memory instead of dynamic. Recommended for OpenClaw bots
    to prevent OOM from dynamic memory starting at minimum.

.EXAMPLE
    .\New-BotVM.ps1 -Name "phoenix" -StaticMemory
    .\New-BotVM.ps1 -Name "phoenix" -StaticMemory -OpenClawConfig "D:\BotFleet\configs\phoenix.json"
    .\New-BotVM.ps1 -Name "sales-bot-01" -RAM 2GB -CPUs 2
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Name,

    [int64]$RAM = 8GB,

    [int]$CPUs = 4,

    [int]$DiskSizeGB = 100,

    [string]$VMPath = "D:\BotFleet",

    [string]$SwitchName = "BotFleet NAT",

    [string]$SSHPublicKey = "",

    [string]$StaticIP = "10.10.10.100",

    [string]$Gateway = "10.10.10.1",

    [string]$DNS = "8.8.8.8",

    [string]$OpenClawConfig = "",

    [switch]$StaticMemory
)

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIG
# ============================================================
$ImageCacheDir = "$VMPath\_images"
$CloudImageURL = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
$CloudImageFile = "$ImageCacheDir\ubuntu-24.04-cloudimg-amd64.img"
$BaseVHDX = "$ImageCacheDir\ubuntu-24.04-base.vhdx"

# VM-specific paths
$VMDir = "$VMPath\$Name"
$VHDX = "$VMDir\$Name-os.vhdx"
$CloudInitISO = "$VMDir\$Name-cidata.iso"
$SSHKeyDir = "$VMDir\ssh"

# ============================================================
# PREREQUISITES CHECK
# ============================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Bot Fleet Provisioner" -ForegroundColor Cyan
Write-Host "  Creating: $Name" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Must run as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator. Right-click PowerShell > Run as Administrator."
    exit 1
}

# Check Hyper-V module
if (-not (Get-Command "New-VM" -ErrorAction SilentlyContinue)) {
    Write-Error "Hyper-V PowerShell module not found. Run: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell"
    exit 1
}

# Check virtual switch exists
$vmSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $vmSwitch) {
    Write-Host "Virtual switch '$SwitchName' not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "Available switches:" -ForegroundColor Yellow
    Get-VMSwitch | Format-Table Name, SwitchType -AutoSize
    Write-Error "Specify -SwitchName with one of the above."
    exit 1
}

# Check VM doesn't already exist
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    Write-Error "VM '$Name' already exists. Remove it first: Remove-VM -Name '$Name' -Force"
    exit 1
}

# ============================================================
# STEP 1: Download Ubuntu Cloud Image (first run only)
# ============================================================
New-Item -ItemType Directory -Path $ImageCacheDir -Force | Out-Null
New-Item -ItemType Directory -Path $VMDir -Force | Out-Null

if (-not (Test-Path $BaseVHDX)) {
    if (-not (Test-Path $CloudImageFile)) {
        Write-Host "[1/6] Downloading Ubuntu 24.04 cloud image (~600MB)..." -ForegroundColor Yellow
        Write-Host "       URL: $CloudImageURL"
        Write-Host "       This only happens once. Future VMs clone from cache."
        Write-Host ""

        try {
            Start-BitsTransfer -Source $CloudImageURL -Destination $CloudImageFile -DisplayName "Ubuntu 24.04 Cloud Image"
        } catch {
            Write-Host "       BITS transfer failed, falling back to Invoke-WebRequest..." -ForegroundColor Yellow
            Invoke-WebRequest -Uri $CloudImageURL -OutFile $CloudImageFile -UseBasicParsing
        }
        Write-Host "       Download complete." -ForegroundColor Green
    } else {
        Write-Host "[1/6] Ubuntu cloud image already cached." -ForegroundColor Green
    }

    # Convert .img (qcow2) to .vhdx
    Write-Host "[1/6] Converting cloud image to VHDX..." -ForegroundColor Yellow

    # Find qemu-img
    $qemuImg = $null
    $qemuSearchPaths = @(
        "C:\Program Files\qemu\qemu-img.exe",
        "C:\qemu\qemu-img.exe",
        "$env:ProgramFiles\qemu\qemu-img.exe",
        "$env:ChocolateyInstall\bin\qemu-img.exe"
    )

    $qemuCmd = Get-Command "qemu-img" -ErrorAction SilentlyContinue
    if ($qemuCmd) {
        $qemuImg = $qemuCmd.Source
    } else {
        foreach ($p in $qemuSearchPaths) {
            if (Test-Path $p) { $qemuImg = $p; break }
        }
    }

    if (-not $qemuImg) {
        Write-Host ""
        Write-Host "  ERROR: qemu-img not found." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Install it with:" -ForegroundColor Yellow
        Write-Host "    winget install SoftwareFreedomConservancy.QEMU" -ForegroundColor White
        Write-Host ""
        Write-Host "  Then restart this PowerShell window and run the script again." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "       Using: $qemuImg" -ForegroundColor Gray
    & $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic "$CloudImageFile" "$BaseVHDX"

    if ($LASTEXITCODE -ne 0) {
        Write-Error "qemu-img conversion failed. Check the cloud image file isn't corrupted."
        exit 1
    }
    Write-Host "       Base VHDX created." -ForegroundColor Green
} else {
    Write-Host "[1/6] Base VHDX already cached." -ForegroundColor Green
}

# ============================================================
# STEP 2: Create VM disk from base image
# ============================================================
Write-Host "[2/6] Creating VM disk (${DiskSizeGB}GB)..." -ForegroundColor Yellow

Copy-Item $BaseVHDX $VHDX -Force
Resize-VHD -Path $VHDX -SizeBytes ($DiskSizeGB * 1GB)
Write-Host "       Disk ready." -ForegroundColor Green

# ============================================================
# STEP 3: Generate SSH keypair (if needed)
# ============================================================
if (-not $SSHPublicKey) {
    Write-Host "[3/6] Generating SSH keypair..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $SSHKeyDir -Force | Out-Null
    $keyFile = "$SSHKeyDir\$Name"

    # Remove existing key files if any (ssh-keygen won't overwrite)
    if (Test-Path $keyFile) { Remove-Item $keyFile -Force }
    if (Test-Path "$keyFile.pub") { Remove-Item "$keyFile.pub" -Force }

    # Generate ed25519 key with empty passphrase
    # Use """" for PowerShell to pass empty string to native command
    ssh-keygen -t ed25519 -f $keyFile -C "botfleet-$Name" -q -P """"

    if (-not (Test-Path "$keyFile.pub")) {
        Write-Error "SSH key generation failed. Make sure ssh-keygen is available (comes with Windows 10+)."
        exit 1
    }

    $SSHPublicKey = (Get-Content "$keyFile.pub").Trim()
    Write-Host "       Keys saved to: $SSHKeyDir" -ForegroundColor Green
    Write-Host "       ** Store private key in BWS, then delete local copy! **" -ForegroundColor Red
} else {
    Write-Host "[3/6] Using provided SSH public key." -ForegroundColor Green
}

# ============================================================
# STEP 4: Create cloud-init ISO
# ============================================================
Write-Host "[4/6] Building cloud-init config..." -ForegroundColor Yellow

$ciDir = "$VMDir\cidata"
if (Test-Path $ciDir) { Remove-Item $ciDir -Recurse -Force }
New-Item -ItemType Directory -Path $ciDir -Force | Out-Null

# meta-data (must be valid YAML)
$metaData = @"
instance-id: $Name
local-hostname: $Name
"@
[System.IO.File]::WriteAllText("$ciDir\meta-data", $metaData, [System.Text.UTF8Encoding]::new($false))

# user-data
$userData = @"
#cloud-config

hostname: $Name
manage_etc_hosts: true
timezone: America/Denver

users:
  - name: botadmin
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: botfleet
    ssh_authorized_keys:
      - $SSHPublicKey

ssh_pwauth: true
chpasswd:
  expire: false

package_update: true
package_upgrade: true
packages:
  - curl
  - wget
  - git
  - ufw
  - fail2ban
  - unattended-upgrades
  - apt-transport-https
  - ca-certificates
  - gnupg
  - jq
  - htop
  - tmux

runcmd:
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 22/tcp comment 'SSH'
  - ufw --force enable
  - systemctl enable fail2ban
  - systemctl start fail2ban
  - sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  - sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
  - sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  - sed -i 's/#MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
  - systemctl restart sshd
  - dpkg-reconfigure -plow unattended-upgrades
  - curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  - apt-get install -y nodejs
  - npm install -g openclaw
  - mkdir -p /home/botadmin/.openclaw/workspace
  - chown -R botadmin:botadmin /home/botadmin/.openclaw
  - echo "OpenClaw config will be injected by provisioner"
  - echo "Bot $Name provisioning complete" | tee /var/log/bot-provision.log

final_message: "Bot $Name is LIVE after \$UPTIME seconds."
"@
# Inject OpenClaw config into cloud-init if provided
if ($OpenClawConfig -and (Test-Path $OpenClawConfig)) {
    Write-Host "       Injecting OpenClaw config from: $OpenClawConfig" -ForegroundColor Cyan
    $configJson = (Get-Content $OpenClawConfig -Raw).Trim()
    # Indent config JSON for YAML embedding (each line gets 6 spaces)
    $indentedJson = ($configJson -split "`n" | ForEach-Object { "      $_" }) -join "`n"
    # Add write_files section before runcmd to write the config
    $writeFiles = @"

write_files:
  - path: /home/botadmin/.openclaw/openclaw.json
    owner: botadmin:botadmin
    permissions: '0644'
    content: |
$indentedJson

"@
    # Insert write_files before runcmd
    $userData = $userData -replace "runcmd:", ($writeFiles + "runcmd:")
    # Replace placeholder with gateway start commands
    $ocRuncmd = "  - su - botadmin -c 'openclaw gateway install' || true`n  - su - botadmin -c 'openclaw gateway start' || true"
    $userData = $userData -replace "  - echo `"OpenClaw config will be injected by provisioner`"", $ocRuncmd
} else {
    $userData = $userData -replace "  - echo `"OpenClaw config will be injected by provisioner`"", "  - echo `"No OpenClaw config provided. Run: openclaw init`""
}

[System.IO.File]::WriteAllText("$ciDir\user-data", $userData, [System.Text.UTF8Encoding]::new($false))

# network-config
if ($StaticIP) {
    $networkConfig = @"
version: 2
ethernets:
  eth0:
    dhcp4: false
    addresses:
      - $StaticIP/24
    routes:
      - to: default
        via: $Gateway
    nameservers:
      addresses: [$DNS]
"@
} else {
    $networkConfig = @"
version: 2
ethernets:
  eth0:
    dhcp4: true
"@
}
[System.IO.File]::WriteAllText("$ciDir\network-config", $networkConfig, [System.Text.UTF8Encoding]::new($false))

# Build cloud-init ISO
Write-Host "       Creating cloud-init ISO..." -ForegroundColor Yellow

# Find oscdimg (Windows ADK)
$oscdimgPath = $null
$adkSearchPaths = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
)

$oscdimgCmd = Get-Command "oscdimg" -ErrorAction SilentlyContinue
if ($oscdimgCmd) {
    $oscdimgPath = $oscdimgCmd.Source
} else {
    foreach ($p in $adkSearchPaths) {
        if (Test-Path $p) { $oscdimgPath = $p; break }
    }
}

if ($oscdimgPath) {
    Write-Host "       Using oscdimg: $oscdimgPath" -ForegroundColor Gray
    & $oscdimgPath -j2 -lCIDATA "$ciDir" "$CloudInitISO"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "oscdimg failed to create ISO."
        exit 1
    }
} else {
    # Fallback: try WSL + genisoimage
    $wslCmd = Get-Command "wsl" -ErrorAction SilentlyContinue
    if ($wslCmd) {
        Write-Host "       oscdimg not found, trying WSL + genisoimage..." -ForegroundColor Yellow

        # Convert Windows paths to WSL paths
        $ciDirWSL = wsl wslpath -a ($ciDir -replace '\\','/')
        $isoWSL = wsl wslpath -a ($CloudInitISO -replace '\\','/')

        # Install genisoimage if needed, then create ISO
        wsl bash -c "which genisoimage > /dev/null 2>&1 || sudo apt-get install -y genisoimage > /dev/null 2>&1"
        wsl genisoimage -output "$isoWSL" -volid CIDATA -joliet -rock "$ciDirWSL" 2>$null

        if ($LASTEXITCODE -ne 0) {
            Write-Error "genisoimage failed. Install Windows ADK: winget install Microsoft.WindowsADK"
            exit 1
        }
    } else {
        Write-Host ""
        Write-Host "  ERROR: No ISO creation tool found." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Install Windows ADK:" -ForegroundColor Yellow
        Write-Host "    winget install Microsoft.WindowsADK" -ForegroundColor White
        Write-Host ""
        Write-Host "  Or install WSL:" -ForegroundColor Yellow
        Write-Host "    wsl --install" -ForegroundColor White
        Write-Host ""
        exit 1
    }
}

if (-not (Test-Path $CloudInitISO)) {
    Write-Error "Cloud-init ISO was not created. Check errors above."
    exit 1
}

Write-Host "       Cloud-init ISO created." -ForegroundColor Green

# ============================================================
# STEP 5: Create and configure Hyper-V VM
# ============================================================
Write-Host "[5/6] Creating Hyper-V VM..." -ForegroundColor Yellow

New-VM -Name $Name `
    -MemoryStartupBytes $RAM `
    -VHDPath $VHDX `
    -Generation 2 `
    -SwitchName $SwitchName `
    -Path $VMPath

if ($StaticMemory) {
    Set-VM -Name $Name `
        -ProcessorCount $CPUs `
        -StaticMemory `
        -AutomaticStartAction Start `
        -AutomaticStopAction ShutDown `
        -CheckpointType Standard
} else {
    Set-VM -Name $Name `
        -ProcessorCount $CPUs `
        -DynamicMemory `
        -MemoryMinimumBytes ([math]::Max($RAM / 2, 2GB)) `
        -MemoryMaximumBytes $RAM `
        -AutomaticStartAction Start `
        -AutomaticStopAction ShutDown `
        -CheckpointType Standard
}

# Disable Secure Boot (required for Ubuntu cloud image — no Microsoft UEFI keys)
Set-VMFirmware -VMName $Name -EnableSecureBoot Off

# Attach cloud-init ISO as DVD
Add-VMDvdDrive -VMName $Name -Path $CloudInitISO

# Set boot order: HDD first, then DVD
$hdd = Get-VMHardDiskDrive -VMName $Name
$dvd = Get-VMDvdDrive -VMName $Name
Set-VMFirmware -VMName $Name -BootOrder $hdd, $dvd

# Enable guest integration services
Enable-VMIntegrationService -VMName $Name -Name "Guest Service Interface" -ErrorAction SilentlyContinue

Write-Host "       VM created and configured." -ForegroundColor Green

# ============================================================
# STEP 6: Start VM
# ============================================================
Write-Host "[6/6] Starting VM..." -ForegroundColor Yellow
Start-VM -Name $Name

# Wait a moment then try to get IP
Write-Host ""
Write-Host "       Waiting for VM to get an IP address..." -ForegroundColor Yellow
$ip = $null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 5
    $adapter = Get-VMNetworkAdapter -VMName $Name
    $ips = $adapter.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
    if ($ips) {
        $ip = $ips[0]
        break
    }
    Write-Host "       ... still waiting ($($i * 5)s)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Phoenix is ALIVE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

if ($ip) {
    Write-Host "  IP Address: $ip" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  SSH in (after cloud-init finishes, ~3-5 min):" -ForegroundColor White
    Write-Host "    ssh -i `"$SSHKeyDir\$Name`" botadmin@$ip" -ForegroundColor Yellow
} else {
    Write-Host "  IP not assigned yet. Check manually:" -ForegroundColor Yellow
    Write-Host "    Get-VMNetworkAdapter -VMName $Name | Select IPAddresses" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Then SSH in:" -ForegroundColor White
    Write-Host "    ssh -i `"$SSHKeyDir\$Name`" botadmin@<IP>" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Cloud-init is still installing packages (~3-5 min)." -ForegroundColor Cyan
Write-Host "  Check progress after SSH:" -ForegroundColor Cyan
Write-Host "    sudo cloud-init status --wait" -ForegroundColor Gray
Write-Host "    cat /var/log/cloud-init-output.log" -ForegroundColor Gray
Write-Host ""
if ($OpenClawConfig) {
    Write-Host "  OpenClaw config injected — gateway will start automatically!" -ForegroundColor Green
} else {
    Write-Host "  Then configure OpenClaw:" -ForegroundColor White
    Write-Host "    openclaw init" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  SSH private key: $SSHKeyDir\$Name" -ForegroundColor Red
Write-Host "  ** STORE IN BWS, THEN DELETE LOCAL COPY **" -ForegroundColor Red
Write-Host ""

# Save VM info for inventory
$summary = @{
    Name       = $Name
    RAM        = "$($RAM / 1GB)GB"
    CPUs       = $CPUs
    Disk       = "${DiskSizeGB}GB"
    VHDX       = $VHDX
    IP         = $(if ($ip) { $ip } else { "pending" })
    SSHKeyPath = "$SSHKeyDir\$Name"
    SSHUser    = "botadmin"
    Switch     = $SwitchName
    Created    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Status     = "Provisioning"
}

$summary | ConvertTo-Json | Set-Content "$VMDir\vm-info.json"
Write-Host "  VM info saved: $VMDir\vm-info.json" -ForegroundColor Gray
Write-Host ""
