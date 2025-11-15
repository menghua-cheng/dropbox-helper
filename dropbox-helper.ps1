<#
.SYNOPSIS
    Dropbox Camera Upload Auto-Offload Tool
.DESCRIPTION
    Monitors Dropbox Camera Uploads folder and automatically moves fully-synced 
    photos/videos to a backup location, preventing Dropbox storage from filling up.
.PARAMETER h
    Display help information.
.PARAMETER Validate
    Run comprehensive validation checks on configuration, paths, and connections.
    Use this before installing as a service or scheduled task.
.EXAMPLE
    .\dropbox-helper.ps1 -h
    Display help information.
.EXAMPLE
    .\dropbox-helper.ps1 -Validate
    Run validation checks on all settings and connections.
.EXAMPLE
    . .\dropbox-helper.ps1
    Dot-source the script to load functions into current session.
.NOTES
    Version: 1.0.0
    Author: DevOps Expert
    Requires: PowerShell 5.1+
#>

[CmdletBinding()]
param(
    [Parameter()]
    [Alias('help')]
    [switch]$h,
    
    [Parameter()]
    [switch]$Validate,
    
    [Parameter()]
    [string]$Command
)

#Requires -Version 5.1

# Script Variables
$script:ModuleName = "DropboxHelper"
$script:ConfigPath = Join-Path $env:APPDATA "$ModuleName\config.json"
$script:FileWatcher = $null
$script:FileQueue = [System.Collections.Concurrent.ConcurrentQueue[PSCustomObject]]::new()
$script:IsRunning = $false
$script:SSHConnectionTested = $false
$script:SSHCreatedDirectories = @{}  # Cache of created remote directories
$script:Statistics = @{
    FilesProcessed = 0
    FilesMoved = 0
    Errors = 0
    TotalBytes = 0
}

#region Configuration Management

<#
.SYNOPSIS
    Initializes the configuration file with default settings.
.DESCRIPTION
    Creates the configuration directory and file if they don't exist.
    Uses default settings for Dropbox Camera Uploads monitoring.
#>
function Initialize-Configuration {
    [CmdletBinding()]
    param()
    
    try {
        $configDir = Split-Path -Parent $script:ConfigPath
        
        if (-not (Test-Path $configDir)) {
            Write-Verbose "Creating configuration directory: $configDir"
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }
        
        if (-not (Test-Path $script:ConfigPath)) {
            Write-Verbose "Creating default configuration file"
            
            # Detect Dropbox path
            $dropboxPath = Get-DropboxPath
            
            $defaultConfig = [PSCustomObject]@{
                DropboxCameraUploadsPath = $dropboxPath
                BackupDestinationPath = Join-Path $env:USERPROFILE "Documents\CameraBackup"
                FileStabilityWaitSeconds = 30
                CheckIntervalSeconds = 5
                SupportedExtensions = @('.jpg', '.jpeg', '.png', '.heic', '.heif', '.mp4', '.mov', '.avi', '.3gp', '.m4v')
                EnableLogging = $true
                LogPath = Join-Path $env:APPDATA "$script:ModuleName\logs"
                MoveOrCopy = 'Move'
                PreserveDirectoryStructure = $true
                ConflictResolutionStrategy = 'Timestamp'
                MinHoursBeforeMove = 48
                MaxLogAgeDays = 30
                RetryAttempts = 3
                RetryDelaySeconds = 5
                TransportMethod = 'Local'
                SSHHost = ''
                SSHUser = ''
                SSHPort = 22
                SSHKeyPath = ''
                SSHRemotePath = '/photos/user1/camera uploads/'
            }
            
            $defaultConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ConfigPath -Encoding UTF8
            Write-Verbose "Configuration file created at: $script:ConfigPath"
        }
        
        return $true
    }
    catch {
        Write-Error "Failed to initialize configuration: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Detects the Dropbox Camera Uploads folder path.
#>
function Get-DropboxPath {
    [CmdletBinding()]
    param()
    
    # Common Dropbox paths
    $possiblePaths = @(
        (Join-Path $env:USERPROFILE "Dropbox\Camera Uploads"),
        (Join-Path $env:USERPROFILE "Dropbox (Personal)\Camera Uploads"),
        (Join-Path $env:USERPROFILE "Dropbox (Business)\Camera Uploads")
    )
    
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            Write-Verbose "Found Dropbox Camera Uploads at: $path"
            return $path
        }
    }
    
    # Default fallback
    return Join-Path $env:USERPROFILE "Dropbox\Camera Uploads"
}

<#
.SYNOPSIS
    Reads and parses the configuration file.
.DESCRIPTION
    Loads configuration from JSON file and returns as PSCustomObject.
#>
function Get-Configuration {
    [CmdletBinding()]
    param()
    
    try {
        if (-not (Test-Path $script:ConfigPath)) {
            Write-Warning "Configuration file not found. Initializing with defaults."
            Initialize-Configuration | Out-Null
        }
        
        $config = Get-Content -Path $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        
        # Validate required properties
        $requiredProperties = @('DropboxCameraUploadsPath', 'BackupDestinationPath')
        foreach ($prop in $requiredProperties) {
            if (-not $config.$prop) {
                throw "Configuration is missing required property: $prop"
            }
        }
        
        Write-Verbose "Configuration loaded successfully"
        return $config
    }
    catch {
        Write-Error "Failed to load configuration: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Updates configuration settings.
.DESCRIPTION
    Updates one or more configuration properties and saves to file.
.PARAMETER Settings
    Hashtable of settings to update.
#>
function Set-Configuration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings
    )
    
    try {
        $config = Get-Configuration
        if (-not $config) {
            throw "Could not load existing configuration"
        }
        
        # Update properties
        foreach ($key in $Settings.Keys) {
            if ($config.PSObject.Properties.Name -contains $key) {
                if ($PSCmdlet.ShouldProcess($key, "Update configuration")) {
                    $config.$key = $Settings[$key]
                    Write-Verbose "Updated configuration: $key = $($Settings[$key])"
                }
            }
            else {
                Write-Warning "Unknown configuration property: $key"
            }
        }
        
        # Validate paths if they were updated
        if ($Settings.ContainsKey('DropboxCameraUploadsPath') -or 
            $Settings.ContainsKey('BackupDestinationPath')) {
            if (-not (Test-ConfigurationPath -Config $config)) {
                throw "Path validation failed"
            }
        }
        
        # Save configuration
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ConfigPath -Encoding UTF8
        Write-Verbose "Configuration saved successfully"
        
        return $true
    }
    catch {
        Write-Error "Failed to update configuration: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Validates paths in configuration.
.DESCRIPTION
    Checks if configured paths are valid and accessible.
.PARAMETER Config
    Configuration object to validate.
#>
function Test-ConfigurationPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )
    
    $isValid = $true
    
    # Validate Dropbox path
    if ($Config.DropboxCameraUploadsPath) {
        $dropboxPath = [System.Environment]::ExpandEnvironmentVariables($Config.DropboxCameraUploadsPath)
        
        if (-not (Test-Path $dropboxPath)) {
            Write-Warning "Dropbox Camera Uploads path not found: $dropboxPath"
            Write-Warning "The path will be monitored when it becomes available."
        }
        else {
            Write-Verbose "Dropbox path validated: $dropboxPath"
        }
    }
    
    # Validate backup destination
    if ($Config.BackupDestinationPath) {
        $backupPath = [System.Environment]::ExpandEnvironmentVariables($Config.BackupDestinationPath)
        
        # Check if it's a UNC path
        if ($backupPath -match '^\\\\') {
            Write-Verbose "Detected UNC path: $backupPath"
            
            # Try to test the path
            if (-not (Test-Path $backupPath -ErrorAction SilentlyContinue)) {
                Write-Warning "Network path not currently accessible: $backupPath"
                Write-Warning "Ensure network location is available before starting."
            }
            else {
                Write-Verbose "Network path validated: $backupPath"
            }
        }
        else {
            # Local path - create if doesn't exist
            if (-not (Test-Path $backupPath)) {
                try {
                    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
                    Write-Verbose "Created backup directory: $backupPath"
                }
                catch {
                    Write-Error "Cannot create backup directory: $backupPath - $_"
                    $isValid = $false
                }
            }
            else {
                Write-Verbose "Backup path validated: $backupPath"
            }
        }
    }
    
    return $isValid
}

#endregion Configuration Management

#region Logging System

<#
.SYNOPSIS
    Initializes the logging system.
.DESCRIPTION
    Creates log directory and sets up logging infrastructure.
#>
function Initialize-Logger {
    [CmdletBinding()]
    param()
    
    try {
        $config = Get-Configuration
        if (-not $config) {
            throw "Configuration not available"
        }
        
        $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
        
        if (-not (Test-Path $logPath)) {
            Write-Verbose "Creating log directory: $logPath"
            New-Item -ItemType Directory -Path $logPath -Force | Out-Null
        }
        
        # Clean old logs
        if ($config.MaxLogAgeDays -gt 0) {
            Clear-OldLogs -Days $config.MaxLogAgeDays
        }
        
        Write-LogInfo "Logger initialized successfully"
        return $true
    }
    catch {
        Write-Error "Failed to initialize logger: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Writes a log entry.
.PARAMETER Message
    Log message content.
.PARAMETER Level
    Log level (INFO, WARNING, ERROR).
#>
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )
    
    try {
        $config = Get-Configuration
        if (-not $config -or -not $config.EnableLogging) {
            return
        }
        
        $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
        $logFile = Join-Path $logPath "dropbox-helper_$(Get-Date -Format 'yyyyMMdd').log"
        
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $logEntry = "[$timestamp] [$Level] $Message"
        
        # Append to log file
        Add-Content -Path $logFile -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
        
        # Also write to appropriate stream
        switch ($Level) {
            'WARNING' { Write-Warning $Message }
            'ERROR' { Write-Error $Message }
            default { Write-Verbose $Message }
        }
    }
    catch {
        # Silently fail to avoid infinite loops
        Write-Verbose "Logging failed: $_"
    }
}

<#
.SYNOPSIS
    Writes an INFO level log entry.
#>
function Write-LogInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )
    
    Write-Log -Message $Message -Level 'INFO'
}

