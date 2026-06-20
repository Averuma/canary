[CmdletBinding()]
param(
    [ValidateSet(
        "Menu",
        "Status",
        "Backup",
        "UpdateSource",
        "UpdateServer",
        "UpdateClient",
        "UpdateAll",
        "RollbackClient",
        "ServerStatus",
        "StartServer",
        "RestartServer",
        "StopServer",
        "ServerLogs",
        "StartClient",
        "ClientLogs"
    )]
    [string]$Action = "Menu",
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot "update-center.json"
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$canaryRoot = $config.canaryRoot
$composeFile = Join-Path $canaryRoot $config.composeFile
$backupRoot = Join-Path $canaryRoot $config.backupRoot
$stateRoot = $config.statePath
$stateFile = Join-Path $stateRoot "state.json"
$cacheRoot = Join-Path $stateRoot "cache"
$githubHeaders = @{ "User-Agent" = "Canary-Update-Center" }

New-Item -ItemType Directory -Force -Path $backupRoot, $stateRoot, $cacheRoot | Out-Null

function Write-Step([string]$Message) {
    Write-Host "`n== $Message ==" -ForegroundColor Cyan
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Confirm-Update([string]$Message) {
    if ($Yes) {
        return
    }
    $answer = Read-Host "$Message [y/N]"
    if ($answer -notin @("y", "Y", "yes", "YES", "sim", "SIM", "s", "S")) {
        throw "Operation cancelled."
    }
}

function Get-State {
    if (Test-Path -LiteralPath $stateFile) {
        return Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    }

    return [pscustomobject]@{
        clientVersion = $config.assumedClientVersion
        lastClientBackup = $null
        lastCheck = $null
    }
}

function Save-State($State) {
    $State.lastCheck = (Get-Date).ToString("o")
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile -Encoding UTF8
}

function Get-LatestClientRelease {
    $uri = "https://api.github.com/repos/$($config.clientRepository)/releases/latest"
    return Invoke-RestMethod -Headers $githubHeaders -Uri $uri
}

function Get-ReleaseAsset($Release) {
    $asset = $Release.assets | Where-Object { $_.name -eq $config.clientReleaseAsset } | Select-Object -First 1
    if (-not $asset) {
        throw "Asset '$($config.clientReleaseAsset)' not found in release $($Release.tag_name)."
    }
    return $asset
}

function Get-ReleaseByTag([string]$Tag) {
    $uri = "https://api.github.com/repos/$($config.clientRepository)/releases/tags/$Tag"
    return Invoke-RestMethod -Headers $githubHeaders -Uri $uri
}

function Get-RemoteImageDigest([string]$Image) {
    $output = & docker buildx imagetools inspect $Image --format "{{json .Manifest.Digest}}"
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return ($output -replace '"', '').Trim()
}

function Get-LocalImageDigest([string]$Image) {
    $output = & docker image inspect $Image --format "{{json .RepoDigests}}" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return $null
    }
    $digests = $output | ConvertFrom-Json
    if (-not $digests -or $digests.Count -eq 0) {
        return $null
    }
    return ($digests[0] -split "@", 2)[1]
}

function Get-CanaryStatus {
    Write-Step "Canary source"
    Invoke-Native git @("-c", "safe.directory=$canaryRoot", "-C", $canaryRoot, "fetch", "--prune", "upstream")
    $branch = (& git -c "safe.directory=$canaryRoot" -C $canaryRoot status --short --branch) -join "`n"
    $distance = (& git -c "safe.directory=$canaryRoot" -C $canaryRoot rev-list --left-right --count "HEAD...upstream/main").Trim() -split "\s+"
    Write-Host $branch
    Write-Host "Local-only commits: $($distance[0]); upstream commits available: $($distance[1])"

    Write-Step "Docker images"
    $images = @(
        "ghcr.io/opentibiabr/canary:latest",
        "mariadb:11.4",
        "opentibiabr/login-server:latest"
    )
    foreach ($image in $images) {
        $local = Get-LocalImageDigest $image
        $remote = Get-RemoteImageDigest $image
        $status = if ($local -and $remote -and $local -eq $remote) { "current" } else { "update available" }
        $localDisplay = if ($local) { $local } else { "not installed" }
        $remoteDisplay = if ($remote) { $remote } else { "unavailable" }
        Write-Host ("{0}: {1}" -f $image, $status)
        Write-Host ("  local:  {0}" -f $localDisplay)
        Write-Host ("  remote: {0}" -f $remoteDisplay)
    }
}

function Get-ClientStatus($State) {
    Write-Step "OTClient"
    $release = Get-LatestClientRelease
    $current = [string]$State.clientVersion
    $status = if ($current -eq [string]$release.tag_name) { "current release" } else { "update available" }
    Write-Host "Installed/baseline version: $current"
    Write-Host "Latest official release: $($release.tag_name) ($status)"
    Write-Host "Release: $($release.html_url)"

    $process = Get-Process -Name "otclient" -ErrorAction SilentlyContinue
    Write-Host "Client process: $(if ($process) { 'running' } else { 'stopped' })"
    Write-Host "User data: $($config.clientUserDataPath)"
}

function Backup-Database([string]$Destination) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $sqlFile = Join-Path $Destination "canary.sql"
    Write-Step "Backing up MariaDB"
    $sql = & docker exec otbr-db-1 mariadb-dump -ucanary -pcanary --single-transaction --routines --events canary
    if ($LASTEXITCODE -ne 0) {
        throw "Database backup failed."
    }
    [IO.File]::WriteAllLines($sqlFile, [string[]]$sql)
    Write-Host "Database backup: $sqlFile"
}

