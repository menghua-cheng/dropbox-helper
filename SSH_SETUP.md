# SSH/SCP Setup Guide for Remote NAS Backup

This guide explains how to configure the Dropbox Helper to backup files to a remote NAS using **SCP (Secure Copy)** over SSH.

## How It Works

The tool uses **SCP** (part of OpenSSH) to transfer files securely to your NAS:
- **No additional software required** - Uses built-in Windows OpenSSH SCP
- **Automatic space handling** - Uses hex-encoded transfer for paths with spaces
- **File validation** - Verifies file size after transfer
- **Cached connections** - Creates remote directories once and caches them

---

## Prerequisites

### OpenSSH Client (Built-in Windows 10/11)

OpenSSH Client is pre-installed on Windows 10 (version 1809+) and Windows 11.

**Verify installation:**
```powershell
ssh -V
scp
```

**If not installed:**
```powershell
# Check if available
Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Client*'

# Install if needed (run as Administrator)
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

---

## Setup SSH Key Authentication

### 1. Generate SSH Key Pair

```powershell
# Generate RSA key pair
ssh-keygen -t rsa -b 4096 -C "dropbox-helper@$(hostname)"

# Save to default location: C:\Users\YourName\.ssh\id_rsa
# Press Enter for no passphrase (or set one for extra security)
```

### 2. Copy Public Key to NAS

**Method 1: Using ssh-copy-id** (if available):
```powershell
ssh-copy-id user1@192.168.1.120
```

**Method 2: Manual copy** (Windows):
```powershell
type $env:USERPROFILE\.ssh\id_rsa.pub | ssh user1@192.168.1.120 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

**Method 3: GUI method:**
1. Open: `C:\Users\YourName\.ssh\id_rsa.pub` in Notepad
2. Copy the entire content
3. SSH to your NAS: `ssh user1@192.168.1.120`
4. Run: `nano ~/.ssh/authorized_keys`
5. Paste the key, save and exit

### 3. Set Correct Permissions on NAS

```bash
# SSH to your NAS
ssh user1@192.168.1.120

# Set permissions
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

### 4. Test SSH Connection

```powershell
# Test passwordless SSH
ssh user1@192.168.1.120 "echo 'Connection successful'"

# Should connect without asking for password
```

---

## Configuration

### Configure Dropbox Helper for SSH/SCP

**Method 1: Using PowerShell commands:**

```powershell
. .\dropbox-helper.ps1

Set-Configuration -Settings @{
    TransportMethod = 'SSH'
    SSHHost = '192.168.1.120'
    SSHUser = 'user1'
    SSHPort = 22
    SSHKeyPath = '%USERPROFILE%\.ssh\id_rsa'
    SSHRemotePath = '/volume1/photos/camera-uploads/'
} -Confirm:$false
```

**Method 2: Edit config file directly:**

Location: `%APPDATA%\DropboxHelper\config.json`

```json
{
  "TransportMethod": "SSH",
  "SSHHost": "192.168.1.120",
  "SSHUser": "user1",
  "SSHPort": 22,
  "SSHKeyPath": "%USERPROFILE%\\.ssh\\id_rsa",
  "SSHRemotePath": "/volume1/photos/camera-uploads/"
}
```

### Configuration Options

| Option | Description | Example |
|--------|-------------|---------|
| `TransportMethod` | Must be `"SSH"` for remote backup | `"SSH"` |
| `SSHHost` | IP address or hostname of NAS | `"192.168.1.120"` or `"nas.local"` |
| `SSHUser` | SSH username on NAS | `"user1"` |
| `SSHPort` | SSH port (default 22) | `22` |
| `SSHKeyPath` | Path to private SSH key | `"%USERPROFILE%\\.ssh\\id_rsa"` |
| `SSHRemotePath` | Destination path on NAS | `"/volume1/photos/"` |

### Example Configurations

**Basic Configuration:**
```json
{
  "TransportMethod": "SSH",
  "SSHHost": "192.168.1.120",
  "SSHUser": "backup",
  "SSHKeyPath": "%USERPROFILE%\\.ssh\\id_rsa",
  "SSHRemotePath": "/volume1/photos/"
}
```

**Custom SSH Port:**
```json
{
  "TransportMethod": "SSH",
  "SSHHost": "nas.mydomain.com",
  "SSHUser": "backupuser",
  "SSHPort": 2222,
  "SSHKeyPath": "%USERPROFILE%\\.ssh\\nas_key",
  "SSHRemotePath": "/backups/iphone/"
}
```

**Path with Spaces (automatically handled):**
```json
{
  "SSHRemotePath": "/volume1/photo/Dropbox Camera Uploads/"
}
```

---

## Testing

### 1. Validate Configuration

```powershell
. .\dropbox-helper.ps1

