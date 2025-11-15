<#
.SYNOPSIS
    Installation script for Dropbox Camera Upload Helper
.DESCRIPTION
    Interactive installation wizard for setting up the Dropbox Helper tool
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

Write-Host @"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║     Dropbox Camera Upload Helper - Installation Wizard       ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Write-Host ""

# Import main script
$scriptPath = Join-Path $PSScriptRoot "dropbox-helper.ps1"
if (-not (Test-Path $scriptPath)) {
    Write-Host "ERROR: Cannot find dropbox-helper.ps1 in the same directory" -ForegroundColor Red
    exit 1
}

. $scriptPath

Write-Host "Step 1: Initializing Configuration..." -ForegroundColor Yellow
if (-not (Initialize-Configuration)) {
    Write-Host "ERROR: Failed to initialize configuration" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Configuration initialized`n" -ForegroundColor Green

$config = Get-Configuration

Write-Host "Step 2: Configuration Review" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor Gray

Write-Host "Current Settings:" -ForegroundColor White
Write-Host "  Dropbox Source: " -NoNewline -ForegroundColor Gray
Write-Host $config.DropboxCameraUploadsPath -ForegroundColor White
Write-Host "  Backup Destination: " -NoNewline -ForegroundColor Gray
Write-Host $config.BackupDestinationPath -ForegroundColor White
Write-Host ""

# Ask if user wants to change backup destination
$changeBackup = Read-Host "Do you want to change the backup destination? (Y/N)"
if ($changeBackup -eq 'Y' -or $changeBackup -eq 'y') {
    Write-Host "`nEnter new backup destination path:" -ForegroundColor Yellow
    Write-Host "  Examples:" -ForegroundColor Gray
    Write-Host "    D:\MyBackup\CameraUploads" -ForegroundColor Gray
    Write-Host "    \\MyNAS\Photos\iPhone-Backup" -ForegroundColor Gray
    Write-Host ""
    
    $newBackupPath = Read-Host "  Path"
    
    if ($newBackupPath) {
        Set-Configuration -Settings @{
            BackupDestinationPath = $newBackupPath
        } -Confirm:$false | Out-Null
        
        Write-Host "✓ Backup destination updated`n" -ForegroundColor Green
        $config = Get-Configuration
    }
}

Write-Host "Step 3: Path Validation" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor Gray

$dropboxPath = [System.Environment]::ExpandEnvironmentVariables($config.DropboxCameraUploadsPath)
$backupPath = [System.Environment]::ExpandEnvironmentVariables($config.BackupDestinationPath)

Write-Host "Checking Dropbox path..." -ForegroundColor White
if (Test-Path $dropboxPath) {
    Write-Host "✓ Dropbox Camera Uploads found: $dropboxPath" -ForegroundColor Green
} else {
    Write-Host "⚠ Dropbox Camera Uploads not found: $dropboxPath" -ForegroundColor Yellow
    Write-Host "  The tool will monitor this path when it becomes available." -ForegroundColor Gray
}