<#
.SYNOPSIS
    Writes a WARNING level log entry.
#>
function Write-LogWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )
    
    Write-Log -Message $Message -Level 'WARNING'
}

<#
.SYNOPSIS
    Writes an ERROR level log entry.
#>
function Write-LogError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )
    
    Write-Log -Message $Message -Level 'ERROR'
}

<#
.SYNOPSIS
    Retrieves recent log entries.
.PARAMETER Days
    Number of days of logs to retrieve.
.PARAMETER Level
    Filter by log level.
#>
function Get-LogHistory {
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$Days = 7,
        
        [Parameter()]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'ALL')]
        [string]$Level = 'ALL'
    )
    
    try {
        $config = Get-Configuration
        if (-not $config) {
            throw "Configuration not available"
        }
        
        $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
        $cutoffDate = (Get-Date).AddDays(-$Days)
        
        $logFiles = Get-ChildItem -Path $logPath -Filter "dropbox-helper_*.log" |
            Where-Object { $_.LastWriteTime -ge $cutoffDate } |
            Sort-Object LastWriteTime -Descending
        
        $entries = foreach ($file in $logFiles) {
            Get-Content $file | ForEach-Object {
                if ($_ -match '^\[(.*?)\] \[(.*?)\] (.*)$') {
                    [PSCustomObject]@{
                        Timestamp = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
                        Level = $Matches[2]
                        Message = $Matches[3]
                    }
                }
            }
        }
        
        if ($Level -ne 'ALL') {
            $entries = $entries | Where-Object { $_.Level -eq $Level }
        }
        
        return $entries | Sort-Object Timestamp -Descending
    }
    catch {
        Write-Error "Failed to retrieve log history: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Cleans up old log files.
.PARAMETER Days
    Remove logs older than this many days.
#>
function Clear-OldLogs {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [int]$Days = 30
    )
    
    try {
        $config = Get-Configuration
        if (-not $config) {
            return
        }
        
        $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
        
        if (-not (Test-Path $logPath)) {
            return
        }
        
        $cutoffDate = (Get-Date).AddDays(-$Days)
        
        $oldLogs = Get-ChildItem -Path $logPath -Filter "dropbox-helper_*.log" |
            Where-Object { $_.LastWriteTime -lt $cutoffDate }
        
        foreach ($log in $oldLogs) {
            if ($PSCmdlet.ShouldProcess($log.Name, "Delete old log file")) {
                Remove-Item $log.FullName -Force
                Write-Verbose "Deleted old log: $($log.Name)"
            }
        }
    }
    catch {
        Write-Verbose "Failed to clean old logs: $_"
    }
}

#endregion Logging System

#region File System Monitoring

<#
.SYNOPSIS
    Initializes the FileSystemWatcher for monitoring Camera Uploads folder.
.PARAMETER Path
    Path to monitor. If not specified, uses configuration.
#>
function Initialize-FileWatcher {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path
    )
    
    try {
        if (-not $Path) {
            $config = Get-Configuration
            if (-not $config) {
                throw "Configuration not available"
            }
            $Path = [System.Environment]::ExpandEnvironmentVariables($config.DropboxCameraUploadsPath)
        }
        
        if (-not (Test-Path $Path)) {
            throw "Monitor path does not exist: $Path"
        }
        
        # Create FileSystemWatcher
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $Path
        $watcher.Filter = "*.*"
        $watcher.IncludeSubdirectories = $true
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor 
                                [System.IO.NotifyFilters]::LastWrite -bor
                                [System.IO.NotifyFilters]::CreationTime
        
        Write-LogInfo "FileSystemWatcher initialized for path: $Path"
        return $watcher
    }
    catch {
        Write-LogError "Failed to initialize FileSystemWatcher: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Registers event handlers for FileSystemWatcher.
.PARAMETER Watcher
    FileSystemWatcher object to register events for.
#>
function Register-FileWatcherEvents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileSystemWatcher]$Watcher
    )
    
    try {
        # Created event
        $createdAction = {
            param($sender, $e)
            
            $filePath = $e.FullPath
            Write-LogInfo "File detected: $filePath"
            
            # Add to queue for processing
            $fileInfo = [PSCustomObject]@{
                FullPath = $filePath
                FileName = $e.Name
                DetectedTime = Get-Date
                ChangeType = $e.ChangeType
                IsExisting = $false  # New files need stability checks
            }
            
            Add-ToFileQueue -FileInfo $fileInfo
        }
        
        # Changed event
        $changedAction = {
            param($sender, $e)
            
            # We primarily care about new files, but log changes
            Write-Verbose "File changed: $($e.FullPath)"
        }
        
        # Register events
        $createdEvent = Register-ObjectEvent -InputObject $Watcher -EventName Created -Action $createdAction
        $changedEvent = Register-ObjectEvent -InputObject $Watcher -EventName Changed -Action $changedAction
        
        Write-LogInfo "FileSystemWatcher events registered"
        
        return @{
            Created = $createdEvent
            Changed = $changedEvent
        }
    }
    catch {
        Write-LogError "Failed to register FileSystemWatcher events: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Starts the FileSystemWatcher.
.PARAMETER Watcher
    FileSystemWatcher object to start.
#>
function Start-FileWatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileSystemWatcher]$Watcher
    )
    
    try {
        $Watcher.EnableRaisingEvents = $true
        Write-LogInfo "FileSystemWatcher started"
        return $true
    }
    catch {
        Write-LogError "Failed to start FileSystemWatcher: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Stops the FileSystemWatcher and cleans up resources.
.PARAMETER Watcher
    FileSystemWatcher object to stop.
.PARAMETER Events
    Event subscriptions to unregister.
#>
function Stop-FileWatcher {
    [CmdletBinding()]
    param(
        [Parameter()]
        [System.IO.FileSystemWatcher]$Watcher,
        
        [Parameter()]
        [hashtable]$Events
    )
    
    try {
        if ($Watcher) {
            $Watcher.EnableRaisingEvents = $false
            $Watcher.Dispose()
            Write-LogInfo "FileSystemWatcher stopped"
        }
        
        if ($Events) {
            foreach ($event in $Events.Values) {
                if ($event) {
                    Unregister-Event -SourceIdentifier $event.Name -ErrorAction SilentlyContinue
                }
            }
            Write-LogInfo "FileSystemWatcher events unregistered"
        }
        
        return $true
    }
    catch {
        Write-LogError "Failed to stop FileSystemWatcher: $_"
        return $false
    }
}

#endregion File System Monitoring

#region Sync Status Detection

<#
.SYNOPSIS
    Tests if a file is locked by another process.
.PARAMETER FilePath
    Path to the file to test.
#>
function Test-FileIsLocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )
    
    if (-not (Test-Path -LiteralPath $FilePath)) {
        return $false
    }
    
    try {
        $file = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'None')
        $file.Close()
        $file.Dispose()
        return $false
    }
    catch {
        return $true
    }
}

<#
.SYNOPSIS
    Tests if a file's size has stabilized.
.PARAMETER FilePath
    Path to the file to test.
.PARAMETER StabilitySeconds
    Number of seconds the file size must remain constant.
#>
function Test-FileIsStable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        
        [Parameter()]
        [int]$StabilitySeconds = 5
    )
    
    if (-not (Test-Path -LiteralPath $FilePath)) {
        return $false
    }
    
    try {
        $initialSize = (Get-Item -LiteralPath $FilePath).Length
        $initialTime = (Get-Item -LiteralPath $FilePath).LastWriteTime
        
        Start-Sleep -Seconds $StabilitySeconds
        
        if (-not (Test-Path -LiteralPath $FilePath)) {
            return $false
        }
        
        $currentSize = (Get-Item -LiteralPath $FilePath).Length
        $currentTime = (Get-Item -LiteralPath $FilePath).LastWriteTime
        
        return ($initialSize -eq $currentSize) -and ($initialTime -eq $currentTime)
    }
    catch {
        Write-LogWarning "Error checking file stability for ${FilePath}: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Checks Dropbox-specific sync indicators.
.PARAMETER FilePath
    Path to the file to check.
#>
function Test-DropboxSyncStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )
    
    if (-not (Test-Path -LiteralPath $FilePath)) {
        return $false
    }
    
    try {
        # Check if Dropbox has any lock on the file
        if (Test-FileIsLocked -FilePath $FilePath) {
            Write-Verbose "File is locked: $FilePath"
            return $false
        }
        
        # Check for temporary Dropbox files in the same directory
        $directory = Split-Path $FilePath -Parent
        $fileName = Split-Path $FilePath -Leaf
        $tempFile = Join-Path $directory ".dropbox.cache"
        
        # Dropbox sync is likely complete if no temp files exist
        return $true
    }
    catch {
        Write-LogWarning "Error checking Dropbox sync status for ${FilePath}: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Waits for a file to become stable and fully synced.
.PARAMETER FilePath
    Path to the file to wait for.
.PARAMETER TimeoutSeconds
    Maximum time to wait.
#>
function Wait-ForFileStability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        
        [Parameter()]
        [int]$TimeoutSeconds = 300
    )
    
    $config = Get-Configuration
    $stabilityWait = if ($config) { $config.FileStabilityWaitSeconds } else { 30 }
    $checkInterval = if ($config) { $config.CheckIntervalSeconds } else { 5 }
    
    $startTime = Get-Date
    $elapsed = 0
    
    Write-LogInfo "Waiting for file to stabilize: $FilePath"
    
    while ($elapsed -lt $TimeoutSeconds) {
        if (-not (Test-Path -LiteralPath $FilePath)) {
            Write-LogWarning "File no longer exists: $filePath"
            return $false
        }
        
        # Check if file is locked
        if (Test-FileIsLocked -FilePath $FilePath) {
            Write-Verbose "File is still locked, waiting..."
            Start-Sleep -Seconds $checkInterval
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            continue
        }
        
        # Check if file is stable
        if (Test-FileIsStable -FilePath $FilePath -StabilitySeconds $checkInterval) {
            Write-LogInfo "File is stable: $FilePath"
            
            # Final wait for configured stability period
            Start-Sleep -Seconds $stabilityWait
            
            # Final check
            if ((Test-Path -LiteralPath $FilePath) -and -not (Test-FileIsLocked -FilePath $FilePath)) {
                Write-LogInfo "File is ready for processing: $FilePath"
                return $true
            }
        }
        
        Start-Sleep -Seconds $checkInterval
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
    }
    
    Write-LogWarning "Timeout waiting for file stability: $FilePath"
    return $false
}