# Run comprehensive validation
Test-DropboxHelperSetup -Verbose
```

Expected output:
```
[PASS] SSH Connection
[PASS] SCP Available
[PASS] Remote Path Accessible
```

### 2. Test Manual Transfer

```powershell
# Create a test file
"Test content" | Out-File "$env:USERPROFILE\Dropbox\Camera Uploads\test.txt"

# Start the helper and watch it transfer
Start-DropboxHelper -ShowProgress -Verbose
```

### 3. Verify on NAS

```bash
# SSH to NAS
ssh user1@192.168.1.120

# Check if files arrived
ls -la "/volume1/photos/"
```

---

## Common NAS Paths

| NAS Brand | Typical Path |
|-----------|--------------|
| Synology | `/volume1/photos/` or `/volume1/photo/` |
| QNAP | `/share/Multimedia/Photos/` or `/share/Photo/` |
| Unraid | `/mnt/user/Photos/` or `/mnt/user/Media/` |
| TrueNAS | `/mnt/tank/photos/` |
| Generic Linux | `/home/user/photos/` |

---

## How SCP Transfer Works

The tool automatically handles different scenarios:

### For paths WITHOUT spaces:
```
Standard SCP: scp -P 22 -i "C:\Users\...\id_rsa" "C:\...\photo.jpg" user@host:/path/
```
- Fast and efficient
- Uses native SCP protocol
- Optimized with fast ciphers and no compression

### For paths WITH spaces:
```
Hex-encoded SSH: cat binary_hex_data | ssh user@host "cat | xxd -r -p > '/path with spaces/photo.jpg'"
```
- Binary-safe transfer
- Handles spaces and special characters
- Slightly slower but reliable

### Validation:
```
SSH: ssh user@host "ls -al '/path/photo.jpg'"
```
- Verifies file size matches
- Ensures transfer integrity

---

## Troubleshooting

### SSH Connection Failed

**Test SSH manually:**
```powershell
ssh user1@192.168.1.120 "echo 'test'"
```

**Check SSH service on NAS:**
```bash
# On NAS
sudo systemctl status sshd
# or
sudo service ssh status
```

**Check firewall:**
```bash
# On NAS, check if port 22 is open
sudo netstat -tulpn | grep :22
```

### Permission Denied (publickey)

**Verify SSH key exists:**
```powershell
Test-Path "$env:USERPROFILE\.ssh\id_rsa"
Get-Content "$env:USERPROFILE\.ssh\id_rsa.pub"
```

**Check key permissions on Windows:**
```powershell
icacls "$env:USERPROFILE\.ssh\id_rsa"
# Should show only your username with read access
```

**Verify key is on NAS:**
```bash
# On NAS
cat ~/.ssh/authorized_keys
# Should contain your public key
```

**Check NAS SSH configuration:**
```bash
# On NAS, verify /etc/ssh/sshd_config:
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
```

### SCP Not Found

SCP is part of OpenSSH Client. Install it:

```powershell
# Run as Administrator
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

### Remote Path Not Accessible

**Test if path exists:**
```bash
ssh user1@192.168.1.120 "ls -la '/volume1/photos/'"
```