Write-Host "`nChecking backup path..." -ForegroundColor White
if (Test-BackupPathAvailable -Path $backupPath) {
    Write-Host "✓ Backup destination is accessible: $backupPath" -ForegroundColor Green
} else {
    Write-Host "⚠ Warning: Cannot access backup destination: $backupPath" -ForegroundColor Yellow
    $continue = Read-Host "Do you want to continue anyway? (Y/N)"
    if ($continue -ne 'Y' -and $continue -ne 'y') {
        Write-Host "`nInstallation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "`nStep 4: Installation Options" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor Gray

Write-Host "How would you like to run the Dropbox Helper?" -ForegroundColor White
Write-Host ""
Write-Host "  1) Install as Scheduled Task (Recommended - runs automatically at logon)" -ForegroundColor White
Write-Host "  2) Manual start only (run script manually when needed)" -ForegroundColor White
Write-Host "  3) Test run now (see it in action)" -ForegroundColor White
Write-Host ""

$choice = Read-Host "Enter choice (1-3)"

switch ($choice) {
    "1" {
        Write-Host "`nInstalling as Scheduled Task..." -ForegroundColor Yellow
        
        # Check if running as admin
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        
        if (-not $isAdmin) {
            Write-Host "⚠ Administrator privileges required to create scheduled task" -ForegroundColor Yellow
            Write-Host "Please run this installer as Administrator, or choose option 2 or 3.`n" -ForegroundColor Gray
            
            $restart = Read-Host "Restart installer as Administrator? (Y/N)"
            if ($restart -eq 'Y' -or $restart -eq 'y') {
                Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
                exit 0
            }
        } else {
            if (Install-DropboxHelperTask) {
                Write-Host "`n✓ Scheduled task installed successfully!`n" -ForegroundColor Green
                
                $startNow = Read-Host "Start the task now? (Y/N)"
                if ($startNow -eq 'Y' -or $startNow -eq 'y') {
                    Start-DropboxHelperTask
                    Write-Host "✓ Task started`n" -ForegroundColor Green
                }
                
                Write-Host "Task Management Commands:" -ForegroundColor Cyan
                Write-Host "  Start:  Start-DropboxHelperTask" -ForegroundColor Gray
                Write-Host "  Stop:   Stop-DropboxHelperTask" -ForegroundColor Gray
                Write-Host "  Status: Get-ScheduledTask -TaskName 'DropboxCameraHelper'`n" -ForegroundColor Gray
            }
        }
    }
    
    "2" {
        Write-Host "`n✓ Configuration saved successfully!`n" -ForegroundColor Green
        Write-Host "To start the Dropbox Helper manually, run:" -ForegroundColor Cyan
        Write-Host "  . .\dropbox-helper.ps1" -ForegroundColor Gray
        Write-Host "  Start-DropboxHelper`n" -ForegroundColor Gray
    }
    
    "3" {
        Write-Host "`nStarting test run..." -ForegroundColor Yellow
        Write-Host "Press Ctrl+C to stop`n" -ForegroundColor Gray
        Start-Sleep -Seconds 2
        
        Start-DropboxHelper -ShowProgress -Verbose
    }
    
    default {
        Write-Host "`n✓ Configuration saved successfully!`n" -ForegroundColor Green
        Write-Host "To start the Dropbox Helper, run:" -ForegroundColor Cyan
        Write-Host "  . .\dropbox-helper.ps1" -ForegroundColor Gray
        Write-Host "  Start-DropboxHelper`n" -ForegroundColor Gray
    }
}

Write-Host "`n╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                                                               ║" -ForegroundColor Cyan
Write-Host "║                   Installation Complete!                      ║" -ForegroundColor Cyan
Write-Host "║                                                               ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

Write-Host "Configuration file: " -NoNewline -ForegroundColor Gray
Write-Host "$env:APPDATA\DropboxHelper\config.json`n" -ForegroundColor White

Write-Host "Useful Commands:" -ForegroundColor Cyan
Write-Host "  Show Statistics:  " -NoNewline -ForegroundColor Gray
Write-Host "Show-Statistics" -ForegroundColor White
Write-Host "  View Logs:        " -NoNewline -ForegroundColor Gray
Write-Host "Get-LogHistory -Days 7" -ForegroundColor White
Write-Host "  Check Status:     " -NoNewline -ForegroundColor Gray
Write-Host "Get-DropboxHelperStatus" -ForegroundColor White
Write-Host ""

Write-Host "Documentation:" -ForegroundColor Cyan
Write-Host "  README.md     - Full documentation" -ForegroundColor Gray
Write-Host "  QUICKSTART.md - Quick start guide" -ForegroundColor Gray
Write-Host ""

Write-Host "For help, run: " -NoNewline -ForegroundColor Gray
Write-Host "Get-Help Start-DropboxHelper -Full`n" -ForegroundColor White

Write-Host "Happy backing up! 📸 🎥 💾`n" -ForegroundColor Green