function Backup-UserData([string]$Destination) {
    if (-not (Test-Path -LiteralPath $config.clientUserDataPath)) {
        return
    }
    Write-Step "Backing up OTClient user data"
    $zip = Join-Path $Destination "otclient-user-data.zip"
    Compress-Archive -LiteralPath $config.clientUserDataPath -DestinationPath $zip -Force
    Write-Host "Client user data backup: $zip"
}

function New-GeneralBackup {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $destination = Join-Path $backupRoot $stamp
    Backup-Database $destination
    Backup-UserData $destination
    return $destination
}

function Apply-ServerOverrides {
    Write-Step "Applying persistent server overrides"
    foreach ($property in $config.serverLuaOverrides.PSObject.Properties) {
        $name = $property.Name
        $value = [string]$property.Value
        Invoke-Native docker @(
            "exec", "otbr-server-1", "sh", "-lc",
            "if grep -q '^$name[[:space:]]*=' /canary/config.lua; then sed -i 's/^$name[[:space:]]*=.*/$name = $value/' /canary/config.lua; else printf '\n$name = $value\n' >> /canary/config.lua; fi"
        )
    }

    foreach ($relativePath in $config.serverOverlayFiles) {
        $source = Join-Path $canaryRoot $relativePath
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Server overlay not found: $source"
        }
        $containerPath = "/canary/" + ($relativePath -replace "\\", "/")
        Invoke-Native docker @("cp", $source, "otbr-server-1:$containerPath")
        Write-Host "Deployed overlay: $relativePath"
    }
}

function Update-Server {
    Confirm-Update "Pull and recreate updated backend containers?"
    $backup = New-GeneralBackup
    Write-Step "Updating backend containers"
    Push-Location $canaryRoot
    try {
        $services = [string[]]$config.dockerServices
        Invoke-Native docker (@("compose", "-f", $composeFile, "pull") + $services)
        Invoke-Native docker (@("compose", "-f", $composeFile, "up", "-d", "--no-deps", "--force-recreate") + $services)
    } finally {
        Pop-Location
    }

    Start-Sleep -Seconds 5
    Apply-ServerOverrides
    Invoke-Native docker @("restart", "otbr-server-1")
    Start-Sleep -Seconds 5
    Invoke-Native docker @("exec", "otbr-server-1", "sh", "-lc", "grep -n '^autoBank' /canary/config.lua")
    Write-Host "Backend updated. Backup: $backup" -ForegroundColor Green
}

