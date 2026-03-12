<#
.SYNOPSIS
    Provisions a new Ubuntu 24.04 VM on Hyper-V for running OpenClaw bots.

.DESCRIPTION
    Downloads Ubuntu cloud image (first run only), creates a cloud-init ISO,
    spins up a Gen 2 Hyper-V VM, and boots it. Cloud-init handles all
    post-boot configuration: user creation, SSH keys, Node.js, OpenClaw,
    security hardening.

.PARAMETER Name
    VM name (e.g., "fleet-manager", "sales-bot-01")

.PARAMETER RAM
    Memory in bytes. Default: 4GB

.PARAMETER CPUs
    Virtual processors. Default: 2

.PARAMETER DiskSizeGB
    OS disk size in GB. Default: 30

.PARAMETER VMPath
    Base path for VM files. Default: C:\HyperV\BotFleet

.PARAMETER SwitchName
    Hyper-V virtual switch name. Default: "Default Switch"

.PARAMETER SSHPublicKey
    SSH public key for the admin user. If not provided, generates a new keypair.

.EXAMPLE
    .\New-BotVM.ps1 -Name "fleet-manager"
    .\New-BotVM.ps1 -Name "sales-bot-01" -RAM 2GB -CPUs 2
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Name,

    [int64]$RAM = 4GB,

    [int]$CPUs = 2,

    [int]$DiskSizeGB = 30,

    [string]$VMPath = "D:\BotFleet",

    [string]$SwitchName = "Broadcom NetXtreme Gigabit Ethernet #2 - Virtual Switch",

    [string]$SSHPublicKey = ""
)

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIG — Edit these paths for your environment
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
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Bot Fleet Provisioner" -ForegroundColor Cyan
Write-Host " Creating: $Name" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check Hyper-V
if (-not (Get-Command "New-VM" -ErrorAction SilentlyContinue)) {
    Write-Error "Hyper-V PowerShell module not found. Enable Hyper-V first."
    exit 1
}

# Check virtual switch exists
$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $switch) {
    Write-Host "Available switches:" -ForegroundColor Yellow
    Get-VMSwitch | Format-Table Name, SwitchType
    Write-Error "Virtual switch '$SwitchName' not found. Specify -SwitchName or create one."
    exit 1
}

# Check VM doesn't already exist
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    Write-Error "VM '$Name' already exists. Remove it first or pick a different name."
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

        # Use BITS for reliable download with progress
        Start-BitsTransfer -Source $CloudImageURL -Destination $CloudImageFile -DisplayName "Ubuntu 24.04 Cloud Image"
        Write-Host "       Download complete." -ForegroundColor Green
    } else {
        Write-Host "[1/6] Ubuntu cloud image already cached." -ForegroundColor Green
    }

    # Convert .img to .vhdx
    Write-Host "[1/6] Converting cloud image to VHDX..." -ForegroundColor Yellow

    # Check for qemu-img
    $qemuImg = Get-Command "qemu-img" -ErrorAction SilentlyContinue
    if (-not $qemuImg) {
        # Try common install locations
        $qemuPaths = @(
            "C:\Program Files\qemu\qemu-img.exe",
            "C:\qemu\qemu-img.exe",
            "$env:ProgramFiles\qemu\qemu-img.exe"
        )
        foreach ($p in $qemuPaths) {
            if (Test-Path $p) { $qemuImg = $p; break }
        }
    } else {
        $qemuImg = $qemuImg.Source
    }

    if (-not $qemuImg) {
        Write-Host ""
        Write-Host "  qemu-img not found. Install it:" -ForegroundColor Red
        Write-Host "    winget install SoftwareFreedomConservancy.QEMU" -ForegroundColor Yellow
        Write-Host "  Or download from: https://qemu.weilnetz.de/w64/" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  After installing, run this script again." -ForegroundColor Red
        exit 1
    }

    & $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic $CloudImageFile $BaseVHDX
    Write-Host "       Base VHDX created." -ForegroundColor Green
} else {
    Write-Host "[1/6] Base VHDX already cached." -ForegroundColor Green
}

# ============================================================
# STEP 2: Create VM disk from base image
# ============================================================
Write-Host "[2/6] Creating VM disk (${DiskSizeGB}GB)..." -ForegroundColor Yellow

Copy-Item $BaseVHDX $VHDX
Resize-VHD -Path $VHDX -SizeBytes ($DiskSizeGB * 1GB)
Write-Host "       Disk ready." -ForegroundColor Green

# ============================================================
# STEP 3: Generate SSH keypair (if needed)
# ============================================================
if (-not $SSHPublicKey) {
    Write-Host "[3/6] Generating SSH keypair..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $SSHKeyDir -Force | Out-Null
    $keyFile = "$SSHKeyDir\$Name"

    # Generate ed25519 key (no passphrase for automation)
    ssh-keygen -t ed25519 -f $keyFile -N '""' -C "botfleet-$Name" -q
    $SSHPublicKey = Get-Content "$keyFile.pub"
    Write-Host "       Keys saved to: $SSHKeyDir" -ForegroundColor Green
    Write-Host "       IMPORTANT: Store private key in BWS, then delete local copy." -ForegroundColor Red
} else {
    Write-Host "[3/6] Using provided SSH public key." -ForegroundColor Green
}