**Create directory:**
```bash
ssh user1@192.168.1.120 "mkdir -p '/volume1/photos/camera-uploads/'"
```

**Check write permissions:**
```bash
ssh user1@192.168.1.120 "touch '/volume1/photos/test.txt' && rm '/volume1/photos/test.txt'"
```

### Transfer is Slow

**For fast local networks (1Gbps+), skip validation:**
```powershell
Set-Configuration -Settings @{
    SkipSizeValidation = $true
} -Confirm:$false
```

The tool uses optimized settings for LAN transfers:
- `aes128-gcm@openssh.com` (fast cipher)
- `Compression=no` (disabled for already-compressed media files)

### Paths with Spaces Don't Work

The tool automatically handles spaces. If issues persist:

1. Check logs:
```powershell
Get-Content "$env:APPDATA\DropboxHelper\logs\dropbox-helper_$(Get-Date -Format 'yyyyMMdd').log" -Tail 50
```

2. Verify `xxd` is available on NAS:
```bash
ssh user1@192.168.1.120 "which xxd"
```

---

## Security Best Practices

✅ **Use SSH Keys** - Never use password authentication  
✅ **Protect Private Key** - Set proper file permissions  
✅ **Use Non-Standard Port** - Change SSH port from 22  
✅ **Dedicated User** - Create specific backup user with limited permissions  
✅ **Disable Password Auth** - On NAS: `PasswordAuthentication no`  
✅ **Firewall Rules** - Limit SSH access to known IPs  

**Set restrictive key permissions:**
```powershell
# Remove inheritance and grant only your user access
icacls "$env:USERPROFILE\.ssh\id_rsa" /inheritance:r
icacls "$env:USERPROFILE\.ssh\id_rsa" /grant:r "$env:USERNAME:(R)"
```

---

## NAS-Specific Setup

### Synology DSM
```json
{
  "SSHHost": "192.168.1.120",
  "SSHUser": "admin",
  "SSHRemotePath": "/volume1/photo/iPhone/"
}
```
- Enable SSH: Control Panel > Terminal & SNMP > Enable SSH

### QNAP
```json
{
  "SSHHost": "192.168.1.120",
  "SSHUser": "admin",
  "SSHRemotePath": "/share/Photo/iPhone/"
}
```
- Enable SSH: Control Panel > Telnet / SSH

### Unraid
```json
{
  "SSHHost": "192.168.1.120",
  "SSHUser": "root",
  "SSHRemotePath": "/mnt/user/Media/Photos/"
}
```
- SSH enabled by default

---

## Monitoring

**View transfer logs:**
```powershell
Get-Content "$env:APPDATA\DropboxHelper\logs\dropbox-helper_$(Get-Date -Format 'yyyyMMdd').log" | Select-String "SSH|SCP|Transfer"
```

**Healthy log entries:**
- `[INFO] SSH connection successful`
- `[INFO] Transferring via SCP`
- `[INFO] Transfer validated successfully`
- `[INFO] Removed source file`

---

## Complete Setup Example

```powershell
# 1. Generate SSH key
ssh-keygen -t rsa -b 4096

# 2. Copy to NAS
type $env:USERPROFILE\.ssh\id_rsa.pub | ssh user1@192.168.1.120 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"

# 3. Test
ssh user1@192.168.1.120 "echo 'Works!'"

# 4. Configure
. .\dropbox-helper.ps1
Set-Configuration -Settings @{
    TransportMethod = 'SSH'
    SSHHost = '192.168.1.120'
    SSHUser = 'user1'
    SSHKeyPath = '%USERPROFILE%\.ssh\id_rsa'
    SSHRemotePath = '/volume1/photos/'
} -Confirm:$false

# 5. Validate
Test-DropboxHelperSetup

# 6. Start
Install-DropboxHelperTask
Start-DropboxHelperTask
```

---

**Your photos will now automatically backup to your NAS via secure SSH/SCP!** 🚀 📸 🔐