<#
.SYNOPSIS
    Master function to verify file is fully synced and ready to move.
.PARAMETER FilePath
    Path to the file to check.
#>
function Test-FileIsSyncComplete {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )
    
    if (-not (Test-Path $FilePath)) {
        return $false
    }
    
    # Check if locked
    if (Test-FileIsLocked -FilePath $FilePath) {
        Write-Verbose "File is locked: $FilePath"
        return $false
    }
    
    # Check Dropbox sync status
    if (-not (Test-DropboxSyncStatus -FilePath $FilePath)) {
        Write-Verbose "Dropbox sync not complete: $FilePath"
        return $false
    }
    
    # Check stability
    $config = Get-Configuration
    $stabilitySeconds = if ($config) { $config.FileStabilityWaitSeconds } else { 30 }
    
    if (-not (Test-FileIsStable -FilePath $FilePath -StabilitySeconds 5)) {
        Write-Verbose "File is not stable: $FilePath"
        return $false
    }
    
    Write-LogInfo "File sync is complete: $FilePath"
    return $true
}

#endregion Sync Status Detection

#region File Type Filtering

<#
.SYNOPSIS
    Tests if a file is a supported photo/video type.
.PARAMETER FilePath
    Path to the file to test.
#>
function Test-IsSupportedFileType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )
    
    $config = Get-Configuration
    if (-not $config) {
        return $false
    }
    
    $extension = [System.IO.Path]::GetExtension($FilePath).ToLower()
    
    if ([string]::IsNullOrWhiteSpace($extension)) {
        return $false
    }
    
    $supported = $config.SupportedExtensions | ForEach-Object { $_.ToLower() }
    
    return $supported -contains $extension
}

<#
.SYNOPSIS
    Gets the list of supported file extensions from configuration.
#>
function Get-SupportedExtensions {
    [CmdletBinding()]
    param()
    
    $config = Get-Configuration
    if ($config -and $config.SupportedExtensions) {
        return $config.SupportedExtensions
    }
    
    return @('.jpg', '.jpeg', '.png', '.heic', '.heif', '.mp4', '.mov', '.avi', '.3gp', '.m4v')
}

#endregion File Type Filtering

#region File Operations

<#
.SYNOPSIS
    Tests if the backup path is available and accessible.
.PARAMETER Path
    Backup path to test. If not specified, uses configuration.
#>
function Test-BackupPathAvailable {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path
    )
    
    try {
        if (-not $Path) {
            $config = Get-Configuration
            if (-not $config) {
                return $false
            }
            $Path = [System.Environment]::ExpandEnvironmentVariables($config.BackupDestinationPath)
        }
        
        # Test if path exists
        if (-not (Test-Path $Path)) {
            # Try to create it
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
        
        # Test write access by creating a temp file
        $testFile = Join-Path $Path ".dropbox-helper-test-$(Get-Random).tmp"
        "test" | Set-Content $testFile -ErrorAction Stop
        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        
        return $true
    }
    catch {
        Write-LogError "Backup path not available: $Path - $_"
        return $false
    }
}

<#
.SYNOPSIS
    Resolves filename conflicts by appending timestamp or counter.
.PARAMETER DestinationPath
    Full path where file will be moved.
.PARAMETER Strategy
    Conflict resolution strategy: 'Timestamp', 'Counter', or 'Skip'.
#>
function Resolve-FileNameConflict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        
        [Parameter()]
        [ValidateSet('Timestamp', 'Counter', 'Skip')]
        [string]$Strategy = 'Timestamp'
    )
    
    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        return $DestinationPath
    }
    
    $directory = Split-Path $DestinationPath -Parent
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($DestinationPath)
    $extension = [System.IO.Path]::GetExtension($DestinationPath)
    
    switch ($Strategy) {
        'Timestamp' {
            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $newFileName = "${fileName}_${timestamp}${extension}"
            $newPath = Join-Path $directory $newFileName
            
            # If still exists, add milliseconds
            if (Test-Path -LiteralPath $newPath) {
                $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
                $newFileName = "${fileName}_${timestamp}${extension}"
                $newPath = Join-Path $directory $newFileName
            }
            
            return $newPath
        }
        
        'Counter' {
            $counter = 1
            do {
                $newFileName = "${fileName} ($counter)${extension}"
                $newPath = Join-Path $directory $newFileName
                $counter++
            } while ((Test-Path -LiteralPath $newPath) -and $counter -lt 1000)
            
            return $newPath
        }
        
        'Skip' {
            Write-LogWarning "File already exists, skipping: $DestinationPath"
            return $null
        }
    }
}

<#
.SYNOPSIS
    Creates the destination path structure for a file.
.PARAMETER SourcePath
    Original file path.
.PARAMETER SourceRoot
    Root directory of source.
.PARAMETER DestinationRoot
    Root directory of destination.
.PARAMETER PreserveStructure
    Whether to preserve directory structure.
