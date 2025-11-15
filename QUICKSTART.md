# Dropbox Camera Upload Helper - Quick Start Guide

## 🚀 5-Minute Setup

### Step 1: Download
Save `dropbox-helper.ps1` to a folder:
```
C:\Tools\DropboxHelper\
```

### Step 2: Test Run
Open PowerShell and run:

```powershell
cd C:\Tools\DropboxHelper
.\dropbox-helper.ps1

# Import functions
. .\dropbox-helper.ps1

# Create configuration
Initialize-Configuration

# Start the tool (press Ctrl+C to stop)
Start-DropboxHelper -ShowProgress -Verbose
```

### Step 3: Configure
Edit the backup destination:

```powershell
# For local drive
Set-Configuration -Settings @{
    BackupDestinationPath = "D:\MyBackup\CameraUploads"
} -Confirm:$false

# For network share (NAS)
Set-Configuration -Settings @{
    BackupDestinationPath = "\\MyNAS\Photos\iPhone-Backup"
} -Confirm:$false
```

### Step 4: Install as Background Service

**Option A: Scheduled Task (Recommended)**

Run PowerShell **as Administrator**:

```powershell
cd C:\Tools\DropboxHelper
. .\dropbox-helper.ps1

# Install task
Install-DropboxHelperTask

# Start task
Start-DropboxHelperTask
```

**Option B: Manual Start**

Create a shortcut with this target:
```
powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Tools\DropboxHelper\dropbox-helper.ps1" -Command "Start-DropboxHelper"
```

Place shortcut in:
```
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
```

---

## ✅ Verify It's Working

### Check Status
```powershell
. .\dropbox-helper.ps1
Get-DropboxHelperStatus
```

### View Statistics
```powershell
Show-Statistics
```

### Check Logs
```powershell
Get-LogHistory -Days 1 | Format-Table
```

### Test with a File
1. Place a test photo in Dropbox Camera Uploads
2. Wait 30-60 seconds
3. Check if it moved to your backup location
4. Verify it's gone from Camera Uploads

---

## 📊 Monitor Activity

### Real-time Monitoring
```powershell
Start-DropboxHelper -ShowProgress
```

### View Recent Activity
```powershell
Get-LogHistory -Days 1 -Level INFO | Select-Object -First 20 | Format-Table
```

### Check for Errors
```powershell
Get-LogHistory -Days 7 -Level ERROR | Format-Table
```

---

## 🛑 Stop/Pause

### Stop Scheduled Task
```powershell
Stop-DropboxHelperTask
```

### Stop Manual Run
Press `Ctrl+C` in PowerShell window

### Resume
```powershell
Start-DropboxHelperTask
```

---

## 🔧 Common Configurations

### Maximum Safety (Slow but Reliable)
```powershell
Set-Configuration -Settings @{
    FileStabilityWaitSeconds = 60
    CheckIntervalSeconds = 10
    RetryAttempts = 5
} -Confirm:$false
```

### Fast Processing (Less Cautious)
```powershell
Set-Configuration -Settings @{
    FileStabilityWaitSeconds = 15
    CheckIntervalSeconds = 3
} -Confirm:$false
```

### Photos Only (No Videos)
```powershell
Set-Configuration -Settings @{
    SupportedExtensions = @('.jpg', '.jpeg', '.png', '.heic', '.heif')
} -Confirm:$false
```

### Copy Instead of Move (Keep Files in Dropbox)
```powershell
Set-Configuration -Settings @{
    MoveOrCopy = 'Copy'
} -Confirm:$false
```

---

## 🆘 Quick Troubleshooting

### Script Won't Run
```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Can't Find Dropbox Path
```powershell
# Check if path exists
Test-Path "$env:USERPROFILE\Dropbox\Camera Uploads"

# Set manually if needed
Set-Configuration -Settings @{
    DropboxCameraUploadsPath = "C:\Users\YourName\Dropbox\Camera Uploads"
} -Confirm:$false
```

### Network Path Issues
```powershell
# Test network path
Test-Path "\\MyNAS\Photos"

# Map drive as alternative
New-PSDrive -Name Z -PSProvider FileSystem -Root "\\MyNAS\Photos" -Persist
Set-Configuration -Settings @{
    BackupDestinationPath = "Z:\iPhone-Backup"
} -Confirm:$false
```

### View Error Details
```powershell
Get-LogHistory -Days 1 -Level ERROR | 
    Select-Object Timestamp, Message | 
    Format-List
```

---

## 📝 Useful Commands

| Task | Command |
|------|---------|
| Show configuration | `Get-Configuration` |
| Update setting | `Set-Configuration -Settings @{...}` |
| View statistics | `Show-Statistics` |
| Check status | `Get-DropboxHelperStatus` |
| View logs | `Get-LogHistory -Days 7` |
| Start service | `Start-DropboxHelperTask` |
| Stop service | `Stop-DropboxHelperTask` |
| Reinstall task | `Install-DropboxHelperTask` |
| Uninstall task | `Uninstall-DropboxHelperTask` |

---

## 🎯 Best Practices

1. **Test First**: Run manually for a day before installing as scheduled task
2. **Check Logs Daily**: Look for errors in the first week
3. **Verify Backups**: Occasionally check that files are in backup location
4. **Monitor Dropbox Space**: Confirm space is actually being freed
5. **Keep Backup Drive Healthy**: Ensure backup location has plenty of space

---

## 💡 Tips

- **For NAS Users**: Ensure NAS is always on and accessible
- **For External Drives**: Leave drive connected and powered on
- **For Large Videos**: Consider increasing `FileStabilityWaitSeconds` to 60+
- **For Performance**: Increase `CheckIntervalSeconds` if CPU usage is high
- **For Safety**: Enable hash verification for small files (default)

---

## 📞 Need Help?

1. Check **README.md** for detailed documentation
2. Review **IMPLEMENTATION_PLAN.md** for technical details
3. Check logs: `Get-LogHistory -Days 7 -Level ERROR`
4. Test configuration: `Test-ConfigurationPath -Config (Get-Configuration)`

---

**That's it! Your iPhone photos will now automatically backup to your chosen location.** 📸 ✨
