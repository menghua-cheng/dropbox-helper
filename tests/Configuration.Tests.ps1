<#
.SYNOPSIS
    Unit tests for Dropbox Helper - Configuration and Logging
.DESCRIPTION
    Pester tests for Phase 1: Configuration Management and Logging System
#>

# Import the main script
. "$PSScriptRoot\..\dropbox-helper.ps1"

# Setup test environment
$script:TestConfigPath = Join-Path $env:TEMP "DropboxHelperTests"
$script:TestAppData = Join-Path $script:TestConfigPath "AppData"
$script:OriginalConfigPath = $script:ConfigPath

# Override paths for testing
$script:ConfigPath = Join-Path $script:TestAppData "DropboxHelper\config.json"

Describe "Configuration Management Tests" {
    
    Context "Initialize-Configuration" {
        BeforeEach {
            # Clean up before each test
            if (Test-Path $script:ConfigPath) {
                Remove-Item $script:ConfigPath -Force
            }
        }
        
        It "Should create configuration file if it doesn't exist" {
            Initialize-Configuration | Should -Be $true
            Test-Path $script:ConfigPath | Should -Be $true
        }
        
        It "Should create configuration directory structure" {
            Initialize-Configuration | Should -Be $true
            $configDir = Split-Path -Parent $script:ConfigPath
            Test-Path $configDir | Should -Be $true
        }
        
        It "Should create valid JSON configuration" {
            Initialize-Configuration | Should -Be $true
            { Get-Content $script:ConfigPath -Raw | ConvertFrom-Json } | Should -Not -Throw
        }
        
        It "Should include all required configuration properties" {
            Initialize-Configuration | Should -Be $true
            $config = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            
            $config.DropboxCameraUploadsPath | Should -Not -BeNullOrEmpty
            $config.BackupDestinationPath | Should -Not -BeNullOrEmpty
            $config.FileStabilityWaitSeconds | Should -BeGreaterThan 0
            $config.SupportedExtensions | Should -Not -BeNullOrEmpty
            $config.EnableLogging | Should -Not -BeNullOrEmpty
        }
        
        It "Should not overwrite existing configuration" {
            Initialize-Configuration | Should -Be $true
            $originalTime = (Get-Item $script:ConfigPath).LastWriteTime
            Start-Sleep -Milliseconds 100
            Initialize-Configuration | Should -Be $true
            $newTime = (Get-Item $script:ConfigPath).LastWriteTime
            
            $newTime | Should -Be $originalTime
        }
    }
    
    Context "Get-Configuration" {
        BeforeEach {
            if (Test-Path $script:ConfigPath) {
                Remove-Item $script:ConfigPath -Force
            }
        }
        
        It "Should create config if not exists and return it" {
            $config = Get-Configuration
            $config | Should -Not -BeNullOrEmpty
            Test-Path $script:ConfigPath | Should -Be $true
        }
        
        It "Should return valid configuration object" {
            Initialize-Configuration | Out-Null
            $config = Get-Configuration
            
            $config.PSObject.Properties.Name | Should -Contain 'DropboxCameraUploadsPath'
            $config.PSObject.Properties.Name | Should -Contain 'BackupDestinationPath'
        }
        
        It "Should handle corrupted JSON file" {
            Initialize-Configuration | Out-Null
            "Invalid JSON content" | Set-Content $script:ConfigPath
            
            { Get-Configuration -ErrorAction Stop } | Should -Throw
        }
        
        It "Should validate required properties" {
            Initialize-Configuration | Out-Null
            $config = @{ SomeOtherProperty = "value" }
            $config | ConvertTo-Json | Set-Content $script:ConfigPath
            
            { Get-Configuration -ErrorAction Stop } | Should -Throw
        }
    }
    
    Context "Set-Configuration" {
        BeforeEach {
            if (Test-Path $script:ConfigPath) {
                Remove-Item $script:ConfigPath -Force
            }
            Initialize-Configuration | Out-Null
        }
        
        It "Should update single configuration property" {
            $newValue = 60
            Set-Configuration -Settings @{ FileStabilityWaitSeconds = $newValue } -Confirm:$false | Should -Be $true
            
            $config = Get-Configuration
            $config.FileStabilityWaitSeconds | Should -Be $newValue
        }
        
        It "Should update multiple configuration properties" {
            $settings = @{
                FileStabilityWaitSeconds = 45
                CheckIntervalSeconds = 10
                MaxLogAgeDays = 60
            }
            
            Set-Configuration -Settings $settings -Confirm:$false | Should -Be $true
            
            $config = Get-Configuration
            $config.FileStabilityWaitSeconds | Should -Be 45
            $config.CheckIntervalSeconds | Should -Be 10
            $config.MaxLogAgeDays | Should -Be 60
        }
        
        It "Should warn about unknown properties" {
            $result = Set-Configuration -Settings @{ UnknownProperty = "value" } -Confirm:$false -WarningVariable warnings
            $warnings | Should -Not -BeNullOrEmpty
        }
        
        It "Should persist changes to file" {
            Set-Configuration -Settings @{ FileStabilityWaitSeconds = 100 } -Confirm:$false | Out-Null
            
            # Read directly from file
            $config = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            $config.FileStabilityWaitSeconds | Should -Be 100
        }
    }
    
    Context "Test-ConfigurationPath" {
        BeforeEach {
            if (Test-Path $script:ConfigPath) {
                Remove-Item $script:ConfigPath -Force
            }
            Initialize-Configuration | Out-Null
        }
        
        It "Should validate local backup path" {
            $config = Get-Configuration
            $testPath = Join-Path $script:TestConfigPath "BackupTest"
            $config.BackupDestinationPath = $testPath
            
            Test-ConfigurationPath -Config $config | Should -Be $true
            Test-Path $testPath | Should -Be $true
        }
        
        It "Should handle non-existent Dropbox path gracefully" {
            $config = Get-Configuration
            $config.DropboxCameraUploadsPath = "C:\NonExistentPath\CameraUploads"
            
            # Should still return true with warning
            Test-ConfigurationPath -Config $config -WarningVariable warnings | Should -Be $true
            $warnings | Should -Not -BeNullOrEmpty
        }
        
        It "Should detect UNC paths" {
            $config = Get-Configuration
            $config.BackupDestinationPath = "\\server\share\backup"
            
            # Will warn if not accessible, but shouldn't fail validation
            { Test-ConfigurationPath -Config $config } | Should -Not -Throw
        }
    }
    
    Context "Get-DropboxPath" {
        It "Should return a path string" {
            $path = Get-DropboxPath
            $path | Should -Not -BeNullOrEmpty
            $path | Should -BeOfType [string]
        }
        
        It "Should return a path containing 'Camera Uploads'" {
            $path = Get-DropboxPath
            $path | Should -Match "Camera Uploads"
        }
    }
}