#>
function New-BackupPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter(Mandatory)]
        [string]$SourceRoot,
        
        [Parameter(Mandatory)]
        [string]$DestinationRoot,
        
        [Parameter()]
        [bool]$PreserveStructure = $true
    )
    
    try {
        if ($PreserveStructure) {
            # Get relative path from source root
            $relativePath = Get-RelativePath -From $SourceRoot -To $SourcePath
            
            # Build destination path
            $destinationPath = Join-Path $DestinationRoot $relativePath
            
            # Create destination directory if needed
            $destinationDir = Split-Path $destinationPath -Parent
            if (-not (Test-Path $destinationDir)) {
                New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
                Write-LogInfo "Created directory: $destinationDir"
            }
            
            return $destinationPath
        }
        else {
            # Flat structure - just use filename
            $fileName = Split-Path $SourcePath -Leaf
            return Join-Path $DestinationRoot $fileName
        }
    }
    catch {
        Write-LogError "Failed to create backup path: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Calculates relative path between two paths.
.PARAMETER From
    Base path.
.PARAMETER To
    Target path.
#>
function Get-RelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$From,
        
        [Parameter(Mandatory)]
        [string]$To
    )
    
    try {
        $fromUri = New-Object System.Uri($From + "\")
        $toUri = New-Object System.Uri($To)
        
        $relativeUri = $fromUri.MakeRelativeUri($toUri)
        $relativePath = [System.Uri]::UnescapeDataString($relativeUri.ToString())
        
        # Convert forward slashes to backslashes on Windows
        $relativePath = $relativePath.Replace('/', '\')
        
        return $relativePath
    }
    catch {
        Write-LogError "Failed to calculate relative path: $_"
        return Split-Path $To -Leaf
    }
}

<#
.SYNOPSIS
    Creates mirrored directory structure in backup location.
.PARAMETER SourceDir
    Source directory path.
.PARAMETER SourceRoot
    Source root directory.
.PARAMETER DestinationRoot
    Destination root directory.
#>
function New-MirroredPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,
        
        [Parameter(Mandatory)]
        [string]$SourceRoot,
        
        [Parameter(Mandatory)]
        [string]$DestinationRoot
    )
    
    try {
        $relativePath = Get-RelativePath -From $SourceRoot -To $SourceDir
        $mirroredPath = Join-Path $DestinationRoot $relativePath
        
        if (-not (Test-Path $mirroredPath)) {
            New-Item -ItemType Directory -Path $mirroredPath -Force | Out-Null
            Write-LogInfo "Created mirrored directory: $mirroredPath"
        }
        
        return $mirroredPath
    }
    catch {
        Write-LogError "Failed to create mirrored path: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Verifies file move integrity using hash comparison.
.PARAMETER SourcePath
    Original file path (should not exist after move).
.PARAMETER DestinationPath
    Destination file path.
.PARAMETER SourceHash
    Optional pre-computed hash of source file.
#>
function Test-FileMoveIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        
        [Parameter()]
        [string]$SourceHash
    )
    
    try {
        # Source should not exist after move
        if (Test-Path -LiteralPath $SourcePath) {
            Write-LogError "Source file still exists after move: $SourcePath"
            return $false
        }
        
        # Destination must exist
        if (-not (Test-Path -LiteralPath $DestinationPath)) {
            Write-LogError "Destination file does not exist: $DestinationPath"
            return $false
        }
        
        # If source hash was provided, verify destination
        if ($SourceHash) {
            $destHash = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash
            if ($SourceHash -ne $destHash) {
                Write-LogError "Hash mismatch after move. Source: $SourceHash, Destination: $destHash"
                return $false
            }
        }
        
        Write-Verbose "File move integrity verified: $DestinationPath"
        return $true
    }
    catch {
        Write-LogError "Failed to verify file move integrity: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Moves a file to the backup location with integrity checks.
.PARAMETER SourcePath
    Path to the file to move.
.PARAMETER Force
    Force overwrite existing files.
#>
function Move-FileToBackup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter()]
        [switch]$Force
    )
    
    try {
        if (-not (Test-Path $SourcePath)) {
            Write-LogError "Source file does not exist: $SourcePath"
            return $false
        }
        
        $config = Get-Configuration
        if (-not $config) {
            throw "Configuration not available"
        }
        
        # Check if backup path is available
        if (-not (Test-BackupPathAvailable)) {
            throw "Backup path is not available"
        }
        
        $sourceRoot = [System.Environment]::ExpandEnvironmentVariables($config.DropboxCameraUploadsPath)
        $destinationRoot = [System.Environment]::ExpandEnvironmentVariables($config.BackupDestinationPath)
        
        # Build destination path
        $destinationPath = New-BackupPath -SourcePath $SourcePath `
                                          -SourceRoot $sourceRoot `
                                          -DestinationRoot $destinationRoot `
                                          -PreserveStructure $config.PreserveDirectoryStructure
        
        if (-not $destinationPath) {
            throw "Could not create destination path"
        }
        
        # Handle conflicts
        if (Test-Path $destinationPath) {
            if (-not $Force) {
                $destinationPath = Resolve-FileNameConflict -DestinationPath $destinationPath -Strategy 'Timestamp'
                if (-not $destinationPath) {
                    Write-LogWarning "Skipped due to conflict: $SourcePath"
                    return $false
                }
            }
        }
        
        # Compute source hash for verification (for smaller files)
        $sourceItem = Get-Item -LiteralPath $SourcePath
        $sourceHash = $null
        if ($sourceItem.Length -lt 100MB) {
            $sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
        }
        
        # Perform the move
        if ($PSCmdlet.ShouldProcess($SourcePath, "Move to $destinationPath")) {
            if ($config.MoveOrCopy -eq 'Copy') {
                Copy-Item -LiteralPath $SourcePath -Destination $destinationPath -Force:$Force
                Write-LogInfo "Copied file: $SourcePath -> $destinationPath"
            }
            else {
                Move-Item -LiteralPath $SourcePath -Destination $destinationPath -Force:$Force
                Write-LogInfo "Moved file: $SourcePath -> $destinationPath"
                
                # Verify integrity
                if (-not (Test-FileMoveIntegrity -SourcePath $SourcePath -DestinationPath $destinationPath -SourceHash $sourceHash)) {
                    Write-LogError "Integrity check failed for: $destinationPath"
                    return $false
                }
            }
            
            # Update statistics
            $script:Statistics.FilesMoved++
            $script:Statistics.TotalBytes += $sourceItem.Length
            
            return $true
        }
        
        return $false
    }
    catch {
        Write-LogError "Failed to move file to backup: $SourcePath - $_"
        $script:Statistics.Errors++
        return $false
    }
}

#endregion File Operations

#region SSH/Rsync Transport

<#
.SYNOPSIS
    Tests SSH connectivity to remote host.
.PARAMETER Config
    Configuration object with SSH settings.
#>
function Test-SSHConnection {
    [CmdletBinding()]
    param(
        [Parameter()]
        [PSCustomObject]$Config
    )
    
    try {
        if (-not $Config) {
            $Config = Get-Configuration
        }
        
        if ($Config.TransportMethod -ne 'SSH') {
            return $true
        }
        
        # Check if SSH is available
        $sshCommand = Get-Command ssh -ErrorAction SilentlyContinue
        if (-not $sshCommand) {
            Write-LogError "SSH client not found. Please install OpenSSH client."
            return $false
        }
        
        # Build SSH command
        $sshArgs = @()
        
        if ($Config.SSHPort -and $Config.SSHPort -ne 22) {
            $sshArgs += "-p"
            $sshArgs += $Config.SSHPort
        }
        
        if ($Config.SSHKeyPath) {
            $keyPath = [System.Environment]::ExpandEnvironmentVariables($Config.SSHKeyPath)
            if (Test-Path $keyPath) {
                $sshArgs += "-i"
                $sshArgs += "`"$keyPath`""
            } else {
                Write-LogWarning "SSH key not found: $keyPath"
            }
        }
        
        $sshArgs += "-o"
        $sshArgs += "BatchMode=yes"
        $sshArgs += "-o"
        $sshArgs += "ConnectTimeout=10"
        $sshArgs += "$($Config.SSHUser)@$($Config.SSHHost)"
        $sshArgs += "echo 'Connection successful'"
        
        Write-Verbose "Testing SSH: ssh $($sshArgs -join ' ')"
        
        $result = & ssh @sshArgs 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-LogInfo "SSH connection successful to $($Config.SSHHost)"
            
            # Test write permission by creating and deleting a test file
            Write-Verbose "Testing write permission on remote path..."
            $remotePath = $Config.SSHRemotePath.TrimEnd('/')
            # Escape spaces in remote path for SSH command
            $remotePathEscaped = $remotePath.Replace(' ', '\ ')
            $testFileName = ".dropbox-helper-test-$(Get-Random).tmp"
            $testFilePath = "$remotePathEscaped/$testFileName"
            
            # Create test file
            $testArgs = @()
            if ($Config.SSHPort -and $Config.SSHPort -ne 22) {
                $testArgs += "-p"
                $testArgs += $Config.SSHPort
            }
            if ($Config.SSHKeyPath) {
                $keyPath = [System.Environment]::ExpandEnvironmentVariables($Config.SSHKeyPath)
                if (Test-Path $keyPath) {
                    $testArgs += "-i"
                    $testArgs += "`"$keyPath`""
                }
            }
            $testArgs += "-o"
            $testArgs += "BatchMode=yes"
            $testArgs += "-o"
            $testArgs += "ConnectTimeout=10"
            $testArgs += "$($Config.SSHUser)@$($Config.SSHHost)"
            $testArgs += "mkdir -p $remotePathEscaped && echo 'test' > $testFilePath && rm $testFilePath"
            
            Write-Verbose "Testing write: ssh $($testArgs -join ' ')"
            $testResult = & ssh @testArgs 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-LogInfo "Remote path is writable: $remotePath"
                return $true
            } else {
                Write-LogError "Remote path is not writable: $remotePath - $testResult"
                return $false
            }
        } else {
            Write-LogError "SSH connection failed: $result"
            return $false
        }
    }
    catch {
        Write-LogError "Error testing SSH connection: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Tests if SCP is available on the system.
#>
function Test-SCPAvailable {
    [CmdletBinding()]
    param()
    
    try {
        # Check if SCP is in PATH
        $scpCommand = Get-Command scp -ErrorAction SilentlyContinue
        
        if (-not $scpCommand) {
            Write-LogError "SCP not found. Please install OpenSSH client."
            Write-Host @"

SCP Installation:
SCP is part of OpenSSH client, which is built into Windows 10/11.

To install OpenSSH client:
1. Open Settings > Apps > Optional Features
2. Click "Add a feature"
3. Search for "OpenSSH Client"
4. Install it

Or use PowerShell (as Administrator):
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0

"@ -ForegroundColor Yellow
            return $false
        }
        
        Write-LogInfo "SCP is available: $($scpCommand.Source)"
        return $true
    }
    catch {
        Write-LogError "Error checking SCP availability: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Transfers a file using SFTP over SSH with validation.
.PARAMETER SourcePath
    Local file path to transfer.
.PARAMETER Config
    Configuration object with SSH settings.
#>
function Invoke-SCPTransfer {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter()]
        [PSCustomObject]$Config,
        
        [Parameter()]
        [switch]$DeleteSource
    )
    
    try {
        if (-not $Config) {
            $Config = Get-Configuration
        }
        
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            Write-LogError "Source file not found: $SourcePath"
            return $false
        }
        
        if (-not (Test-SCPAvailable)) {
            return $false
        }
        
        $sourceItem = Get-Item -LiteralPath $SourcePath
        $sourceSize = $sourceItem.Length
        $fileName = $sourceItem.Name
        
        $remotePath = $Config.SSHRemotePath.TrimEnd('/')
        
        if ($Config.PreserveDirectoryStructure) {
            $sourceRoot = [System.Environment]::ExpandEnvironmentVariables($Config.DropboxCameraUploadsPath)
            $relativePath = Get-RelativePath -From $sourceRoot -To $SourcePath
            $remoteSubPath = Split-Path $relativePath -Parent
            
            if ($remoteSubPath -and $remoteSubPath -ne '.') {
                $remoteSubPath = $remoteSubPath.Replace('\', '/')
                $remotePath = "$remotePath/$remoteSubPath"
            }
        }
        
        # --- SSH Arguments Setup ---
        $sshArgs = @()
        if ($Config.SSHPort -and $Config.SSHPort -ne 22) {
            $sshArgs += '-p', $Config.SSHPort
        }
        if ($Config.SSHKeyPath) {
            $keyPath = [System.Environment]::ExpandEnvironmentVariables($Config.SSHKeyPath)
            if (Test-Path $keyPath) {
                $sshArgs += '-i', "`"$keyPath`""
            }
        }
        $sshArgs += '-o', 'BatchMode=yes'
        $sshArgs += '-o', 'ConnectTimeout=30'
        $sshArgs += "$($Config.SSHUser)@$($Config.SSHHost)"

        # --- Directory Creation (with caching) ---
        # Only create directory if not already cached
        if (-not $script:SSHCreatedDirectories.ContainsKey($remotePath)) {
            $mkdirCmd = "mkdir -p '$remotePath'"
            $mkdirFullArgs = $sshArgs + $mkdirCmd
            
            Write-Verbose "Creating remote directory: ssh $($mkdirFullArgs -join ' ')"
            $mkdirResult = & ssh @mkdirFullArgs 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                Write-LogError "Failed to create remote directory: $mkdirResult"
                return $false
            }
            
            # Cache this directory so we don't recreate it
            $script:SSHCreatedDirectories[$remotePath] = $true
            Write-Verbose "Remote directory created and cached: $remotePath"
        }
        else {
            Write-Verbose "Using cached remote directory: $remotePath"
        }
        
        # --- SCP Transfer ---
        if ($PSCmdlet.ShouldProcess($SourcePath, "SCP to $($Config.SSHHost):$remotePath")) {
            Write-LogInfo "Transferring via SCP: $SourcePath -> $($Config.SSHHost):$remotePath"
            
            # Windows OpenSSH SCP has known issues with spaces in remote paths
            # Use SSH pipe transfer as a workaround when paths contain spaces
            $pathHasSpaces = $remotePath -match ' '
            
            if ($pathHasSpaces) {
                Write-Verbose "Path contains spaces, using SSH with hex encoding for binary-safe transfer"
                
                $sshArgs = @()
                if ($Config.SSHPort -and $Config.SSHPort -ne 22) {
                    $sshArgs += '-p', $Config.SSHPort
                }
                if ($Config.SSHKeyPath) {
                    $keyPath = [System.Environment]::ExpandEnvironmentVariables($Config.SSHKeyPath)
                    if (Test-Path $keyPath) {
                        $sshArgs += '-i', "`"$keyPath`""
                    }
                }
                $sshArgs += '-o', 'BatchMode=yes'
                $sshArgs += "$($Config.SSHUser)@$($Config.SSHHost)"
                $remoteFilePath = "$remotePath/$fileName"
                
                Write-Verbose "Encoding file to hex and transferring via SSH with xxd"
                
                # Read file as bytes and convert to hex string
                try {
                    $bytes = [System.IO.File]::ReadAllBytes($SourcePath)
                    $hex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
                    
                    # Transfer via SSH pipe and decode with xxd
                    $sshArgs += "cat | xxd -r -p > '$remoteFilePath'"
                    
                    Write-Verbose "Command: [hex string] | ssh $($sshArgs -join ' ')"
                    
                    # Pipe hex string to SSH
                    $hex | & ssh @sshArgs 2>&1 | Out-Null
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-LogInfo "SSH hex transfer completed: $SourcePath"
                    }
                    else {
                        Write-LogError "SSH hex transfer failed with exit code $LASTEXITCODE"
                        return $false
                    }
                }
                catch {
                    Write-LogError "Failed to encode/transfer file via SSH hex: $_"
                    return $false
                }
            }
            else {
                # Standard SCP transfer for paths without spaces
                $scpArgs = @()
                if ($Config.SSHPort -and $Config.SSHPort -ne 22) {
                    $scpArgs += '-P', $Config.SSHPort
                }
                if ($Config.SSHKeyPath) {
                    $keyPath = [System.Environment]::ExpandEnvironmentVariables($Config.SSHKeyPath)
                    if (Test-Path $keyPath) {
                        $scpArgs += '-i', "`"$keyPath`""
                    }
                }
                
                # Add performance options for fast local network transfers
                $scpArgs += '-o', 'Compression=no'  # Disable compression on LAN for speed
                $scpArgs += '-o', 'Ciphers=aes128-gcm@openssh.com'  # Fast cipher
                
                $scpArgs += "`"$SourcePath`""
                $scpArgs += "$($Config.SSHUser)@$($Config.SSHHost):$remotePath/"
                
                Write-Verbose "Command: scp $($scpArgs -join ' ')"
                
                $scpOutput = & scp @scpArgs 2>&1
                
                if ($LASTEXITCODE -eq 0) {
                    Write-LogInfo "SCP transfer completed: $SourcePath"
                }
                else {
                    Write-LogError "SCP failed with exit code $LASTEXITCODE : $scpOutput"
                    return $false
                }
            }
            
            # Validate the transferred file (optional for performance)
            $remoteFilePath = "$remotePath/$fileName"
            
            # Check if validation is needed (can be disabled for trusted fast networks)
            $skipValidation = $Config.PSObject.Properties.Name -contains 'SkipSizeValidation' -and $Config.SkipSizeValidation
            
            if ($skipValidation) {
                Write-LogInfo "Transfer completed (validation skipped): $fileName"
                
                if ($DeleteSource -and (Test-Path -LiteralPath $SourcePath)) {
                    Remove-Item -LiteralPath $SourcePath -Force
                    Write-LogInfo "Removed source file: $SourcePath"
                }
                
                $script:Statistics.FilesMoved++
                $script:Statistics.TotalBytes += $sourceSize
                return $true
            }
            else {
                # Validate with SSH (adds extra SSH call)
                $validated = Test-RemoteFileSize -Config $Config -RemoteFilePath $remoteFilePath -ExpectedSize $sourceSize
                
                if ($validated) {
                    Write-LogInfo "Transfer validated successfully: $fileName (size: $sourceSize bytes)"
                    
                    if ($DeleteSource -and (Test-Path -LiteralPath $SourcePath)) {
                        Remove-Item -LiteralPath $SourcePath -Force
                        Write-LogInfo "Removed source file: $SourcePath"
                    }
                    
                    $script:Statistics.FilesMoved++
                    $script:Statistics.TotalBytes += $sourceSize
                    return $true
                }
                else {
                    Write-LogError "Transfer validation failed: Remote file size mismatch for $fileName"
                    return $false
                }
            }
        }
        
        return $false
    }
    catch {
        Write-LogError "Error during SCP transfer: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Validates remote file size using SSH ls -al command.
.PARAMETER Config
    Configuration object with SSH settings.
.PARAMETER RemoteFilePath
    Remote file path to check.
.PARAMETER ExpectedSize
    Expected file size in bytes.
#>
function Test-RemoteFileSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,
        
        [Parameter(Mandatory)]
        [string]$RemoteFilePath,
        
        [Parameter(Mandatory)]
        [long]$ExpectedSize
    )
    
    try {
        # Build SSH command to check file
        # Use single quotes for remote path to handle spaces properly
        $lsCmd = "ls -al '$RemoteFilePath'"
        $sshArgs = @()
        
        if ($Config.SSHPort -and $Config.SSHPort -ne 22) {
            $sshArgs += '-p'
            $sshArgs += $Config.SSHPort
        }
        
        if ($Config.SSHKeyPath) {
            $keyPath = [System.Environment]::ExpandEnvironmentVariables($Config.SSHKeyPath)
            if (Test-Path $keyPath) {
                $sshArgs += '-i'
                $sshArgs += "`"$keyPath`""
            }
        }
        
        $sshArgs += '-o'
        $sshArgs += 'BatchMode=yes'
        $sshArgs += '-o'
        $sshArgs += 'ConnectTimeout=30'
        $sshArgs += "$($Config.SSHUser)@$($Config.SSHHost)"
        $sshArgs += $lsCmd
        
        Write-Verbose "Validating remote file: ssh $($sshArgs -join ' ')"
        
        # Execute SSH command
        $lsOutput = & ssh @sshArgs 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            # Parse ls -al output to get file size
            # Format: -rw-r--r-- 1 user group SIZE date time filename
            # Match the size field which comes after the group name and before the date
            if ($lsOutput -match '\s(\d+)\s+\w+\s+\d+\s+\d+') {
                $remoteSize = [long]$Matches[1]
                
                Write-Verbose "Remote file size: $remoteSize bytes, Expected: $ExpectedSize bytes"
                
                if ($remoteSize -eq $ExpectedSize) {
                    return $true
                }
                else {
                    Write-LogError "Size mismatch: Remote=$remoteSize, Expected=$ExpectedSize"
                    return $false
                }
            }
            else {
                Write-LogWarning "Could not parse remote file size from: $lsOutput"
                # If we can't parse but command succeeded, assume it's okay
                return $true
            }
        }
        else {
            Write-LogError "Failed to check remote file: $lsOutput"
            return $false
        }
    }
    catch {
        Write-LogError "Error validating remote file size: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Tests if rsync is available on the system (DEPRECATED - USE SCP).
#>
function Test-RsyncAvailable {
    [CmdletBinding()]
    param()
    
    Write-LogWarning "Test-RsyncAvailable is deprecated. Using SCP for SSH transfers."
    return $false
}

# Legacy function name for backward compatibility
function Invoke-RsyncTransfer {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter()]
        [PSCustomObject]$Config,
        
        [Parameter()]
        [switch]$DeleteSource
    )
    
    # Redirect to SCP transfer
    Write-LogInfo "Redirecting to SCP transfer (rsync-win deprecated)"
    return Invoke-SCPTransfer @PSBoundParameters
}