function Update-Source {
    Write-Step "Updating Canary source"
    Invoke-Native git @("-c", "safe.directory=$canaryRoot", "-C", $canaryRoot, "fetch", "--prune", "upstream")
    $dirty = @(& git -c "safe.directory=$canaryRoot" -C $canaryRoot status --porcelain)
    if ($dirty.Count -gt 0) {
        Write-Host "Source update was not applied because the worktree has local changes:" -ForegroundColor Yellow
        $dirty | ForEach-Object { Write-Host "  $_" }
        throw "Preserve the local changes on a working branch before updating the Canary source."
    }

    $branch = (& git -c "safe.directory=$canaryRoot" -C $canaryRoot branch --show-current).Trim()
    if ($branch -ne "main" -and $branch -notlike "dudantas/*") {
        throw "Source synchronization is allowed only on main or dudantas/* branches. Current branch: $branch"
    }

    $distance = (& git -c "safe.directory=$canaryRoot" -C $canaryRoot rev-list --left-right --count "HEAD...upstream/main").Trim() -split "\s+"
    if ($branch -eq "main" -and [int]$distance[0] -gt 0) {
        throw "Local main contains commits not present on upstream/main; refusing to rewrite history."
    }
    if ([int]$distance[1] -eq 0) {
        Write-Host "Canary source is already current."
        return
    }

    if ($branch -eq "main") {
        Confirm-Update "Fast-forward Canary source by $($distance[1]) commit(s)?"
        Invoke-Native git @("-c", "safe.directory=$canaryRoot", "-C", $canaryRoot, "merge", "--ff-only", "upstream/main")
        Write-Host "Canary source updated by fast-forward." -ForegroundColor Green
        return
    }

    Confirm-Update "Merge $($distance[1]) upstream commit(s) into $branch?"
    Invoke-Native git @("-c", "safe.directory=$canaryRoot", "-C", $canaryRoot, "merge", "--no-edit", "upstream/main")
    Write-Host "Official Canary updates merged into $branch." -ForegroundColor Green
}

function Get-Archive([string]$Version, $Asset) {
    $archive = Join-Path $cacheRoot "otclient-$Version.zip"
    if (-not (Test-Path -LiteralPath $archive) -or (Get-Item $archive).Length -ne [int64]$Asset.size) {
        Write-Step "Downloading OTClient $Version"
        Invoke-WebRequest -Headers $githubHeaders -Uri $Asset.browser_download_url -OutFile $archive
    }
    return $archive
}

function Expand-Release([string]$Version, [string]$Archive) {
    $destination = Join-Path $cacheRoot "otclient-$Version"
    if (-not (Test-Path -LiteralPath $destination)) {
        Expand-Archive -LiteralPath $Archive -DestinationPath $destination
    }

    $children = @(Get-ChildItem -LiteralPath $destination -Force)
    if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
        return $children[0].FullName
    }
    return $destination
}

function Get-RelativeFiles([string]$Root) {
    $result = @{}
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length).TrimStart("\", "/")
        $result[$relative] = $_.FullName
    }
    return $result
}