Describe "Logging System Tests" {
    
    Context "Initialize-Logger" {
        BeforeEach {
            if (Test-Path $script:ConfigPath) {
                Remove-Item $script:ConfigPath -Force
            }
            Initialize-Configuration | Out-Null
            
            $config = Get-Configuration
            $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
            if (Test-Path $logPath) {
                Remove-Item $logPath -Recurse -Force
            }
        }
        
        It "Should create log directory" {
            Initialize-Logger | Should -Be $true
            
            $config = Get-Configuration
            $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
            Test-Path $logPath | Should -Be $true
        }
        
        It "Should return true on successful initialization" {
            Initialize-Logger | Should -Be $true
        }
    }
    
    Context "Write-Log" {
        BeforeEach {
            if (Test-Path $script:ConfigPath) {
                Remove-Item $script:ConfigPath -Force
            }
            Initialize-Configuration | Out-Null
            Initialize-Logger | Out-Null
        }
        
        It "Should create log file with current date" {
            Write-LogInfo "Test message"
            
            $config = Get-Configuration
            $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
            $expectedFile = Join-Path $logPath "dropbox-helper_$(Get-Date -Format 'yyyyMMdd').log"
            
            Test-Path $expectedFile | Should -Be $true
        }
        
        It "Should write formatted log entry" {
            $testMessage = "Test log entry $(Get-Random)"
            Write-LogInfo $testMessage
            
            $config = Get-Configuration
            $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
            $logFile = Join-Path $logPath "dropbox-helper_$(Get-Date -Format 'yyyyMMdd').log"
            
            $content = Get-Content $logFile -Raw
            $content | Should -Match "\[INFO\]"
            $content | Should -Match $testMessage
        }
        
        It "Should support INFO level" {
            $testMessage = "INFO test $(Get-Random)"
            Write-LogInfo $testMessage
            
            $config = Get-Configuration
            $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
            $logFile = Join-Path $logPath "dropbox-helper_$(Get-Date -Format 'yyyyMMdd').log"
            
            $content = Get-Content $logFile -Raw
            $content | Should -Match "\[INFO\].*$testMessage"
        }
        
        It "Should support WARNING level" {
            $testMessage = "WARNING test $(Get-Random)"
            Write-LogWarning $testMessage
            
            $config = Get-Configuration
            $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
            $logFile = Join-Path $logPath "dropbox-helper_$(Get-Date -Format 'yyyyMMdd').log"
            
            $content = Get-Content $logFile -Raw
            $content | Should -Match "\[WARNING\].*$testMessage"
        }
        
        It "Should support ERROR level" {
            $testMessage = "ERROR test $(Get-Random)"
            Write-LogError $testMessage
            
            $config = Get-Configuration
            $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
            $logFile = Join-Path $logPath "dropbox-helper_$(Get-Date -Format 'yyyyMMdd').log"
            
            $content = Get-Content $logFile -Raw
            $content | Should -Match "\[ERROR\].*$testMessage"
        }
        
        It "Should not log when logging is disabled" {
            Set-Configuration -Settings @{ EnableLogging = $false } -Confirm:$false | Out-Null
            
            Write-LogInfo "This should not be logged"
            
            $config = Get-Configuration
            $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
            $logFile = Join-Path $logPath "dropbox-helper_$(Get-Date -Format 'yyyyMMdd').log"
            
            if (Test-Path $logFile) {
                $content = Get-Content $logFile -Raw
                $content | Should -Not -Match "This should not be logged"
            }
        }
    }
    
    Context "Get-LogHistory" {
        BeforeEach {
            if (Test-Path $script:ConfigPath) {
                Remove-Item $script:ConfigPath -Force
            }
            Initialize-Configuration | Out-Null
            Initialize-Logger | Out-Null
        }
        
        It "Should retrieve log entries" {
            Write-LogInfo "Test entry 1"
            Write-LogInfo "Test entry 2"
            
            $history = Get-LogHistory -Days 1
            $history | Should -Not -BeNullOrEmpty
            $history.Count | Should -BeGreaterOrEqual 2
        }
        
        It "Should parse log entries correctly" {
            Write-LogInfo "Structured test entry"
            
            $history = Get-LogHistory -Days 1
            $entry = $history | Where-Object { $_.Message -match "Structured test entry" } | Select-Object -First 1
            
            $entry | Should -Not -BeNullOrEmpty
            $entry.Timestamp | Should -BeOfType [datetime]
            $entry.Level | Should -Be 'INFO'
            $entry.Message | Should -Match "Structured test entry"
        }
        
        It "Should filter by log level" {
            Write-LogInfo "Info message"
            Write-LogWarning "Warning message"
            Write-LogError "Error message"
            
            $infoLogs = Get-LogHistory -Days 1 -Level INFO
            $warningLogs = Get-LogHistory -Days 1 -Level WARNING
            $errorLogs = Get-LogHistory -Days 1 -Level ERROR
            
            ($infoLogs | Where-Object { $_.Level -eq 'INFO' }).Count | Should -BeGreaterOrEqual 1
            ($warningLogs | Where-Object { $_.Level -eq 'WARNING' }).Count | Should -BeGreaterOrEqual 1
            ($errorLogs | Where-Object { $_.Level -eq 'ERROR' }).Count | Should -BeGreaterOrEqual 1
        }
        
        It "Should sort entries by timestamp descending" {
            Write-LogInfo "First entry"
            Start-Sleep -Milliseconds 100
            Write-LogInfo "Second entry"
            
            $history = Get-LogHistory -Days 1
            if ($history.Count -ge 2) {
                $history[0].Timestamp | Should -BeGreaterOrEqual $history[1].Timestamp
            }
        }
    }
    
    Context "Clear-OldLogs" {
        BeforeEach {
            if (Test-Path $script:ConfigPath) {
                Remove-Item $script:ConfigPath -Force
            }
            Initialize-Configuration | Out-Null
            Initialize-Logger | Out-Null
        }
        
        It "Should remove logs older than specified days" {
            $config = Get-Configuration
            $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
            
            # Create an old log file
            $oldDate = (Get-Date).AddDays(-35).ToString('yyyyMMdd')
            $oldLogFile = Join-Path $logPath "dropbox-helper_$oldDate.log"
            "Old log content" | Set-Content $oldLogFile
            
            # Set the timestamp to make it appear old
            (Get-Item $oldLogFile).LastWriteTime = (Get-Date).AddDays(-35)
            
            Clear-OldLogs -Days 30 -Confirm:$false
            
            Test-Path $oldLogFile | Should -Be $false
        }
        
        It "Should keep recent logs" {
            $config = Get-Configuration
            $logPath = [System.Environment]::ExpandEnvironmentVariables($config.LogPath)
            
            Write-LogInfo "Recent log entry"
            
            $recentLogFile = Join-Path $logPath "dropbox-helper_$(Get-Date -Format 'yyyyMMdd').log"
            
            Clear-OldLogs -Days 30 -Confirm:$false
            
            Test-Path $recentLogFile | Should -Be $true
        }
    }
}