# ============================================================
# STEP 4: Create cloud-init ISO
# ============================================================
Write-Host "[4/6] Building cloud-init config..." -ForegroundColor Yellow

$ciDir = "$VMDir\cidata"
New-Item -ItemType Directory -Path $ciDir -Force | Out-Null

# meta-data
@"
instance-id: $Name
local-hostname: $Name
"@ | Set-Content "$ciDir\meta-data" -Encoding UTF8 -NoNewline

# user-data (the big one)
@"
#cloud-config

hostname: $Name
manage_etc_hosts: true
timezone: America/Denver

# Create admin user (no password login — SSH key only)
users:
  - name: botadmin
    groups: [sudo, docker]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $SSHPublicKey

# Disable password SSH
ssh_pwauth: false

# Package management
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
  - python3-pip

# Run commands after boot
runcmd:
  # ---- SECURITY HARDENING ----
  # UFW firewall
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 22/tcp comment 'SSH'
  - ufw --force enable

  # Fail2ban
  - systemctl enable fail2ban
  - systemctl start fail2ban

  # SSH hardening
  - sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  - sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  - sed -i 's/#MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
  - sed -i 's/#ClientAliveInterval.*/ClientAliveInterval 300/' /etc/ssh/sshd_config
  - systemctl restart sshd

  # Auto security updates
  - dpkg-reconfigure -plow unattended-upgrades

  # ---- NODE.JS 22 LTS ----
  - curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  - apt-get install -y nodejs

  # ---- OPENCLAW ----
  - npm install -g openclaw

  # ---- BITWARDEN SECRETS CLI ----
  - curl -fsSL https://github.com/nicholasgasior/bws-cli/releases/latest/download/bws-linux-x86_64 -o /usr/local/bin/bws || true
  - chmod +x /usr/local/bin/bws || true

  # ---- CREATE OPENCLAW WORKSPACE ----
  - mkdir -p /home/botadmin/.openclaw/workspace
  - |
    cat > /home/botadmin/.openclaw/workspace/SOUL.md << 'SOUL'
    # SOUL.md
    You are a sales bot in the Humming Agent fleet.
    Your job is to prospect, enrich leads, and execute outreach.
    Be resourceful. Be persistent. Report results.
    SOUL
  - chown -R botadmin:botadmin /home/botadmin/.openclaw

  # ---- DONE ----
  - echo "=== Bot $Name provisioning complete ===" | tee /var/log/bot-provision.log

# Phone home when done
final_message: "Bot $Name is LIVE. Boot took \$UPTIME seconds."

power_state:
  mode: reboot
  condition: true
  timeout: 30
"@ | Set-Content "$ciDir\user-data" -Encoding UTF8 -NoNewline

# network-config (DHCP)
@"
version: 2
ethernets:
  eth0:
    dhcp4: true
"@ | Set-Content "$ciDir\network-config" -Encoding UTF8 -NoNewline

# Build ISO using oscdimg (part of Windows ADK) or mkisofs
Write-Host "       Creating cloud-init ISO..." -ForegroundColor Yellow

# Try oscdimg first (Windows ADK)
$oscdimg = Get-Command "oscdimg" -ErrorAction SilentlyContinue
if (-not $oscdimg) {
    $adkPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    foreach ($p in $adkPaths) {
        if (Test-Path $p) { $oscdimg = $p; break }
    }
}