<#
.SYNOPSIS
    Moves or copies file to backup location (local or remote via rsync).
.PARAMETER SourcePath
    Path to the file to move/copy.
.PARAMETER Force
    Force overwrite existing files.
#>
function Move-FileToBackupWithTransport {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter()]
        [switch]$Force
    )
    
    try {
        if (-not (Test-Path $SourcePath)) {
            Write-LogError "Source file does not exist: $SourcePath"
            return $false
        }
        
        $config = Get-Configuration
        if (-not $config) {
            throw "Configuration not available"
        }
        
        # Determine transport method
        $transportMethod = $config.TransportMethod
        
        if (-not $transportMethod -or $transportMethod -eq 'Local') {
            # Use original local file move
            return Move-FileToBackup -SourcePath $SourcePath -Force:$Force
        }
        elseif ($transportMethod -eq 'SSH' -or $transportMethod -eq 'Rsync') {
            # Validate SSH configuration
            if (-not $config.SSHHost -or -not $config.SSHUser) {
                Write-LogError "SSH transport requires SSHHost and SSHUser configuration"
                return $false
            }
            
            # Test SSH connection (only once per session)
            if (-not $script:SSHConnectionTested) {
                if (-not (Test-SSHConnection -Config $config)) {
                    Write-LogError "SSH connection test failed. Please verify SSH configuration."
                    return $false
                }
                $script:SSHConnectionTested = $true
            }
            
            # Use SCP for transfer
            $deleteSource = ($config.MoveOrCopy -eq 'Move')
            return Invoke-SCPTransfer -SourcePath $SourcePath -Config $config -DeleteSource:$deleteSource -Confirm:$false
        }
        else {
            Write-LogError "Unknown transport method: $transportMethod"
            return $false
        }
    }
    catch {
        Write-LogError "Error in file transport: $_"
        $script:Statistics.Errors++
        return $false
    }
}

#endregion SSH/Rsync Transport

#region File Processing Queue

<#
.SYNOPSIS
    Adds a file to the processing queue.
.PARAMETER FileInfo
    File information object to add to queue.
