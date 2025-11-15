# Dropbox Camera Upload Auto-Offload Tool

## 📋 Table of Contents
- [What This Tool Does](#what-this-tool-does)
- [Quick Start](#quick-start)
- [Usage Modes](#usage-modes)
- [Requirements](#requirements)
- [Installation & Setup](#installation--setup)
- [Configuration](#configuration)
- [Backup Locations](#backup-locations)
- [SSH/SCP Remote Backup](#sshscp-remote-backup)
- [Service Management](#service-management)
- [Monitoring & Logs](#monitoring--logs)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Advanced Usage](#advanced-usage)

---

## 🎯 What This Tool Does

The **Dropbox Camera Upload Auto-Offload Tool** solves a common problem: **keeping your iPhone photos/videos backed up via Dropbox without filling up your Dropbox storage**.

### The Problem

1. Your **iPhone** automatically uploads photos/videos to Dropbox Camera Uploads
2. These files **sync** to your Windows computer  
3. But they **keep taking up** Dropbox storage quota
4. Result: Your **Dropbox fills up** and you must manually delete files

### The Solution

This tool automatically:
1. **Monitors** your Dropbox Camera Uploads folder in real-time
2. **Waits** for files to finish syncing completely
3. **Moves** them to your backup location (local/NAS/remote server)
4. **Frees** Dropbox space automatically
5. **Preserves** your complete photo/video backup

### Key Benefits

✅ **Never run out of Dropbox space** - Files moved after syncing  
✅ **Complete backups** - All photos/videos safely stored  
✅ **Set and forget** - Runs automatically in background  
✅ **Safe and reliable** - File integrity validation  
✅ **Flexible storage** - Local drives, NAS, or SSH/SCP remote  
✅ **No cloud fees** - Your files, your storage, your control  
✅ **Handles spaces in paths** - Works with any folder structure  
✅ **Smart conflict resolution** - No file overwrites  

### Key Features

- **Real-time Monitoring** - FileSystemWatcher for instant detection
- **Smart Sync Detection** - Multiple checks ensure files are fully synced
- **Pre-flight Validation** - Creates/validates remote directories before transfer
- **Multiple Transfer Methods** - Automatic fallback for paths with spaces
- **File Integrity Checks** - Size validation after transfer
- **Background Service** - Runs as Windows scheduled task
- **Comprehensive Logging** - Track all operations and errors
- **Statistics Tracking** - Monitor files processed and data moved

---

## ⚡ Quick Start

### Three Simple Steps

**1. Download the Script**
```powershell
# Save dropbox-helper.ps1 to a permanent location
# Example: C:\Tools\DropboxHelper\
```

**2. Test It (One-Time Use)**
```powershell
# Navigate to script folder
cd C:\Tools\DropboxHelper

# Load the script functions
. .\dropbox-helper.ps1

# Create default configuration
Initialize-Configuration

# Run pre-flight validation
Test-DropboxHelperSetup

# Start monitoring (press Ctrl+C to stop)
Start-DropboxHelper -Verbose
```

**3. Install as Service (Recommended)**
```powershell
# Open PowerShell as Administrator
cd C:\Tools\DropboxHelper
. .\dropbox-helper.ps1

# Install Windows scheduled task
Install-DropboxHelperTask

# Start the service
Start-DropboxHelperTask
```

That's it! The tool runs automatically in background.

---

## 🔧 Usage Modes

Choose the mode that fits your needs:

### Mode 1: One-Time Testing

**When to use:** Test configuration or process files once

```powershell
. .\dropbox-helper.ps1
Start-DropboxHelper -ShowProgress
# Press Ctrl+C when done
```

**Pros:** See real-time progress, test before installing  
**Cons:** Must keep PowerShell open, stops when closed

---

### Mode 2: Batch Processing

**When to use:** Process all existing files once without monitoring

```powershell
. .\dropbox-helper.ps1
$config = Get-Configuration

# Process all files in Camera Uploads
Get-ChildItem $config.DropboxCameraUploadsPath -Recurse -File |
    Where-Object { Test-IsSupportedFileType -FilePath $_.FullName } |
    ForEach-Object {
        Write-Host "Processing: $($_.Name)" -ForegroundColor Cyan
        Move-FileToBackup -SourcePath $_.FullName -Confirm:$false
    }
```

**Pros:** Quick one-time operation, no monitoring overhead  
**Cons:** Must run manually, doesn't watch for new files

---

### Mode 3: Windows Service (Recommended)

**When to use:** Automatic continuous monitoring

#### Install Service

```powershell
# MUST run as Administrator
cd C:\Tools\DropboxHelper
. .\dropbox-helper.ps1

Install-DropboxHelperTask  # Install
Start-DropboxHelperTask    # Start
```

#### Manage Service

```powershell
# Check status
Get-ScheduledTask -TaskName "DropboxCameraHelper" | Get-ScheduledTaskInfo

# Stop service
Stop-DropboxHelperTask

# Start service
Start-DropboxHelperTask

# Uninstall service
Uninstall-DropboxHelperTask

# View statistics
. .\dropbox-helper.ps1
Show-Statistics
```

#### How It Works

- Starts automatically at user logon
- Runs hidden in background
- Monitors continuously for new files
- Logs to `%APPDATA%\DropboxHelper\logs`
- Survives reboots

**Pros:** Fully automatic, runs 24/7, professional service  
**Cons:** Requires admin to install, harder to debug

---

## 💻 Requirements

### System Requirements

- **OS**: Windows 10/11 or Windows Server 2016+
- **PowerShell**: 5.1 or higher (pre-installed on Windows 10+)
- **Dropbox**: Desktop app installed and syncing
- **Storage**: Write access to backup destination
- **Admin Rights**: Only for installing as scheduled task

### For SSH/SCP Remote Backup (Optional)

- **OpenSSH Client**: Pre-installed on Windows 10 1809+
- **SSH Access**: To remote NAS/server
- **SSH Key**: Passwordless authentication recommended
- **xxd utility**: For binary file transfer (usually available via SSH)

### Verify Requirements

```powershell
# Check PowerShell version
$PSVersionTable.PSVersion  # Should be 5.1+

# Check OpenSSH (for SSH/SCP)
ssh -V

# Check Dropbox path
Test-Path "$env:USERPROFILE\Dropbox\Camera Uploads"

# Run validation test
. .\dropbox-helper.ps1
Test-DropboxHelperSetup
```

---

## 🛠️ Installation & Setup

### Step 1: Initial Setup

```powershell
# Navigate to script location
cd C:\Tools\DropboxHelper

# Load script
. .\dropbox-helper.ps1

# Create default configuration
Initialize-Configuration

# Configuration file created at:
# %APPDATA%\DropboxHelper\config.json
```

### Step 2: Configure Settings

**Option A: Edit Config File Directly**

Open `%APPDATA%\DropboxHelper\config.json` in Notepad and edit:

```json
{
  "DropboxCameraUploadsPath": "C:\\Users\\YourName\\Dropbox\\Camera Uploads",
  "BackupDestinationPath": "D:\\MyBackup\\Photos",
  "FileStabilityWaitSeconds": 30,
  "TransportMethod": "Local"
}
```

**Option B: Use PowerShell Commands**

```powershell
# Set backup destination
Set-Configuration -Settings @{
    BackupDestinationPath = "D:\MyBackup\Photos"
} -Confirm:$false

# Adjust stability wait time
Set-Configuration -Settings @{
    FileStabilityWaitSeconds = 60
} -Confirm:$false

# View current config
Get-Configuration | Format-List
```

### Step 3: Run Validation

```powershell
# Run comprehensive pre-flight checks
Test-DropboxHelperSetup

# Expected output:
# [PASS] PowerShell Version
# [PASS] Configuration File
# [PASS] Dropbox Camera Uploads Path
# [PASS] Backup Destination Path
# [SUCCESS] All validation checks passed!
```

### Step 4: Test Run

```powershell
# Test with real-time feedback
Start-DropboxHelper -ShowProgress

# Watch for:
# - "Scanning for existing files..."
# - "Found X existing files to process"
# - "Processing: filename.jpg"
# - "Moved successfully: filename.jpg"

# Press Ctrl+C to stop
```

### Step 5: Install as Service (Optional)

```powershell
# Open NEW PowerShell as Administrator
cd C:\Tools\DropboxHelper
. .\dropbox-helper.ps1

# Install service
Install-DropboxHelperTask

# Start service
Start-DropboxHelperTask

# Verify it's running
Get-ScheduledTask -TaskName "DropboxCameraHelper"
```

---

## ⚙️ Configuration

Configuration file: `%APPDATA%\DropboxHelper\config.json`

### Basic Settings

| Setting | Description | Default |
|---------|-------------|---------|
| `DropboxCameraUploadsPath` | Source folder (auto-detected) | Dropbox Camera Uploads |
| `BackupDestinationPath` | Where to move files | `Documents\CameraBackup` |
| `FileStabilityWaitSeconds` | Wait after file stable | 30 |
| `CheckIntervalSeconds` | Monitoring frequency | 5 |
| `SupportedExtensions` | File types to process | `.jpg`, `.jpeg`, `.png`, `.heic`, `.mp4`, `.mov`, etc. |
| `EnableLogging` | Enable logs | `true` |
| `LogPath` | Log location | `%APPDATA%\DropboxHelper\logs` |
| `MoveOrCopy` | Operation mode | `Move` |
| `PreserveDirectoryStructure` | Keep folder structure | `true` |
| `ConflictResolutionStrategy` | Handle duplicates | `Timestamp` |
| `MaxLogAgeDays` | Log retention | 30 |
| `RetryAttempts` | Retry on failure | 3 |
| `RetryDelaySeconds` | Delay between retries | 5 |

### SSH/SCP Settings (Remote Backup)

| Setting | Description | Default |
|---------|-------------|---------|
| `TransportMethod` | Transfer method: `Local` or `SSH` | `Local` |
| `SSHHost` | Remote server IP/hostname | (empty) |
| `SSHUser` | SSH username | (empty) |
| `SSHPort` | SSH port | 22 |
| `SSHKeyPath` | SSH private key path | (empty) |
| `SSHRemotePath` | Remote destination path | (empty) |

### Example Configurations

**Local Backup:**
```json
{
  "TransportMethod": "Local",
  "BackupDestinationPath": "D:\\Backup\\iPhone-Photos"
}
```

**Network Share (NAS):**
```json
{
  "TransportMethod": "Local",
  "BackupDestinationPath": "\\\\MyNAS\\Photos\\iPhone-Backup"
}
```

**SSH/SCP Remote Backup:**
```json
{
  "TransportMethod": "SSH",
  "SSHHost": "192.168.1.100",
  "SSHUser": "myuser",
  "SSHPort": 22,
  "SSHKeyPath": "%USERPROFILE%\\.ssh\\id_rsa",
  "SSHRemotePath": "/volume1/photos/iphone-backup"
}
```

---

## 📂 Backup Locations

### Local Drive

```powershell
Set-Configuration -Settings @{
    TransportMethod = 'Local'
    BackupDestinationPath = 'D:\MyBackup\Photos'
} -Confirm:$false
```

### External Drive

```powershell
Set-Configuration -Settings @{
    TransportMethod = 'Local'
    BackupDestinationPath = 'E:\iPhone-Backup'
} -Confirm:$false
```

### Network Share (Windows SMB/NAS)

```powershell
Set-Configuration -Settings @{
    TransportMethod = 'Local'
    BackupDestinationPath = '\\MyNAS\Photos\iPhone-Backup'
} -Confirm:$false
```

**Note:** Ensure network share is accessible and you have write permissions.

---

## 🔐 SSH/SCP Remote Backup

For secure remote backup over SSH to Linux NAS or servers.

### Prerequisites

1. **OpenSSH Client** (pre-installed on Windows 10 1809+)
   ```powershell
   ssh -V  # Verify installation
   ```

2. **SSH Key Authentication**
   ```powershell
   # Generate SSH key
   ssh-keygen -t rsa -b 4096 -f $env:USERPROFILE\.ssh\id_rsa
   
   # Copy to remote server
   type $env:USERPROFILE\.ssh\id_rsa.pub | ssh user@192.168.1.100 "cat >> ~/.ssh/authorized_keys"
   
   # Test connection
   ssh user@192.168.1.100 "echo 'SSH works!'"
   ```

3. **Remote Server Requirements**
   - SSH server running
   - `xxd` utility installed (usually pre-installed)
   - Write permissions to destination folder

### Configuration

```powershell
. .\dropbox-helper.ps1

Set-Configuration -Settings @{
    TransportMethod = 'SSH'
    SSHHost = '192.168.1.100'
    SSHUser = 'myuser'
    SSHPort = 22
    SSHKeyPath = '%USERPROFILE%\.ssh\id_rsa'
    SSHRemotePath = '/volume1/photos/iphone-backup'
} -Confirm:$false
```

### How SSH Transfer Works

The tool automatically handles paths with spaces using a smart fallback:

1. **Pre-flight Checks**
   - Creates remote directory: `ssh mkdir -p '/remote/path'`
   - Validates directory: `ssh ls -d '/remote/path'`

2. **Transfer Method**
   - **Paths without spaces**: Uses standard SCP (fast)
   - **Paths with spaces**: Uses hex-encoded SSH transfer (binary-safe)

3. **Post-transfer Validation**
   - Verifies remote file size: `ssh ls -al '/remote/file'`
   - Ensures data integrity

### Testing SSH Setup

```powershell
. .\dropbox-helper.ps1

# Run comprehensive validation
Test-DropboxHelperSetup -Verbose

# Expected output:
# [PASS] SSH Connection
# [PASS] SCP Available
# [PASS] Remote Path Accessible
```

**For detailed SSH setup instructions, see [SSH_SETUP.md](SSH_SETUP.md)**

### Troubleshooting SSH

**Issue: SSH Connection Failed**
```powershell
# Test SSH manually
ssh -p 22 -i "$env:USERPROFILE\.ssh\id_rsa" user@192.168.1.100 "echo test"
```

**Issue: Permission Denied**
```powershell
# Check SSH key permissions
icacls "$env:USERPROFILE\.ssh\id_rsa"
# Should be: Owner only (inherited permissions removed)
```

**Issue: Remote Path Not Writable**
```powershell
# Test write permission
ssh user@192.168.1.100 "touch '/remote/path/test.txt' && rm '/remote/path/test.txt'"
```

---

## 🎛️ Service Management

### Install Service

```powershell
# MUST run PowerShell as Administrator
cd C:\Tools\DropboxHelper
. .\dropbox-helper.ps1

Install-DropboxHelperTask

# Output:
# "Scheduled task 'DropboxCameraHelper' created successfully"
```

### Start/Stop Service

```powershell
# Start
Start-DropboxHelperTask

# Stop
Stop-DropboxHelperTask

# Restart
Stop-DropboxHelperTask
Start-Sleep -Seconds 3
Start-DropboxHelperTask
```

### Check Service Status

**Method 1: PowerShell**
```powershell
Get-ScheduledTask -TaskName "DropboxCameraHelper" | Get-ScheduledTaskInfo
```

**Method 2: Task Scheduler GUI**
1. Press `Win + R`, type `taskschd.msc`, Enter
2. Navigate to "Task Scheduler Library"
3. Find "DropboxCameraHelper"
4. View "Last Run Result" and "History"

### Uninstall Service

```powershell
. .\dropbox-helper.ps1
Uninstall-DropboxHelperTask -Confirm:$false

# Cleanup configuration (optional)
Remove-Item "$env:APPDATA\DropboxHelper" -Recurse -Force
```

---

## 📊 Monitoring & Logs

### View Statistics

```powershell
. .\dropbox-helper.ps1
Show-Statistics

# Output:
# Dropbox Helper Statistics:
#   Files Processed: 145
#   Files Moved: 145
#   Errors: 0
#   Total Data Moved: 2.34 GB
#   Queue Size: 0
#   Status: Running
```

### View Logs

**Recent logs:**
```powershell
. .\dropbox-helper.ps1
Get-LogHistory -Days 7 | Format-Table -AutoSize
```

**Errors only:**
```powershell
Get-LogHistory -Days 7 -Level ERROR | Format-Table
```

**Live tail (manual):**
```powershell
$logFile = "$env:APPDATA\DropboxHelper\logs\dropbox-helper_$(Get-Date -Format 'yyyyMMdd').log"
Get-Content $logFile -Wait -Tail 20
```

### Log Location

```
%APPDATA%\DropboxHelper\logs\dropbox-helper_YYYYMMDD.log
```

Example: `C:\Users\YourName\AppData\Roaming\DropboxHelper\logs\dropbox-helper_20251111.log`

### Log Levels

- **INFO**: Normal operations (file moved, queue processed)
- **WARNING**: Non-critical issues (file skipped, retry)
- **ERROR**: Critical errors (move failed, connection error)

---

## 🔧 Troubleshooting

### Pre-Flight Validation

Always run validation before troubleshooting:

```powershell
. .\dropbox-helper.ps1
Test-DropboxHelperSetup -Verbose
```

### Common Issues

#### Script Won't Start

**Check execution policy:**
```powershell
Get-ExecutionPolicy
# If "Restricted", change it:
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**Verify Dropbox path:**
```powershell
Test-Path "$env:USERPROFILE\Dropbox\Camera Uploads"
```

#### Files Not Being Moved

**Check supported file types:**
```powershell
. .\dropbox-helper.ps1
Get-SupportedExtensions
```

**Check file lock:**
```powershell
Test-FileIsLocked -FilePath "C:\Path\To\File.jpg"
```

**Review logs:**
```powershell
Get-LogHistory -Days 1 -Level ERROR
```

#### Network Path Issues

**Test connectivity:**
```powershell
Test-Path "\\MyNAS\Photos"
```

**Map drive (workaround):**
```powershell
New-PSDrive -Name Z -PSProvider FileSystem -Root "\\MyNAS\Photos" -Persist
# Then use Z:\iPhone-Backup as destination
```

#### SSH Connection Issues

**Test SSH manually:**
```powershell
ssh -p 22 -i "$env:USERPROFILE\.ssh\id_rsa" user@host "echo test"
```

**Check SSH key permissions:**
```powershell
# Key should be readable only by owner
icacls "$env:USERPROFILE\.ssh\id_rsa"
```

#### Service Not Running

**Check task status:**
```powershell
Get-ScheduledTask -TaskName "DropboxCameraHelper" | Get-ScheduledTaskInfo
```

**Run manually:**
```powershell
Start-ScheduledTask -TaskName "DropboxCameraHelper"
```

**Check Event Viewer:**
1. Open Event Viewer (`eventvwr.msc`)
2. Navigate to: Applications and Services Logs → Microsoft → Windows → TaskScheduler
3. Look for "DropboxCameraHelper" errors

---

## 📋 Monitoring Running Service

After installing as a Windows scheduled task, use these commands to monitor the service:

### View Logs

**Log Location:**
```
%APPDATA%\DropboxHelper\logs\dropbox-helper_YYYYMMDD.log
```

**View last 30 lines:**
```powershell
Get-Content "$env:APPDATA\DropboxHelper\logs\dropbox-helper_$(Get-Date -Format 'yyyyMMdd').log" -Tail 30
```

**Live monitoring (watch in real-time):**
```powershell
Get-Content "$env:APPDATA\DropboxHelper\logs\dropbox-helper_$(Get-Date -Format 'yyyyMMdd').log" -Wait -Tail 20
```

**Show errors only:**
```powershell
Get-Content "$env:APPDATA\DropboxHelper\logs\dropbox-helper_*.log" | Select-String "ERROR"
```

**Open log folder in Explorer:**
```powershell
explorer "$env:APPDATA\DropboxHelper\logs"
```

### Check Service Status

**View scheduled task status:**
```powershell
Get-ScheduledTask -TaskName "DropboxCameraHelper" | Format-List TaskName, State

Get-ScheduledTaskInfo -TaskName "DropboxCameraHelper" | Format-List LastRunTime, LastTaskResult
```

**Using built-in function:**
```powershell
. .\dropbox-helper.ps1
Get-DropboxHelperTaskStatus
```

### What to Look For

**Healthy Log Entries:**
- `[INFO] Dropbox Helper started successfully`
- `[INFO] FileSystemWatcher started`
- `[INFO] File detected: [filename]`
- `[INFO] File is ready for processing`
- `[INFO] Successfully processed: [filename]`

**For SSH/SCP transfers:**
- `[INFO] SSH connection successful to [host]`
- `[INFO] Transferring via SCP: [file] -> [destination]`
- `[INFO] Transfer validated successfully`
- `[INFO] Removed source file: [file]`

**Warning Signs:**
- `[WARNING]` entries indicate non-critical issues (retries, temporary locks)
- `[ERROR]` entries indicate failures that need attention

### Task State Values

- **Running**: Service is actively monitoring
- **Ready**: Service installed but not currently running
- **Disabled**: Service has been disabled

### Last Task Result Codes

- **0**: Success
- **267009**: Task is currently running (normal for background tasks)
- **Other codes**: Check Event Viewer for details

---

## ❓ FAQ

### Q: Will this delete files from Dropbox?

**A:** By default, YES - files are **moved** (not copied) from Camera Uploads to backup. Dropbox syncs this change. To keep copies in both places:

```powershell
Set-Configuration -Settings @{ MoveOrCopy = "Copy" } -Confirm:$false
```

Note: Copy mode defeats the purpose of freeing Dropbox space.

### Q: Can I run this on multiple computers?

**A:** Yes, but:
- Each computer needs its own backup destination
- OR use shared network location with timestamp conflict resolution
- Don't point multiple computers to same local path

### Q: What if backup drive is full?

**A:** The tool will:
1. Fail to move file
2. Log error
3. Retry per `RetryAttempts` config
4. Keep file in Camera Uploads until space available

### Q: Does this work with Dropbox Business?

**A:** Yes! Just set the correct path:
```json
"DropboxCameraUploadsPath": "C:\\Users\\YourName\\Dropbox (Business)\\Camera Uploads"
```

### Q: Can I backup to cloud storage (OneDrive/Google Drive)?

**A:** Yes, if the cloud storage has a local sync folder:
```json
"BackupDestinationPath": "C:\\Users\\YourName\\OneDrive\\iPhone-Backup"
```

### Q: How much Dropbox space does this save?

**A:** 100% of Camera Uploads space. Files are moved immediately after syncing, keeping Camera Uploads nearly empty.

### Q: Will this affect my iPhone camera roll?

**A:** No. Your iPhone's photos are unaffected. This only manages files on Windows after Dropbox syncs them.

### Q: How do I pause temporarily?

**A:** 
```powershell
# If running as service:
Stop-DropboxHelperTask

# If running interactively:
# Press Ctrl+C

# Resume:
Start-DropboxHelperTask
```

### Q: What about spaces in file/folder names?

**A:** Fully supported! The tool automatically handles:
- Spaces in filenames
- Spaces in folder paths  
- Special characters
- Unicode characters

For SSH/SCP, it uses hex-encoded transfer for paths with spaces.

---

## 🚀 Advanced Usage

### Batch Process Existing Files

```powershell
. .\dropbox-helper.ps1
$config = Get-Configuration

Get-ChildItem $config.DropboxCameraUploadsPath -Recurse -File |
    Where-Object { Test-IsSupportedFileType -FilePath $_.FullName } |
    ForEach-Object {
        Write-Host "Moving: $($_.Name)" -ForegroundColor Cyan
        Move-FileToBackup -SourcePath $_.FullName -Confirm:$false
    }
```

### Custom Stability Detection

For large files or slow networks:

```powershell
Set-Configuration -Settings @{
    FileStabilityWaitSeconds = 120
    CheckIntervalSeconds = 10
} -Confirm:$false
```

### Process Specific File Types Only

Photos only (no videos):
```powershell
Set-Configuration -Settings @{
    SupportedExtensions = @('.jpg', '.jpeg', '.png', '.heic', '.heif')
} -Confirm:$false
```

Videos only:
```powershell
Set-Configuration -Settings @{
    SupportedExtensions = @('.mp4', '.mov', '.avi', '.m4v')
} -Confirm:$false
```

### Custom Conflict Resolution

```powershell
# Use sequential numbers for duplicates
Set-Configuration -Settings @{
    ConflictResolutionStrategy = 'Counter'
} -Confirm:$false

# Skip duplicates (keep original)
Set-Configuration -Settings @{
    ConflictResolutionStrategy = 'Skip'
} -Confirm:$false
```

### Monitor Multiple Folders

Run separate instances with different configs:

```powershell
# Instance 1: Camera Uploads
$env:DropboxHelper_ConfigPath = "$env:APPDATA\DropboxHelper\config1.json"
. .\dropbox-helper.ps1
Initialize-Configuration
Set-Configuration -Settings @{ BackupDestinationPath = 'D:\Backup1' }
Start-DropboxHelper

# Instance 2: Screenshots folder (separate PowerShell window)
$env:DropboxHelper_ConfigPath = "$env:APPDATA\DropboxHelper\config2.json"
. .\dropbox-helper.ps1
Initialize-Configuration
Set-Configuration -Settings @{
    DropboxCameraUploadsPath = "$env:USERPROFILE\Dropbox\Screenshots"
    BackupDestinationPath = 'D:\Backup2'
}
Start-DropboxHelper
```

---

## 📝 Performance

### Resource Usage

- **CPU**: < 1% idle, 2-5% when processing
- **Memory**: 50-100 MB
- **Disk I/O**: Proportional to file sizes
- **Network**: Only for network/SSH destinations

### Throughput

- **Small photos (2-5 MB)**: 5-10 seconds per file
- **Videos (50-200 MB)**: 30-60 seconds per file
- **Network backup**: Depends on network speed
- **SSH/SCP**: Slightly slower due to encryption overhead

---

## 🔒 Security

### Data Privacy

- All operations are local (no external services)
- No data uploaded or transmitted (except to your configured backup)
- Configuration and logs stored locally

### File Integrity

- File size validation after transfer
- Stability checks prevent partial transfers
- Hash verification for files < 100 MB (local transport)

### Permissions

- Runs with your user account privileges
- No elevation required (except scheduled task install)
- Network/SSH access only to configured destinations

---

## 🗑️ Uninstallation

```powershell
# 1. Remove scheduled task
. .\dropbox-helper.ps1
Uninstall-DropboxHelperTask

# 2. Delete configuration and logs
Remove-Item "$env:APPDATA\DropboxHelper" -Recurse -Force

# 3. Delete script
Remove-Item "C:\Tools\DropboxHelper" -Recurse -Force
```

---

## 📄 License

This project is provided as-is for free use and modification.

---

## 📞 Support

**Before asking for help:**
1. Run: `Test-DropboxHelperSetup -Verbose`
2. Check logs: `Get-LogHistory -Days 7 -Level ERROR`
3. Review [Troubleshooting](#troubleshooting) section
4. Check [FAQ](#faq)
5. For SSH setup: See [SSH_SETUP.md](SSH_SETUP.md)

**Documentation:**
- [README.md](README.md) - Full documentation
- [QUICKSTART.md](QUICKSTART.md) - Quick start guide
- [SSH_SETUP.md](SSH_SETUP.md) - SSH/SCP remote backup setup

**Include in support requests:**
- PowerShell version: `$PSVersionTable.PSVersion`
- Windows version: `(Get-ComputerInfo).WindowsVersion`
- Error messages from logs
- Configuration (remove personal paths)

---

## 🎉 Credits

Developed with ❤️ and PowerShell

**Happy Backing Up! 📸 🎥 💾**

---

**Version:** 1.0.1  
**Last Updated:** November 12, 2025  
**Transport:** Local file system, Network shares (SMB), SSH/SCP
