# Bot Fleet — Setup Guide

## Prerequisites (One-Time)

Before running the script, your Hyper-V host needs:

### 1. qemu-img (converts Ubuntu cloud image to VHDX)
```powershell
winget install SoftwareFreedomConservancy.QEMU
```

### 2. Cloud-init ISO tool (one of these)

**Option A — Windows ADK (recommended):**
```powershell
winget install Microsoft.WindowsADK
```

**Option B — WSL:**
```powershell
wsl --install
# then inside WSL:
sudo apt-get install genisoimage
```

### 3. Hyper-V Virtual Switch
If you don't already have one:
```powershell
# Check existing switches
Get-VMSwitch

# Create an external switch (connects VMs to your LAN)
New-VMSwitch -Name "BotFleet" -NetAdapterName "Ethernet" -AllowManagementOS $true
```
Replace `"Ethernet"` with your actual network adapter name (`Get-NetAdapter` to list them).

---

## Provision Your First Bot

### Step 1: Run the script
```powershell
cd C:\path\to\bot-fleet
.\New-BotVM.ps1 -Name "fleet-manager" -SwitchName "Default Switch"
```

Change `"Default Switch"` to whatever your switch is named.

### Step 2: Wait 3-5 minutes
Cloud-init is installing everything. You can watch from Hyper-V Manager console.

### Step 3: Get the IP
```powershell
Get-VMNetworkAdapter -VMName "fleet-manager" | Select IPAddresses
```

### Step 4: SSH in
```powershell
ssh -i "C:\HyperV\BotFleet\fleet-manager\ssh\fleet-manager" botadmin@<IP>
```

### Step 5: Verify everything installed
```bash
# Check Node.js
node --version    # Should show v22.x

# Check OpenClaw
openclaw --version

# Check firewall
sudo ufw status   # Should show active, SSH allowed

# Check cloud-init finished
cat /var/log/cloud-init-output.log | tail -20
```

### Step 6: Configure OpenClaw
```bash
openclaw init
```
This walks you through:
- API key (Claude, etc.)
- Channel connections (Signal, Slack)
- Identity setup

### Step 7: Store SSH key in BWS
On your Windows machine:
```powershell
# Read the private key and store in BWS
$key = Get-Content "C:\HyperV\BotFleet\fleet-manager\ssh\fleet-manager" -Raw
# Use BWS CLI to store it (adjust project ID)
bws secret create "bot/fleet-manager/ssh-key" "$key" --project-id <YOUR_PROJECT_ID>

# Then delete the local copy
Remove-Item "C:\HyperV\BotFleet\fleet-manager\ssh\fleet-manager"
```

### Step 8: Store VM IP in BWS
```powershell
$ip = (Get-VMNetworkAdapter -VMName "fleet-manager").IPAddresses[0]
bws secret create "bot/fleet-manager/ip" "$ip" --project-id <YOUR_PROJECT_ID>
```

---

## Provision More Bots

Once fleet-manager is running, use the same script:
```powershell
.\New-BotVM.ps1 -Name "sales-bot-01" -RAM 2GB -CPUs 2
.\New-BotVM.ps1 -Name "sales-bot-02" -RAM 2GB -CPUs 2
.\New-BotVM.ps1 -Name "research-bot-01" -RAM 4GB -CPUs 4
```

---

## Customization

### Change VM defaults
Edit the top of `New-BotVM.ps1`:
- `$VMPath` — where VMs live on disk
- `$SwitchName` — your Hyper-V switch
- RAM/CPU defaults

### Change what gets installed
Edit the `user-data` section in the script:
- Add packages to the `packages:` list
- Add commands to `runcmd:`
- Change the default SOUL.md

### Static IP instead of DHCP
Edit the `network-config` in the script:
```yaml
version: 2
ethernets:
  eth0:
    addresses: [192.168.1.100/24]
    gateway4: 192.168.1.1
    nameservers:
      addresses: [8.8.8.8, 8.8.4.4]
```

---

## Troubleshooting

### VM won't boot
- Check Secure Boot is off: `Get-VMFirmware -VMName "name"`
- Check boot order: HDD should be first

### Can't get IP
- Wait longer (DHCP can take a minute)
- Check VM is connected to switch: `Get-VMNetworkAdapter -VMName "name"`
- Try: `vmconnect localhost "name"` to see the console

### Cloud-init didn't run
- Check ISO is attached: `Get-VMDvdDrive -VMName "name"`
- Console in and check: `sudo cloud-init status --long`

### SSH connection refused
- Cloud-init might still be running (wait)
- Check: `sudo systemctl status sshd` from Hyper-V console