function Get-Sha([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Update-Client($State) {
    if (Get-Process -Name "otclient" -ErrorAction SilentlyContinue) {
        throw "Close OTClient before updating it."
    }

    $latest = Get-LatestClientRelease
    $oldVersion = [string]$State.clientVersion
    $newVersion = [string]$latest.tag_name
    if ($oldVersion -eq $newVersion) {
        Write-Host "OTClient is already on official release $newVersion."
        return
    }

    Confirm-Update "Update OTClient from $oldVersion to $newVersion?"
    $oldRelease = Get-ReleaseByTag $oldVersion
    $oldAsset = Get-ReleaseAsset $oldRelease
    $newAsset = Get-ReleaseAsset $latest
    $oldRoot = Expand-Release $oldVersion (Get-Archive $oldVersion $oldAsset)
    $newRoot = Expand-Release $newVersion (Get-Archive $newVersion $newAsset)
    $oldFiles = Get-RelativeFiles $oldRoot
    $newFiles = Get-RelativeFiles $newRoot

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = Join-Path $backupRoot "client-$stamp"
    $filesBackup = Join-Path $backup "files"
    New-Item -ItemType Directory -Force -Path $filesBackup | Out-Null
    $created = [System.Collections.Generic.List[string]]::new()
    $changed = [System.Collections.Generic.List[string]]::new()
    $conflicts = [System.Collections.Generic.List[string]]::new()

    Write-Step "Applying OTClient update"
    foreach ($relative in $newFiles.Keys) {
        $currentPath = Join-Path $config.clientPath $relative
        $newPath = $newFiles[$relative]
        $oldPath = $oldFiles[$relative]

        if (-not (Test-Path -LiteralPath $currentPath)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $currentPath) | Out-Null
            Copy-Item -LiteralPath $newPath -Destination $currentPath
            $created.Add($relative)
            continue
        }

        if (-not $oldPath) {
            if ((Get-Sha $currentPath) -ne (Get-Sha $newPath)) {
                $conflicts.Add($relative)
            }
            continue
        }

        $currentSha = Get-Sha $currentPath
        $oldSha = Get-Sha $oldPath
        $newSha = Get-Sha $newPath
        if ($currentSha -eq $oldSha -and $currentSha -ne $newSha) {
            $backupPath = Join-Path $filesBackup $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
            Copy-Item -LiteralPath $currentPath -Destination $backupPath
            Copy-Item -LiteralPath $newPath -Destination $currentPath -Force
            $changed.Add($relative)
        } elseif ($currentSha -ne $oldSha -and $newSha -ne $oldSha -and $currentSha -ne $newSha) {
            $conflicts.Add($relative)
        }
    }

    foreach ($relative in $oldFiles.Keys) {
        if ($newFiles.ContainsKey($relative)) {
            continue
        }
        $currentPath = Join-Path $config.clientPath $relative
        if ((Test-Path -LiteralPath $currentPath) -and (Get-Sha $currentPath) -eq (Get-Sha $oldFiles[$relative])) {
            $backupPath = Join-Path $filesBackup $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
            Copy-Item -LiteralPath $currentPath -Destination $backupPath
            Remove-Item -LiteralPath $currentPath
            $changed.Add($relative)
        }
    }

    $manifest = [pscustomobject]@{
        fromVersion = $oldVersion
        toVersion = $newVersion
        created = @($created)
        changed = @($changed)
        conflicts = @($conflicts)
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backup "manifest.json") -Encoding UTF8
    $State.clientVersion = $newVersion
    $State.lastClientBackup = $backup
    Save-State $State

    Write-Host "OTClient updated to baseline $newVersion." -ForegroundColor Green
    Write-Host "Updated/removed files: $($changed.Count); new files: $($created.Count); preserved conflicts: $($conflicts.Count)"
    Write-Host "Rollback snapshot: $backup"
}

function Rollback-Client($State) {
    $backup = [string]$State.lastClientBackup
    if (-not $backup -or -not (Test-Path -LiteralPath $backup)) {
        throw "No client rollback snapshot is available."
    }
    if (Get-Process -Name "otclient" -ErrorAction SilentlyContinue) {
        throw "Close OTClient before rollback."
    }
    Confirm-Update "Rollback the last OTClient update?"
    $manifest = Get-Content -LiteralPath (Join-Path $backup "manifest.json") -Raw | ConvertFrom-Json
    foreach ($relative in $manifest.created) {
        $path = Join-Path $config.clientPath $relative
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path
        }
    }
    Get-ChildItem -LiteralPath (Join-Path $backup "files") -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring((Join-Path $backup "files").Length).TrimStart("\", "/")
        $destination = Join-Path $config.clientPath $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
    }
    $State.clientVersion = $manifest.fromVersion
    $State.lastClientBackup = $null
    Save-State $State
    Write-Host "OTClient rolled back to $($manifest.fromVersion)." -ForegroundColor Green
}

function Show-ServerStatus {
    Write-Step "Docker services"
    Invoke-Native docker @("compose", "-f", $composeFile, "ps")
}

function Start-Server {
    Write-Step "Starting backend stack"
    Invoke-Native docker @("compose", "-f", $composeFile, "up", "-d")
    Show-ServerStatus
}

function Restart-Server {
    Write-Step "Restarting Canary server"
    Invoke-Native docker @("restart", "otbr-server-1")
    Show-ServerStatus
}

function Stop-Server {
    Confirm-Update "Stop the backend stack?"
    Write-Step "Stopping backend stack"
    Invoke-Native docker @("compose", "-f", $composeFile, "stop")
}

function Show-ServerLogs {
    Write-Host "Press Ctrl+C to leave the live server log." -ForegroundColor Yellow
    Invoke-Native docker @("logs", "--follow", "--tail", "150", "otbr-server-1")
}

function Start-Client {
    $clientExecutable = Join-Path $config.clientPath "otclient.exe"
    if (-not (Test-Path -LiteralPath $clientExecutable)) {
        throw "OTClient executable not found: $clientExecutable"
    }
    if (Get-Process -Name "otclient" -ErrorAction SilentlyContinue) {
        Write-Host "OTClient is already running."
        return
    }
    Start-Process -FilePath $clientExecutable -WorkingDirectory $config.clientPath
    Write-Host "OTClient started." -ForegroundColor Green
}