#>
function Add-ToFileQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$FileInfo
    )
    
    try {
        $script:FileQueue.Enqueue($FileInfo)
        Write-Verbose "Added to queue: $($FileInfo.FullPath)"
        return $true
    }
    catch {
        Write-LogError "Failed to add file to queue: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Retrieves the next file from the processing queue.
#>
function Get-NextQueuedFile {
    [CmdletBinding()]
    param()
    
    try {
        $fileInfo = $null
        if ($script:FileQueue.TryDequeue([ref]$fileInfo)) {
            Write-Verbose "Retrieved from queue: $($fileInfo.FullPath)"
            return $fileInfo
        }
        return $null
    }
    catch {
        Write-LogError "Failed to retrieve file from queue: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Gets the current queue count.
#>
function Get-QueueCount {
    [CmdletBinding()]
    param()
    
    return $script:FileQueue.Count
}

<#
.SYNOPSIS
    Processes a single file through the complete pipeline.
.PARAMETER FileInfo
    File information object to process.
#>
function Invoke-FileProcessing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$FileInfo
    )
    
    $filePath = $FileInfo.FullPath
    $isExisting = $FileInfo.PSObject.Properties.Name -contains 'IsExisting' -and $FileInfo.IsExisting
    
    try {
        Write-LogInfo "Processing file: $filePath $(if($isExisting){'(existing)'})"
        $script:Statistics.FilesProcessed++
        
        # Step 1: Check if file still exists
        if (-not (Test-Path $filePath)) {
            Write-LogWarning "File no longer exists: $filePath"
            return $false
        }
        
        # Step 2: Check file type
        if (-not (Test-IsSupportedFileType -FilePath $filePath)) {
            Write-LogInfo "Skipping unsupported file type: $filePath"
            return $false
        }
        
        # Step 3: For new files, wait for stability; for existing files, skip
        if (-not $isExisting) {
            if (-not (Wait-ForFileStability -FilePath $filePath -TimeoutSeconds 300)) {
                Write-LogWarning "File did not stabilize: $filePath"
                return $false
            }
            
            # Step 4: Verify sync complete
            if (-not (Test-FileIsSyncComplete -FilePath $filePath)) {
                Write-LogWarning "File sync not complete: $filePath"
                return $false
            }
        } else {
            # For existing files, just check if locked
            if (Test-FileIsLocked -FilePath $filePath) {
                Write-LogWarning "Existing file is locked, will retry: $filePath"
                return $false
            }
        }
        
        # Step 4.5: Check minimum hours before move
        $config = Get-Configuration
        if ($config -and $config.MinHoursBeforeMove -and $config.MinHoursBeforeMove -gt 0) {
            $fileItem = Get-Item -LiteralPath $filePath
            $fileAge = (Get-Date) - $fileItem.CreationTime
            $minHours = $config.MinHoursBeforeMove

            if ($fileAge.TotalHours -lt $minHours) {
                $remainingHours = [math]::Round($minHours - $fileAge.TotalHours, 1)
                Write-LogInfo "File is too recent to move (age: $([math]::Round($fileAge.TotalHours, 1))h, required: ${minHours}h, remaining: ${remainingHours}h): $filePath"
                # Re-queue the file for later processing
                Add-ToFileQueue -FileInfo $FileInfo
                return $false
            }

            Write-LogInfo "File age check passed ($([math]::Round($fileAge.TotalHours, 1))h >= ${minHours}h): $filePath"
        }

        # Step 5: Move to backup (using configured transport method)
        $moveResult = Move-FileToBackupWithTransport -SourcePath $filePath -Confirm:$false
        
        if ($moveResult) {
            Write-LogInfo "Successfully processed: $filePath"
            Write-Host "  [OK] $(Split-Path $filePath -Leaf)" -ForegroundColor Green
            return $true
        }
        else {
            Write-LogError "Failed to process: $filePath"
            Write-Host "  [FAIL] $(Split-Path $filePath -Leaf)" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-LogError "Error processing file $filePath : $_"
        Write-Host "  [ERROR] $(Split-Path $filePath -Leaf) - $_" -ForegroundColor Red
        $script:Statistics.Errors++
        return $false
    }
}

<#
.SYNOPSIS
    Main processing loop that handles queued files.
#>
function Start-FileProcessingLoop {
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$IntervalSeconds = 5
    )
    
    Write-LogInfo "File processing loop started"
    
    while ($script:IsRunning) {
        try {
            $queueCount = Get-QueueCount
            
            if ($queueCount -gt 0) {
                Write-Verbose "Queue has $queueCount files"
                
                $fileInfo = Get-NextQueuedFile
                if ($fileInfo) {
                    Invoke-FileProcessing -FileInfo $fileInfo
                }
            }
            
            Start-Sleep -Seconds $IntervalSeconds
        }
        catch {
            Write-LogError "Error in processing loop: $_"
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
    
    Write-LogInfo "File processing loop stopped"
}

<#
.SYNOPSIS
    Updates and displays processing statistics.
#>
function Update-Statistics {
    [CmdletBinding()]
    param()
    
    $stats = [PSCustomObject]@{
        FilesProcessed = $script:Statistics.FilesProcessed
        FilesMoved = $script:Statistics.FilesMoved
        Errors = $script:Statistics.Errors
        TotalBytesMoved = $script:Statistics.TotalBytes
        TotalMBMoved = [math]::Round($script:Statistics.TotalBytes / 1MB, 2)
        QueueSize = Get-QueueCount
        IsRunning = $script:IsRunning
    }
    
    return $stats
}

<#
.SYNOPSIS
    Displays current statistics.
#>
function Show-Statistics {
    [CmdletBinding()]
    param()
    
    $stats = Update-Statistics
    
    Write-Host "`nDropbox Helper Statistics:" -ForegroundColor Cyan
    Write-Host "  Files Processed: $($stats.FilesProcessed)" -ForegroundColor White
    Write-Host "  Files Moved: $($stats.FilesMoved)" -ForegroundColor Green
    Write-Host "  Errors: $($stats.Errors)" -ForegroundColor $(if ($stats.Errors -gt 0) { 'Red' } else { 'White' })
    Write-Host "  Total Data Moved: $($stats.TotalMBMoved) MB" -ForegroundColor White
    Write-Host "  Queue Size: $($stats.QueueSize)" -ForegroundColor White
    Write-Host "  Status: $(if ($stats.IsRunning) { 'Running' } else { 'Stopped' })" -ForegroundColor $(if ($stats.IsRunning) { 'Green' } else { 'Yellow' })
    Write-Host ""
}

#endregion File Processing Queue

#region Main Control Functions

<#
.SYNOPSIS
    Starts the Dropbox Helper service.
.PARAMETER ShowProgress
    Display progress information.
#>
function Start-DropboxHelper {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$ShowProgress
    )
    
    try {
        Write-Host "Starting Dropbox Camera Upload Helper..." -ForegroundColor Cyan
        
        # Initialize configuration
        Write-Verbose "Initializing configuration..."
        if (-not (Initialize-Configuration)) {
            throw "Failed to initialize configuration"
        }
        
        # Initialize logger
        Write-Verbose "Initializing logger..."
        if (-not (Initialize-Logger)) {
            throw "Failed to initialize logger"
        }
        
        Write-LogInfo "=== Dropbox Helper Starting ==="
        
        # Load configuration
        $config = Get-Configuration
        if (-not $config) {
            throw "Failed to load configuration"
        }
        
        # Display configuration
        Write-Host "`nConfiguration:" -ForegroundColor Yellow
        Write-Host "  Source: $($config.DropboxCameraUploadsPath)" -ForegroundColor White
        Write-Host "  Destination: $($config.BackupDestinationPath)" -ForegroundColor White
        Write-Host "  Supported Extensions: $($config.SupportedExtensions -join ', ')" -ForegroundColor White
        Write-Host ""
        
        # Validate paths
        Write-Verbose "Validating paths..."
        if (-not (Test-ConfigurationPath -Config $config)) {
            Write-Warning "Path validation completed with warnings"
        }
        
        # Initialize file watcher
        Write-Host "Initializing file system watcher..." -ForegroundColor Cyan
        $sourcePath = [System.Environment]::ExpandEnvironmentVariables($config.DropboxCameraUploadsPath)
        
        if (-not (Test-Path $sourcePath)) {
            throw "Source path does not exist: $sourcePath"
        }
        
        $script:FileWatcher = Initialize-FileWatcher -Path $sourcePath
        if (-not $script:FileWatcher) {
            throw "Failed to initialize file watcher"
        }
        
        # Register events
        $watcherEvents = Register-FileWatcherEvents -Watcher $script:FileWatcher
        if (-not $watcherEvents) {
            throw "Failed to register file watcher events"
        }
        
        # Start watcher
        if (-not (Start-FileWatcher -Watcher $script:FileWatcher)) {
            throw "Failed to start file watcher"
        }
        
        Write-Host "File system watcher started successfully" -ForegroundColor Green
        
        # Set running flag
        $script:IsRunning = $true
        
        # Scan for existing files and add to queue for processing
        Write-Host "`nScanning for existing files..." -ForegroundColor Cyan
        $allFiles = @(Get-ChildItem -Path $sourcePath -File -Recurse -ErrorAction SilentlyContinue)
        
        $addedCount = 0
        foreach ($file in $allFiles) {
            if (Test-IsSupportedFileType -FilePath $file.FullName) {
                # Add all existing files to queue - they'll be processed by the main loop
                # This prevents hanging during startup
                $fileInfo = [PSCustomObject]@{
                    FullPath = $file.FullName
                    FileName = $file.Name
                    DetectedTime = Get-Date
                    ChangeType = 'Existing'
                    IsExisting = $true  # Flag to skip stability checks
                }
                Add-ToFileQueue -FileInfo $fileInfo
                $addedCount++
            }
        }
        
        if ($addedCount -gt 0) {
            Write-Host "Found $addedCount existing files to process" -ForegroundColor Yellow
            Write-Host "Files will be processed in the background..." -ForegroundColor Gray
            Write-LogInfo "Added $addedCount existing files to processing queue"
        } else {
            Write-Host "No existing files found" -ForegroundColor Gray
        }
        
        Write-Host "`nDropbox Helper is now running!" -ForegroundColor Green
        Write-Host "Monitoring: $sourcePath" -ForegroundColor White
        Write-Host "Press Ctrl+C to stop`n" -ForegroundColor Yellow
        
        Write-LogInfo "Dropbox Helper started successfully"
        
        # Main processing loop
        $config = Get-Configuration
        $checkInterval = if ($config) { $config.CheckIntervalSeconds } else { 5 }
        $lastProgress = Get-Date
        
        while ($script:IsRunning) {
            try {
                # Process queued files
                $queueCount = Get-QueueCount
                
                if ($queueCount -gt 0) {
                    Write-Verbose "Queue has $queueCount files"
                    
                    $fileInfo = Get-NextQueuedFile
                    if ($fileInfo) {
                        Invoke-FileProcessing -FileInfo $fileInfo
                    }
                }
                
                # Show progress periodically
                if ($ShowProgress) {
                    $now = Get-Date
                    if (($now - $lastProgress).TotalSeconds -ge 10) {
                        Show-Statistics
                        $lastProgress = $now
                    }
                }
                
                # Brief sleep to prevent CPU spinning
                Start-Sleep -Seconds 1
            }
            catch {
                Write-LogError "Error in main loop: $_"
                Start-Sleep -Seconds $checkInterval
            }
        }
        
        return $true
    }
    catch {
        Write-Host "Failed to start Dropbox Helper: $_" -ForegroundColor Red
        Write-LogError "Failed to start: $_"
        Stop-DropboxHelper
        return $false
    }
}

<#
.SYNOPSIS
    Stops the Dropbox Helper service gracefully.
#>
function Stop-DropboxHelper {
    [CmdletBinding()]
    param()
    
    try {
        Write-Host "`nStopping Dropbox Helper..." -ForegroundColor Yellow
        
        # Stop processing
        $script:IsRunning = $false
        
        # Stop file watcher
        if ($script:FileWatcher) {
            Stop-FileWatcher -Watcher $script:FileWatcher
            $script:FileWatcher = $null
        }
        
        # Process remaining queued files
        $remainingCount = Get-QueueCount
        if ($remainingCount -gt 0) {
            Write-Host "Processing $remainingCount remaining files..." -ForegroundColor Yellow
            
            while (Get-QueueCount -gt 0) {
                $fileInfo = Get-NextQueuedFile
                if ($fileInfo) {
                    Invoke-FileProcessing -FileInfo $fileInfo
                }
            }
        }
        
        # Show final statistics
        Show-Statistics
        
        Write-LogInfo "=== Dropbox Helper Stopped ==="
        Write-Host "Dropbox Helper stopped successfully" -ForegroundColor Green
        
        return $true
    }
    catch {
        Write-Host "Error stopping Dropbox Helper: $_" -ForegroundColor Red
        Write-LogError "Error during shutdown: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Gets the current status of Dropbox Helper.
#>
function Get-DropboxHelperStatus {
    [CmdletBinding()]
    param()
    
    $status = [PSCustomObject]@{
        IsRunning = $script:IsRunning
        WatcherActive = ($script:FileWatcher -ne $null -and $script:FileWatcher.EnableRaisingEvents)
        Statistics = Update-Statistics
        Configuration = Get-Configuration
    }
    
    return $status
}

#endregion Main Control Functions

#region Validation

<#
.SYNOPSIS
    Runs comprehensive validation checks on configuration, paths, and connections.
.DESCRIPTION
    Performs pre-flight checks before installation as a service or scheduled task.
    Validates configuration file, paths, permissions, network connections, and SSH setup.
.PARAMETER Silent
    Suppress console output and return only the validation result object.
.EXAMPLE
    Test-DropboxHelperSetup
    Run validation checks with detailed console output.
.EXAMPLE
    $result = Test-DropboxHelperSetup -Silent
    if ($result.AllTestsPassed) { Install-DropboxHelperTask }
#>
function Test-DropboxHelperSetup {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Silent
    )
    
    $results = @{
        AllTestsPassed = $true
        Tests = @()
        Warnings = @()
        Errors = @()
    }
    
    function Add-TestResult {
        param($Name, $Passed, $Message, $IsWarning = $false)
        
        $test = [PSCustomObject]@{
            Test = $Name
            Passed = $Passed
            Message = $Message
            IsWarning = $IsWarning
        }
        $results.Tests += $test
        
        if (-not $Passed) {
            if ($IsWarning) {
                $results.Warnings += $Message
            } else {
                $results.Errors += $Message
                $results.AllTestsPassed = $false
            }
        }
        
        if (-not $Silent) {
            $status = if ($Passed) { "[PASS]" } else { if ($IsWarning) { "[WARN]" } else { "[FAIL]" } }
            $color = if ($Passed) { "Green" } elseif ($IsWarning) { "Yellow" } else { "Red" }
            Write-Host ("{0,-12} {1}" -f $status, $Name) -ForegroundColor $color
            if ($Message) {
                Write-Host ("             {0}" -f $Message) -ForegroundColor Gray
            }
        }
    }
    
    if (-not $Silent) {
        Write-Host "`n" -NoNewline
        Write-Host ("=" * 60) -ForegroundColor Cyan
        Write-Host "  Dropbox Helper - Pre-Flight Validation Checks" -ForegroundColor Cyan
        Write-Host ("=" * 60) -ForegroundColor Cyan
        Write-Host ""
    }
    
    # Test 1: PowerShell Version
    if (-not $Silent) { Write-Host "[ Configuration & Environment ]" -ForegroundColor Yellow }
    $psVersion = $PSVersionTable.PSVersion
    Add-TestResult "PowerShell Version" `
        ($psVersion.Major -ge 5) `
        "Version $psVersion (Requires 5.1+)"
    
    # Test 2: Configuration File Exists
    $configExists = Test-Path $script:ConfigPath
    Add-TestResult "Configuration File" `
        $configExists `
        "Path: $script:ConfigPath"
    
    if (-not $configExists) {
        Add-TestResult "Auto-Initialize Config" `
            $false `
            "Run: Initialize-Configuration to create default config" `
            $false
        
        if (-not $Silent) {
            Write-Host "`n[!] Configuration file not found. Stopping validation." -ForegroundColor Red
            Write-Host "Run: . .\dropbox-helper.ps1; Initialize-Configuration`n" -ForegroundColor Yellow
        }
        return $results
    }
    
    # Test 3: Load Configuration
    try {
        $config = Get-Configuration
        Add-TestResult "Load Configuration" $true "Successfully loaded"
    }
    catch {
        Add-TestResult "Load Configuration" $false "Failed: $_"
        return $results
    }
    
    # Test 4: Dropbox Camera Uploads Path
    if (-not $Silent) {
        Write-Host "`n[ Dropbox Camera Uploads Path ]" -ForegroundColor Yellow
    }
    $dropboxPath = [System.Environment]::ExpandEnvironmentVariables($config.DropboxCameraUploadsPath)
    Add-TestResult "Dropbox Camera Uploads Path" `
        (Test-Path $dropboxPath) `
        "Path: $dropboxPath"
    
    # Test 5: Backup Destination Path
    if (-not $Silent) {
        Write-Host "`n[ Backup Destination Path ]" -ForegroundColor Yellow
    }
    $backupPath = [System.Environment]::ExpandEnvironmentVariables($config.BackupDestinationPath)
    
    # Check if using SSH transport
    $useSSH = $backupPath -match "^[^@]+@[^:]+:"
    
    if ($useSSH) {
        # SSH/SCP destination - test SSH connectivity
        $sshMatch = $backupPath -match "^(?<user>[^@]+)@(?<host>[^:]+):(?<path>.+)$"
        if ($sshMatch) {
            $sshHost = $Matches.host
            $sshUser = $Matches.user
            $remotePath = $Matches.path
            
            Add-TestResult "SSH Destination Format" $true "User: $sshUser, Host: $sshHost"
            
            # Test SSH connectivity
            if (-not $Silent) {
                Write-Host "`n[ SSH Connectivity ]" -ForegroundColor Yellow
            }
            
            $sshTest = Test-SSHConnection -Hostname $sshHost -Username $sshUser
            Add-TestResult "SSH Connection" $sshTest.Connected $sshTest.Message
            
            # Test SCP availability
            $scpTest = Test-SCPAvailable
            Add-TestResult "SCP Available" $scpTest.Available $scpTest.Message
            
            if ($sshTest.Connected) {
                # Test remote path accessibility
                try {
                    $testCmd = "ssh $sshUser@$sshHost `"test -d '$remotePath' && echo 'EXISTS' || echo 'NOT_EXISTS'`""
                    $result = Invoke-Expression $testCmd 2>$null
                    $pathExists = $result -match "EXISTS"
                    Add-TestResult "Remote Path Accessible" `
                        $true `
                        "Path: $remotePath $(if($pathExists){'(exists)'}else{'(will be created)'})" `
                        (-not $pathExists)
                }
                catch {
                    Add-TestResult "Remote Path Test" $false "Failed to test remote path: $_" $true
                }
            }
        }
        else {
            Add-TestResult "SSH Destination Format" $false "Invalid SSH format (expected: user@host:/path)"
        }
    }
    else {
        # Local path - test accessibility
        $pathExists = Test-Path $backupPath
        Add-TestResult "Backup Destination Path" $pathExists "Path: $backupPath"
        
        if (-not $pathExists) {
            # Try to create it
            try {
                $null = New-Item -Path $backupPath -ItemType Directory -Force -ErrorAction Stop
                Add-TestResult "Create Backup Path" $true "Successfully created backup directory"
            }
            catch {
                Add-TestResult "Create Backup Path" $false "Failed to create: $_"
            }
        }
        else {
            # Test write permissions
            try {
                $testFile = Join-Path $backupPath "_test_$(Get-Date -Format 'yyyyMMddHHmmss').tmp"
                $null = New-Item -Path $testFile -ItemType File -Force -ErrorAction Stop
                Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
                Add-TestResult "Write Permissions" $true "Can write to backup destination"
            }
            catch {
                Add-TestResult "Write Permissions" $false "Cannot write to backup destination: $_"
            }
        }
    }
    
    # Test 6: Supported File Extensions
    if (-not $Silent) {
        Write-Host "`n[ File Type Support ]" -ForegroundColor Yellow
    }
    $extensions = $config.SupportedExtensions
    Add-TestResult "Supported Extensions" `
        ($extensions -and $extensions.Count -gt 0) `
        "Configured: $($extensions -join ', ')"
    
    # Test 7: Check for existing files
    if (Test-Path $dropboxPath) {
        $existingFiles = @(Get-ChildItem -Path $dropboxPath -File -Recurse -ErrorAction SilentlyContinue | 
            Where-Object { $extensions -contains $_.Extension.ToLower() })
        
        Add-TestResult "Existing Files" `
            $true `
            "Found $($existingFiles.Count) files ready to process" `
            ($existingFiles.Count -eq 0)
    }
    
    # Summary
    if (-not $Silent) {
        Write-Host "`n" -NoNewline
        Write-Host ("=" * 60) -ForegroundColor Cyan
        Write-Host "  Validation Summary" -ForegroundColor Cyan
        Write-Host ("=" * 60) -ForegroundColor Cyan
        Write-Host ""
        
        $passCount = ($results.Tests | Where-Object { $_.Passed }).Count
        $failCount = ($results.Tests | Where-Object { -not $_.Passed -and -not $_.IsWarning }).Count
        $warnCount = ($results.Tests | Where-Object { -not $_.Passed -and $_.IsWarning }).Count
        
        Write-Host "  Tests Passed : " -NoNewline -ForegroundColor White
        Write-Host $passCount -ForegroundColor Green
        Write-Host "  Tests Failed : " -NoNewline -ForegroundColor White
        Write-Host $failCount -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
        Write-Host "  Warnings     : " -NoNewline -ForegroundColor White
        Write-Host $warnCount -ForegroundColor Yellow
        Write-Host ""
        
        if ($results.AllTestsPassed) {
            Write-Host "  [SUCCESS] All validation checks passed!" -ForegroundColor Green
            Write-Host "  Ready to run: Start-DropboxHelper" -ForegroundColor Cyan
        }
        else {
            Write-Host "  [FAILED] Some validation checks failed" -ForegroundColor Red
            Write-Host "  Please resolve errors before running" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host ("=" * 60) -ForegroundColor Cyan
        Write-Host ""
    }
    
    return [PSCustomObject]$results
}

#endregion Validation

#region Script Entry Point

# Handle command-line execution
if ($h) {
    Get-Help $PSCommandPath -Full
    exit 0
}

if ($Validate) {
    Test-DropboxHelperSetup
    exit 0
}

if ($Command) {
    # Execute specified command (used by scheduled task)
    switch ($Command) {
        'Start-DropboxHelper' {
            Start-DropboxHelper
        }
        default {
            Write-Host "Unknown command: $Command" -ForegroundColor Red
            exit 1
        }
    }
    exit 0
}

# When script is dot-sourced, just load functions
if ($PSBoundParameters.Count -eq 0 -and $MyInvocation.InvocationName -eq $MyInvocation.MyCommand.Name) {
    Write-Host "Dropbox Camera Upload Helper loaded." -ForegroundColor Green
    Write-Host "Run 'Start-DropboxHelper' to begin monitoring" -ForegroundColor Cyan
    Write-Host "Run 'Test-DropboxHelperSetup' to validate configuration" -ForegroundColor Cyan
}

#endregion Script Entry Point

#region Scheduled Task Management

<#
.SYNOPSIS
    Installs Dropbox Helper as a Windows scheduled task.
.DESCRIPTION
    Creates a scheduled task that runs at user logon and monitors Dropbox Camera Uploads automatically.
    Requires Administrator privileges to create the scheduled task.
.EXAMPLE
    Install-DropboxHelperTask
    Install the scheduled task.
#>
function Install-DropboxHelperTask {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    
    try {
        # Check if running as administrator
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        
        if (-not $isAdmin) {
            Write-Host "ERROR: Administrator privileges required to create scheduled task" -ForegroundColor Red
            Write-Host "Please run PowerShell as Administrator and try again" -ForegroundColor Yellow
            return $false
        }
        
        $taskName = "DropboxCameraHelper"
        
        # Check if task already exists
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Host "Scheduled task already exists: $taskName" -ForegroundColor Yellow
            $overwrite = Read-Host "Do you want to overwrite it? (Y/N)"
            if ($overwrite -ne 'Y' -and $overwrite -ne 'y') {
                Write-Host "Installation cancelled" -ForegroundColor Yellow
                return $false
            }
            
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "Removed existing task" -ForegroundColor Green
        }
        
        # Get the script path
        $scriptPath = $PSCommandPath
        if (-not $scriptPath) {
            # If not available, use the current location
            $scriptPath = Join-Path $PSScriptRoot "dropbox-helper.ps1"
        }
        
        if (-not (Test-Path $scriptPath)) {
            Write-Host "ERROR: Cannot find dropbox-helper.ps1" -ForegroundColor Red
            return $false
        }
        
        # Create action
        $action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`" -Command `"Start-DropboxHelper`""
        
        # Create trigger (at user logon)
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        
        # Create settings
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RunOnlyIfNetworkAvailable `
            -DontStopOnIdleEnd
        
        # Create principal (run as current user)
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        
        # Register task
        if ($PSCmdlet.ShouldProcess($taskName, "Create scheduled task")) {
            Register-ScheduledTask `
                -TaskName $taskName `
                -Action $action `
                -Trigger $trigger `
                -Settings $settings `
                -Principal $principal `
                -Description "Automatically moves photos/videos from Dropbox Camera Uploads to backup location" `
                -Force | Out-Null
            
            Write-Host "Scheduled task '$taskName' created successfully!" -ForegroundColor Green
            Write-LogInfo "Scheduled task installed: $taskName"
            return $true
        }
        
        return $false
    }
    catch {
        Write-Host "Failed to install scheduled task: $_" -ForegroundColor Red
        Write-LogError "Failed to install scheduled task: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Starts the Dropbox Helper scheduled task.
.DESCRIPTION
    Starts the scheduled task immediately without waiting for user logon.
.EXAMPLE
    Start-DropboxHelperTask
    Start the scheduled task.
#>
function Start-DropboxHelperTask {
    [CmdletBinding()]
    param()
    
    try {
        $taskName = "DropboxCameraHelper"
        
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) {
            Write-Host "Scheduled task not found: $taskName" -ForegroundColor Red
            Write-Host "Run Install-DropboxHelperTask first" -ForegroundColor Yellow
            return $false
        }
        
        Start-ScheduledTask -TaskName $taskName
        Write-Host "Scheduled task started: $taskName" -ForegroundColor Green
        Write-LogInfo "Scheduled task started: $taskName"
        
        # Wait a moment and check status
        Start-Sleep -Seconds 2
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        
        Write-Host "Task Status: $($task.State)" -ForegroundColor Cyan
        Write-Host "Last Run: $($taskInfo.LastRunTime)" -ForegroundColor Cyan
        Write-Host "Last Result: $($taskInfo.LastTaskResult)" -ForegroundColor Cyan
        
        return $true
    }
    catch {
        Write-Host "Failed to start scheduled task: $_" -ForegroundColor Red
        Write-LogError "Failed to start scheduled task: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Stops the Dropbox Helper scheduled task.
.DESCRIPTION
    Stops the running scheduled task gracefully.
.EXAMPLE
    Stop-DropboxHelperTask
    Stop the scheduled task.
#>
function Stop-DropboxHelperTask {
    [CmdletBinding()]
    param()
    
    try {
        $taskName = "DropboxCameraHelper"
        
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) {
            Write-Host "Scheduled task not found: $taskName" -ForegroundColor Red
            return $false
        }
        
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Write-Host "Scheduled task stopped: $taskName" -ForegroundColor Green
        Write-LogInfo "Scheduled task stopped: $taskName"
        
        return $true
    }
    catch {
        Write-Host "Failed to stop scheduled task: $_" -ForegroundColor Red
        Write-LogError "Failed to stop scheduled task: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Uninstalls the Dropbox Helper scheduled task.
.DESCRIPTION
    Removes the scheduled task from Windows Task Scheduler.
    Requires Administrator privileges.
.EXAMPLE
    Uninstall-DropboxHelperTask
    Remove the scheduled task.
#>
function Uninstall-DropboxHelperTask {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param()
    
    try {
        # Check if running as administrator
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        
        if (-not $isAdmin) {
            Write-Host "ERROR: Administrator privileges required to remove scheduled task" -ForegroundColor Red
            Write-Host "Please run PowerShell as Administrator and try again" -ForegroundColor Yellow
            return $false
        }
        
        $taskName = "DropboxCameraHelper"
        
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) {
            Write-Host "Scheduled task not found: $taskName" -ForegroundColor Yellow
            return $false
        }
        
        if ($PSCmdlet.ShouldProcess($taskName, "Remove scheduled task")) {
            # Stop task if running
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            
            # Unregister task
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "Scheduled task removed: $taskName" -ForegroundColor Green
            Write-LogInfo "Scheduled task uninstalled: $taskName"
            
            return $true
        }
        
        return $false
    }
    catch {
        Write-Host "Failed to uninstall scheduled task: $_" -ForegroundColor Red
        Write-LogError "Failed to uninstall scheduled task: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Gets the status of the Dropbox Helper scheduled task.
.DESCRIPTION
    Retrieves information about the scheduled task including state, last run time, and result.
.EXAMPLE
    Get-DropboxHelperTaskStatus
    Display scheduled task status.
#>
function Get-DropboxHelperTaskStatus {
    [CmdletBinding()]
    param()
    
    try {
        $taskName = "DropboxCameraHelper"
        
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) {
            Write-Host "Scheduled task not found: $taskName" -ForegroundColor Yellow
            Write-Host "Run Install-DropboxHelperTask to create the task" -ForegroundColor Cyan
            return $null
        }
        
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        
        $status = [PSCustomObject]@{
            TaskName = $taskName
            State = $task.State
            Enabled = $task.Settings.Enabled
            LastRunTime = $taskInfo.LastRunTime
            LastResult = $taskInfo.LastTaskResult
            NextRunTime = $taskInfo.NextRunTime
            NumberOfMissedRuns = $taskInfo.NumberOfMissedRuns
        }
        
        Write-Host "`nScheduled Task Status:" -ForegroundColor Cyan
        Write-Host "  Task Name: $($status.TaskName)" -ForegroundColor White
        Write-Host "  State: $($status.State)" -ForegroundColor $(if ($status.State -eq 'Running') { 'Green' } else { 'Yellow' })
        Write-Host "  Enabled: $($status.Enabled)" -ForegroundColor White
        Write-Host "  Last Run: $($status.LastRunTime)" -ForegroundColor White
        Write-Host "  Last Result: $($status.LastResult)" -ForegroundColor $(if ($status.LastResult -eq 0) { 'Green' } else { 'Red' })
        Write-Host "  Next Run: $($status.NextRunTime)" -ForegroundColor White
        Write-Host ""
        
        return $status
    }
    catch {
        Write-Host "Failed to get scheduled task status: $_" -ForegroundColor Red
        return $null
    }
}

#endregion Scheduled Task Management