if ($oscdimg) {
    $oscdimgPath = if ($oscdimg -is [string]) { $oscdimg } else { $oscdimg.Source }
    & $oscdimgPath -j2 -lCIDATA "$ciDir" $CloudInitISO
} else {
    # Fallback: Use PowerShell to create ISO (no external tools needed)
    Write-Host "       oscdimg not found, using PowerShell ISO builder..." -ForegroundColor Yellow

    # Inline ISO creator using .NET
    $isoCreatorCode = @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public class ISOBuilder {
    public static void CreateISO(string sourcePath, string isoPath, string volumeLabel) {
        // Use IMAPI2 COM interface
        Type imageType = Type.GetTypeFromProgID("IMAPI2FS.MsftFileSystemImage");
        dynamic image = Activator.CreateInstance(imageType);
        image.FileSystemsToCreate = 2; // ISO 9660 + Joliet
        image.VolumeName = volumeLabel;

        dynamic rootDir = image.Root;
        foreach (string file in Directory.GetFiles(sourcePath)) {
            dynamic stream = Activator.CreateInstance(Type.GetTypeFromProgID("ADODB.Stream"));
            stream.Open();
            stream.Type = 1; // Binary
            stream.LoadFromFile(file);
            rootDir.AddFile(Path.GetFileName(file), stream);
        }

        dynamic result = image.CreateResultImage();
        dynamic isoStream = result.ImageStream;

        // Write to file
        IStream managedStream = (IStream)isoStream;
        byte[] buf = new byte[65536];
        using (FileStream fs = new FileStream(isoPath, FileMode.Create)) {
            int bytesRead;
            do {
                managedStream.Read(buf, buf.Length, IntPtr.Zero);
                // Check how many bytes were actually read
                fs.Write(buf, 0, buf.Length);
            } while (false);
        }
    }
}
"@

    # Simpler approach: use xorriso via WSL if available, or just tell user to install ADK
    $wsl = Get-Command "wsl" -ErrorAction SilentlyContinue
    if ($wsl) {
        $ciDirWSL = ($ciDir -replace '\\','/') -replace '^C:','/mnt/c'
        $isoWSL = ($CloudInitISO -replace '\\','/') -replace '^C:','/mnt/c'
        wsl genisoimage -output $isoWSL -volid CIDATA -joliet -rock $ciDirWSL 2>$null
        if ($LASTEXITCODE -ne 0) {
            wsl sudo apt-get install -y genisoimage 2>$null
            wsl genisoimage -output $isoWSL -volid CIDATA -joliet -rock $ciDirWSL
        }
    } else {
        Write-Host ""
        Write-Host "  Need one of these to create the cloud-init ISO:" -ForegroundColor Red
        Write-Host "    Option A: Install Windows ADK (includes oscdimg)" -ForegroundColor Yellow
        Write-Host "      winget install Microsoft.WindowsADK" -ForegroundColor Yellow
        Write-Host "    Option B: WSL with genisoimage" -ForegroundColor Yellow
        Write-Host "      wsl --install" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

Write-Host "       Cloud-init ISO created." -ForegroundColor Green

# ============================================================
# STEP 5: Create and configure Hyper-V VM
# ============================================================
Write-Host "[5/6] Creating Hyper-V VM..." -ForegroundColor Yellow

# Create VM
New-VM -Name $Name `
    -MemoryStartupBytes $RAM `
    -VHDPath $VHDX `
    -Generation 2 `
    -SwitchName $SwitchName `
    -Path $VMPath

# Configure VM
Set-VM -Name $Name `
    -ProcessorCount $CPUs `
    -DynamicMemory `
    -MemoryMinimumBytes 1GB `
    -MemoryMaximumBytes $RAM `
    -AutomaticStartAction Start `
    -AutomaticStopAction ShutDown `
    -CheckpointType Standard

# Disable Secure Boot (required for Ubuntu cloud image)
Set-VMFirmware -VMName $Name -EnableSecureBoot Off

# Attach cloud-init ISO
Add-VMDvdDrive -VMName $Name -Path $CloudInitISO

# Set boot order: HDD first, then DVD
$hdd = Get-VMHardDiskDrive -VMName $Name
$dvd = Get-VMDvdDrive -VMName $Name
Set-VMFirmware -VMName $Name -BootOrder $hdd, $dvd

# Enable guest services (for file copy, heartbeat)
Enable-VMIntegrationService -VMName $Name -Name "Guest Service Interface"

Write-Host "       VM created and configured." -ForegroundColor Green

# ============================================================
# STEP 6: Start VM
# ============================================================
Write-Host "[6/6] Starting VM..." -ForegroundColor Yellow
Start-VM -Name $Name

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " VM '$Name' is BOOTING" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host " Cloud-init is now:" -ForegroundColor Cyan
Write-Host "   - Updating packages" -ForegroundColor Cyan
Write-Host "   - Installing Node.js 22 + OpenClaw" -ForegroundColor Cyan
Write-Host "   - Hardening SSH + UFW + Fail2ban" -ForegroundColor Cyan
Write-Host "   - Setting up workspace" -ForegroundColor Cyan
Write-Host ""
Write-Host " This takes 3-5 minutes. Then:" -ForegroundColor Yellow
Write-Host ""
Write-Host "   1. Get the VM's IP:" -ForegroundColor White
Write-Host "      Get-VMNetworkAdapter -VMName $Name | Select IPAddresses" -ForegroundColor Gray
Write-Host ""
Write-Host "   2. SSH in:" -ForegroundColor White
Write-Host "      ssh -i `"$SSHKeyDir\$Name`" botadmin@<IP>" -ForegroundColor Gray
Write-Host ""
Write-Host "   3. Check provisioning log:" -ForegroundColor White
Write-Host "      cat /var/log/cloud-init-output.log" -ForegroundColor Gray
Write-Host ""
Write-Host "   4. Configure OpenClaw:" -ForegroundColor White
Write-Host "      openclaw init" -ForegroundColor Gray
Write-Host ""
Write-Host " SSH private key: $SSHKeyDir\$Name" -ForegroundColor Red
Write-Host " Store this in BWS immediately, then delete the local copy." -ForegroundColor Red
Write-Host ""

# Output summary for inventory
$summary = @{
    Name = $Name
    RAM = "$($RAM / 1GB)GB"
    CPUs = $CPUs
    Disk = "${DiskSizeGB}GB"
    VHDX = $VHDX
    SSHKey = "$SSHKeyDir\$Name"
    Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Status = "Provisioning"
}

$summary | ConvertTo-Json | Set-Content "$VMDir\vm-info.json"
Write-Host " VM info saved to: $VMDir\vm-info.json" -ForegroundColor Gray