function Show-ClientLogs {
    $logPath = Join-Path $config.clientPath "otclient.log"
    if (-not (Test-Path -LiteralPath $logPath)) {
        throw "OTClient log not found: $logPath"
    }
    Write-Host "Press Ctrl+C to leave the live client log." -ForegroundColor Yellow
    Get-Content -LiteralPath $logPath -Tail 150 -Wait
}

function Invoke-UpdateCenterAction {
    param(
        [Parameter(Mandatory)][string]$SelectedAction,
        [Parameter(Mandatory)]$State
    )

    switch ($SelectedAction) {
        "Status" {
            Get-CanaryStatus
            Get-ClientStatus $State
            Save-State $State
        }
        "Backup" {
            $destination = New-GeneralBackup
            Write-Host "Backup completed: $destination" -ForegroundColor Green
        }
        "UpdateSource" {
            Update-Source
        }
        "UpdateServer" {
            Update-Server
        }
        "UpdateClient" {
            Update-Client $State
        }
        "UpdateAll" {
            Update-Server
            Update-Client $State
        }
        "RollbackClient" {
            Rollback-Client $State
        }
        "ServerStatus" {
            Show-ServerStatus
        }
        "StartServer" {
            Start-Server
        }
        "RestartServer" {
            Restart-Server
        }
        "StopServer" {
            Stop-Server
        }
        "ServerLogs" {
            Show-ServerLogs
        }
        "StartClient" {
            Start-Client
        }
        "ClientLogs" {
            Show-ClientLogs
        }
    }
}

function Show-InteractiveMenu {
    param([Parameter(Mandatory)]$State)

    $menu = [ordered]@{
        "1" = @{ Action = "Status"; Label = "Check all updates and versions" }
        "2" = @{ Action = "Backup"; Label = "Create database and OTClient backup" }
        "3" = @{ Action = "UpdateSource"; Label = "Sync current Canary branch with official upstream" }
        "4" = @{ Action = "UpdateServer"; Label = "Update backend Docker images" }
        "5" = @{ Action = "UpdateClient"; Label = "Update OTClient official release" }
        "6" = @{ Action = "UpdateAll"; Label = "Update backend and OTClient" }
        "7" = @{ Action = "RollbackClient"; Label = "Rollback last OTClient update" }
        "8" = @{ Action = "ServerStatus"; Label = "Show backend services" }
        "9" = @{ Action = "StartServer"; Label = "Start backend stack" }
        "10" = @{ Action = "RestartServer"; Label = "Restart Canary server" }
        "11" = @{ Action = "StopServer"; Label = "Stop backend stack" }
        "12" = @{ Action = "ServerLogs"; Label = "Follow Canary server logs" }
        "13" = @{ Action = "StartClient"; Label = "Start OTClient" }
        "14" = @{ Action = "ClientLogs"; Label = "Follow OTClient logs" }
    }

    while ($true) {
        Clear-Host
        Write-Host "Canary + OTClient Update Center" -ForegroundColor Cyan
        Write-Host "================================" -ForegroundColor DarkCyan
        Write-Host "Fork: Averuma | origin = personal | upstream = official"
        Write-Host ""
        foreach ($key in $menu.Keys) {
            Write-Host ("[{0,2}] {1}" -f $key, $menu[$key].Label)
        }
        Write-Host "[ 0] Exit"
        Write-Host ""

        $choice = Read-Host "Choose an option"
        if ($choice -eq "0") {
            return
        }
        if (-not $menu.Contains($choice)) {
            Write-Host "Invalid option." -ForegroundColor Yellow
            Read-Host "Press Enter to continue" | Out-Null
            continue
        }

        try {
            Invoke-UpdateCenterAction -SelectedAction $menu[$choice].Action -State $State
        } catch {
            Write-Host "`nOperation failed: $($_.Exception.Message)" -ForegroundColor Red
        }

        Write-Host ""
        Read-Host "Press Enter to return to the menu" | Out-Null
    }
}

$state = Get-State
if ($Action -eq "Menu") {
    Show-InteractiveMenu $state
} else {
    Invoke-UpdateCenterAction -SelectedAction $Action -State $state
}
