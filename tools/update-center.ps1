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
        "ClientLogs",
        "GitStatus",
        "PublishBranches",
        "SyncCanaryGit",
        "SyncClientGit",
        "SyncAndPublishGit",
        "FullWorkflow",
        "SmartUpdate"
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
$script:WorkflowConfirmed = $false

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
    if ($Yes -or $script:WorkflowConfirmed) {
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

function Invoke-GitHubJson {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$CacheName
    )

    $cacheFile = Join-Path $cacheRoot $CacheName
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $result = Invoke-RestMethod -Headers $githubHeaders -Uri $Uri -TimeoutSec 20
            $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cacheFile -Encoding UTF8
            return $result
        } catch {
            if ($attempt -lt 3) {
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    }

    $apiPath = $Uri -replace "^https://api\.github\.com/", ""
    $ghOutput = & gh api $apiPath 2>$null
    if ($LASTEXITCODE -eq 0 -and $ghOutput) {
        $result = ($ghOutput -join "`n") | ConvertFrom-Json
        $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $cacheFile -Encoding UTF8
        return $result
    }

    if (Test-Path -LiteralPath $cacheFile) {
        Write-Host "GitHub API unavailable; using cached release metadata." -ForegroundColor Yellow
        return Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json
    }
    throw "GitHub API is unavailable and no cached release metadata exists."
}

function Get-LatestClientRelease {
    $uri = "https://api.github.com/repos/$($config.clientRepository)/releases/latest"
    return Invoke-GitHubJson -Uri $uri -CacheName "otclient-latest-release.json"
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
    return Invoke-GitHubJson -Uri $uri -CacheName "otclient-release-$Tag.json"
}

function Get-RemoteImageId([string]$Image) {
    $cacheName = "docker-" + ($Image -replace "[^a-zA-Z0-9.-]", "_") + ".txt"
    $cacheFile = Join-Path $cacheRoot $cacheName

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & docker buildx imagetools inspect $Image --format "{{json .Manifest.Digest}}" 2>$null
            $exitCode = $LASTEXITCODE
        } catch {
            $output = $null
            $exitCode = 1
        } finally {
            $ErrorActionPreference = $previousPreference
        }

        if ($exitCode -eq 0 -and $output) {
            $digest = ($output -replace '"', '').Trim()
            Set-Content -LiteralPath $cacheFile -Value $digest -Encoding ASCII
            return $digest
        }
        if ($attempt -lt 3) {
            Start-Sleep -Seconds (2 * $attempt)
        }
    }

    if (Test-Path -LiteralPath $cacheFile) {
        return (Get-Content -LiteralPath $cacheFile -Raw).Trim()
    }
    return $null
}

function Get-LocalImageId([string]$Image) {
    $output = & docker image inspect $Image --format "{{.Id}}" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return $null
    }
    return $output.Trim()
}

function Get-DockerImageStatus {
    $definitions = @(
        @{ Service = "server"; Image = "ghcr.io/opentibiabr/canary:latest" },
        @{ Service = "db"; Image = "mariadb:11.4" },
        @{ Service = "login-server"; Image = "opentibiabr/login-server:latest" }
    )

    $result = @()
    foreach ($definition in $definitions) {
        $local = Get-LocalImageId $definition.Image
        $remote = Get-RemoteImageId $definition.Image
        $result += [pscustomobject]@{
            Service = $definition.Service
            Image = $definition.Image
            Local = $local
            Remote = $remote
            UpdateAvailable = [bool]($local -and $remote -and $local -ne $remote)
            Unknown = [bool](-not $local -or -not $remote)
        }
    }
    return $result
}

function Get-CanaryStatus {
    Write-Step "Canary source"
    Invoke-Native git @("-c", "safe.directory=$canaryRoot", "-C", $canaryRoot, "fetch", "--prune", "upstream")
    $branch = (& git -c "safe.directory=$canaryRoot" -C $canaryRoot status --short --branch) -join "`n"
    $distance = (& git -c "safe.directory=$canaryRoot" -C $canaryRoot rev-list --left-right --count "HEAD...upstream/main").Trim() -split "\s+"
    Write-Host $branch
    Write-Host "Local-only commits: $($distance[0]); upstream commits available: $($distance[1])"

    Write-Step "Docker images"
    foreach ($imageStatus in Get-DockerImageStatus) {
        $status = if ($imageStatus.UpdateAvailable) {
            "update available"
        } elseif ($imageStatus.Unknown) {
            "unable to verify"
        } else {
            "current"
        }
        $localDisplay = if ($imageStatus.Local) { $imageStatus.Local } else { "not installed" }
        $remoteDisplay = if ($imageStatus.Remote) { $imageStatus.Remote } else { "unavailable" }
        Write-Host ("{0}: {1}" -f $imageStatus.Image, $status)
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

function Wait-ContainerHealthy {
    param(
        [Parameter(Mandatory)][string]$Container,
        [int]$TimeoutSeconds = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $status = & docker inspect $Container --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" 2>$null
        if ($LASTEXITCODE -eq 0 -and $status.Trim() -in @("healthy", "running")) {
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "Container $Container did not become healthy within $TimeoutSeconds seconds."
}

function Wait-CanaryOnline {
    param([int]$TimeoutSeconds = 300)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $startedAt = & docker inspect otbr-server-1 --format "{{.State.StartedAt}}" 2>$null
        if ($LASTEXITCODE -eq 0 -and $startedAt) {
            $logs = & docker logs --since $startedAt.Trim() otbr-server-1 2>&1
            if ($logs -match "Canary server online!") {
                return
            }
        }
        Start-Sleep -Seconds 3
    }
    throw "Canary did not report an online state within $TimeoutSeconds seconds."
}

function Update-Server {
    param(
        [switch]$SkipBackup,
        [string[]]$Services
    )

    Confirm-Update "Pull and recreate updated backend containers?"
    $backup = $null
    if (-not $SkipBackup) {
        $backup = New-GeneralBackup
    }
    Write-Step "Updating backend containers"
    Push-Location $canaryRoot
    try {
        $services = if ($Services -and $Services.Count -gt 0) {
            [string[]]$Services
        } else {
            [string[]]$config.dockerServices
        }
        Invoke-Native docker (@("compose", "-f", $composeFile, "pull") + $services)
        Invoke-Native docker (@("compose", "-f", $composeFile, "up", "-d", "--no-deps", "--force-recreate") + $services)
    } finally {
        Pop-Location
    }

    if ($services -contains "db") {
        Write-Step "Waiting for MariaDB"
        Wait-ContainerHealthy "otbr-db-1"
    }

    if ($services -contains "server") {
        Write-Step "Waiting for initial Canary startup"
        Wait-CanaryOnline
        Apply-ServerOverrides
        Invoke-Native docker @("restart", "otbr-server-1")
        Write-Step "Waiting for Canary restart"
        Wait-CanaryOnline
        Invoke-Native docker @("exec", "otbr-server-1", "sh", "-lc", "grep -n '^autoBank' /canary/config.lua")
    } elseif ($services -contains "db") {
        Invoke-Native docker @("restart", "otbr-server-1")
        Write-Step "Waiting for Canary restart"
        Wait-CanaryOnline
    }
    if ($backup) {
        Write-Host "Backend updated. Backup: $backup" -ForegroundColor Green
    } else {
        Write-Host "Backend updated." -ForegroundColor Green
    }
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

function Assert-CleanGitWorktree {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Label
    )

    $changes = @(& git -C $Repository status --porcelain)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Git status for $Label."
    }
    if ($changes.Count -gt 0) {
        Write-Host "$Label has uncommitted changes:" -ForegroundColor Yellow
        $changes | ForEach-Object { Write-Host "  $_" }
        throw "Commit or discard these changes before synchronizing Git."
    }
}

function Get-CurrentGitBranch {
    param([Parameter(Mandatory)][string]$Repository)

    $branch = (& git -C $Repository branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $branch) {
        throw "Unable to determine the current Git branch in $Repository."
    }
    return $branch
}

function Assert-WorkingBranch {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Label
    )

    $branch = Get-CurrentGitBranch $Repository
    if ($branch -notlike "dudantas/*") {
        throw "$Label must be on a dudantas/* working branch. Current branch: $branch"
    }
    return $branch
}

function Show-GitStatus {
    Write-Step "Canary Git"
    Invoke-Native git @("-C", $canaryRoot, "status", "--short", "--branch")
    Invoke-Native git @("-C", $canaryRoot, "branch", "-vv")
    Write-Host ""
    Invoke-Native git @("-C", $canaryRoot, "remote", "-v")

    Write-Step "OTClient Git"
    Invoke-Native git @("-C", $config.clientPath, "status", "--short", "--branch")
    Invoke-Native git @("-C", $config.clientPath, "branch", "-vv")
    Write-Host ""
    Invoke-Native git @("-C", $config.clientPath, "remote", "-v")
}

function Publish-GitBranch {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Label
    )

    Assert-CleanGitWorktree $Repository $Label
    $branch = Assert-WorkingBranch $Repository $Label
    Write-Step "Publishing $Label branch $branch"
    Invoke-Native git @("-C", $Repository, "push", "-u", "origin", "HEAD:$branch")
}

function Publish-WorkingBranches {
    Publish-GitBranch $canaryRoot "Canary"
    Publish-GitBranch $config.clientPath "OTClient"
}

function Sync-CanaryGit {
    Assert-CleanGitWorktree $canaryRoot "Canary"
    $branch = Assert-WorkingBranch $canaryRoot "Canary"

    Write-Step "Fetching official Canary updates"
    Invoke-Native git @("-C", $canaryRoot, "fetch", "--prune", "upstream")
    Invoke-Native git @("-C", $canaryRoot, "fetch", "--prune", "origin")

    Write-Step "Refreshing local Canary main"
    Invoke-Native git @("-C", $canaryRoot, "switch", "main")
    try {
        Invoke-Native git @("-C", $canaryRoot, "merge", "--ff-only", "upstream/main")
    } finally {
        Invoke-Native git @("-C", $canaryRoot, "switch", $branch)
    }

    $behind = (& git -C $canaryRoot rev-list --count "HEAD..upstream/main").Trim()
    if ([int]$behind -eq 0) {
        Write-Host "$branch already contains upstream/main."
        return
    }

    Confirm-Update "Merge $behind official Canary commit(s) into $branch?"
    Invoke-Native git @("-C", $canaryRoot, "merge", "--no-edit", "upstream/main")
    Write-Host "Canary branch synchronized. Review and test it before publishing." -ForegroundColor Green
}

function Sync-ClientGit($State) {
    Assert-CleanGitWorktree $config.clientPath "OTClient"
    $branch = Assert-WorkingBranch $config.clientPath "OTClient"
    $release = Get-LatestClientRelease
    $tag = [string]$release.tag_name

    Write-Step "Fetching official OTClient release $tag"
    Invoke-Native git @("-C", $config.clientPath, "fetch", "--prune", "upstream", "--tags")
    Invoke-Native git @("-C", $config.clientPath, "fetch", "--prune", "origin")

    & git -C $config.clientPath merge-base --is-ancestor "refs/tags/$tag" HEAD
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$branch already contains official release $tag."
        return
    }

    Confirm-Update "Merge official OTClient release $tag into $branch?"
    Invoke-Native git @("-C", $config.clientPath, "merge", "--no-edit", "refs/tags/$tag")
    Write-Host "OTClient branch synchronized with release $tag. Review and test it before publishing." -ForegroundColor Green
}

function Sync-And-PublishGit($State) {
    Assert-CleanGitWorktree $canaryRoot "Canary"
    Assert-CleanGitWorktree $config.clientPath "OTClient"
    Sync-CanaryGit
    Sync-ClientGit $State
    Publish-WorkingBranches
}

function Get-SmartUpdatePlan($State) {
    Invoke-Native git @("-C", $canaryRoot, "fetch", "--prune", "upstream")
    Invoke-Native git @("-C", $canaryRoot, "fetch", "--prune", "origin")
    Invoke-Native git @("-C", $config.clientPath, "fetch", "--prune", "upstream", "--tags")
    Invoke-Native git @("-C", $config.clientPath, "fetch", "--prune", "origin")

    $canaryBehind = [int]((& git -C $canaryRoot rev-list --count "HEAD..upstream/main").Trim())
    $canaryAheadOrigin = [int]((& git -C $canaryRoot rev-list --count "@{upstream}..HEAD").Trim())
    $clientAheadOrigin = [int]((& git -C $config.clientPath rev-list --count "@{upstream}..HEAD").Trim())
    $release = Get-LatestClientRelease
    $clientTag = [string]$release.tag_name
    & git -C $config.clientPath merge-base --is-ancestor "refs/tags/$clientTag" HEAD
    $clientSourceNeedsUpdate = $LASTEXITCODE -ne 0
    $clientRuntimeNeedsUpdate = [string]$State.clientVersion -ne $clientTag
    $dockerStatuses = @(Get-DockerImageStatus)
    $dockerServices = @($dockerStatuses | Where-Object { $_.UpdateAvailable } | ForEach-Object { $_.Service })

    return [pscustomobject]@{
        CanaryBehind = $canaryBehind
        CanaryAheadOrigin = $canaryAheadOrigin
        ClientTag = $clientTag
        ClientSourceNeedsUpdate = $clientSourceNeedsUpdate
        ClientRuntimeNeedsUpdate = $clientRuntimeNeedsUpdate
        ClientAheadOrigin = $clientAheadOrigin
        DockerStatuses = $dockerStatuses
        DockerServices = $dockerServices
        NeedsBackup = [bool]($clientRuntimeNeedsUpdate -or $dockerServices.Count -gt 0)
        HasWork = [bool](
            $canaryBehind -gt 0 -or
            $clientSourceNeedsUpdate -or
            $clientRuntimeNeedsUpdate -or
            $dockerServices.Count -gt 0 -or
            $canaryAheadOrigin -gt 0 -or
            $clientAheadOrigin -gt 0
        )
    }
}

function Show-SmartUpdatePlan($Plan) {
    Write-Step "Smart update plan"
    Write-Host ("Canary official commits: {0}" -f $(if ($Plan.CanaryBehind -gt 0) { $Plan.CanaryBehind } else { "current" }))
    Write-Host ("OTClient source: {0}" -f $(if ($Plan.ClientSourceNeedsUpdate) { "merge release $($Plan.ClientTag)" } else { "current" }))
    Write-Host ("OTClient runtime: {0}" -f $(if ($Plan.ClientRuntimeNeedsUpdate) { "install release $($Plan.ClientTag)" } else { "current" }))
    Write-Host ("Docker services: {0}" -f $(if ($Plan.DockerServices.Count -gt 0) { $Plan.DockerServices -join ", " } else { "current" }))
    Write-Host ("Canary commits to publish: {0}" -f $Plan.CanaryAheadOrigin)
    Write-Host ("OTClient commits to publish: {0}" -f $Plan.ClientAheadOrigin)
    Write-Host ("Backup required: {0}" -f $(if ($Plan.NeedsBackup) { "yes" } else { "no" }))
}

function Invoke-SmartUpdate($State) {
    Write-Step "Preflight"
    Assert-CleanGitWorktree $canaryRoot "Canary"
    Assert-CleanGitWorktree $config.clientPath "OTClient"
    Assert-WorkingBranch $canaryRoot "Canary" | Out-Null
    Assert-WorkingBranch $config.clientPath "OTClient" | Out-Null

    $plan = Get-SmartUpdatePlan $State
    Show-SmartUpdatePlan $plan
    if (-not $plan.HasWork) {
        Write-Host "`nEverything is already current." -ForegroundColor Green
        return
    }

    Confirm-Update "Apply this smart update plan?"
    $script:WorkflowConfirmed = $true
    try {
        if ($plan.NeedsBackup) {
            $backup = New-GeneralBackup
            Write-Host "Backup completed: $backup" -ForegroundColor Green
        }
        if ($plan.CanaryBehind -gt 0) {
            Sync-CanaryGit
        }
        if ($plan.ClientSourceNeedsUpdate) {
            Sync-ClientGit $State
        }
        if ($plan.ClientRuntimeNeedsUpdate) {
            Update-Client $State
        }

        $publishCanary = [int]((& git -C $canaryRoot rev-list --count "@{upstream}..HEAD").Trim()) -gt 0
        $publishClient = [int]((& git -C $config.clientPath rev-list --count "@{upstream}..HEAD").Trim()) -gt 0
        if ($publishCanary) {
            Publish-GitBranch $canaryRoot "Canary"
        }
        if ($publishClient) {
            Publish-GitBranch $config.clientPath "OTClient"
        }
        if ($plan.DockerServices.Count -gt 0) {
            Update-Server -SkipBackup -Services $plan.DockerServices
        }

        Write-Step "Final verification"
        Get-CanaryStatus
        Get-ClientStatus $State
        Show-ServerStatus
        Show-GitStatus
        Save-State $State
        Write-Host "`nSmart update completed successfully." -ForegroundColor Green
    } finally {
        $script:WorkflowConfirmed = $false
    }
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
        "GitStatus" {
            Show-GitStatus
        }
        "PublishBranches" {
            Publish-WorkingBranches
        }
        "SyncCanaryGit" {
            Sync-CanaryGit
        }
        "SyncClientGit" {
            Sync-ClientGit $State
        }
        "SyncAndPublishGit" {
            Sync-And-PublishGit $State
        }
        "FullWorkflow" {
            Invoke-SmartUpdate $State
        }
        "SmartUpdate" {
            Invoke-SmartUpdate $State
        }
    }
}

function Invoke-MenuAction {
    param(
        [Parameter(Mandatory)][string]$SelectedAction,
        [Parameter(Mandatory)]$State
    )

    try {
        Invoke-UpdateCenterAction -SelectedAction $SelectedAction -State $State
    } catch {
        Write-Host "`nOperation failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""
    Read-Host "Press Enter to continue" | Out-Null
}

function Show-ServerMenu {
    param([Parameter(Mandatory)]$State)
    while ($true) {
        Clear-Host
        Write-Host "Server and Client" -ForegroundColor Cyan
        Write-Host "[1] Show backend services"
        Write-Host "[2] Start backend"
        Write-Host "[3] Restart Canary"
        Write-Host "[4] Stop backend"
        Write-Host "[5] Canary live logs"
        Write-Host "[6] Start OTClient"
        Write-Host "[7] OTClient live logs"
        Write-Host "[0] Back"
        $choice = Read-Host "Choose"
        $actions = @{ "1" = "ServerStatus"; "2" = "StartServer"; "3" = "RestartServer"; "4" = "StopServer"; "5" = "ServerLogs"; "6" = "StartClient"; "7" = "ClientLogs" }
        if ($choice -eq "0") { return }
        if ($actions[$choice]) { Invoke-MenuAction $actions[$choice] $State }
    }
}

function Show-GitMenu {
    param([Parameter(Mandatory)]$State)
    while ($true) {
        Clear-Host
        Write-Host "Git and GitHub" -ForegroundColor Cyan
        Write-Host "[1] Show both repositories"
        Write-Host "[2] Publish committed changes"
        Write-Host "[3] Sync Canary with official upstream"
        Write-Host "[4] Sync OTClient with latest release"
        Write-Host "[5] Sync and publish both"
        Write-Host "[0] Back"
        $choice = Read-Host "Choose"
        $actions = @{ "1" = "GitStatus"; "2" = "PublishBranches"; "3" = "SyncCanaryGit"; "4" = "SyncClientGit"; "5" = "SyncAndPublishGit" }
        if ($choice -eq "0") { return }
        if ($actions[$choice]) { Invoke-MenuAction $actions[$choice] $State }
    }
}

function Show-AdvancedMenu {
    param([Parameter(Mandatory)]$State)
    while ($true) {
        Clear-Host
        Write-Host "Advanced Operations" -ForegroundColor Cyan
        Write-Host "[1] Update backend Docker only"
        Write-Host "[2] Update OTClient runtime only"
        Write-Host "[3] Sync Canary source only"
        Write-Host "[4] Rollback last OTClient runtime update"
        Write-Host "[0] Back"
        $choice = Read-Host "Choose"
        $actions = @{ "1" = "UpdateServer"; "2" = "UpdateClient"; "3" = "UpdateSource"; "4" = "RollbackClient" }
        if ($choice -eq "0") { return }
        if ($actions[$choice]) { Invoke-MenuAction $actions[$choice] $State }
    }
}

function Show-InteractiveMenu {
    param([Parameter(Mandatory)]$State)

    while ($true) {
        Clear-Host
        Write-Host "Canary + OTClient Update Center" -ForegroundColor Cyan
        Write-Host "================================" -ForegroundColor DarkCyan
        Write-Host "[1] Smart Update (recommended)" -ForegroundColor Green
        Write-Host "[2] Check status"
        Write-Host "[3] Create backup"
        Write-Host "[4] Server and client"
        Write-Host "[5] Git and GitHub"
        Write-Host "[6] Advanced"
        Write-Host "[0] Exit"
        Write-Host ""

        $choice = Read-Host "Choose"
        switch ($choice) {
            "0" { return }
            "1" { Invoke-MenuAction "SmartUpdate" $State }
            "2" { Invoke-MenuAction "Status" $State }
            "3" { Invoke-MenuAction "Backup" $State }
            "4" { Show-ServerMenu $State }
            "5" { Show-GitMenu $State }
            "6" { Show-AdvancedMenu $State }
        }
    }
}

$state = Get-State
if ($Action -eq "Menu") {
    Show-InteractiveMenu $state
} else {
    try {
        Invoke-UpdateCenterAction -SelectedAction $Action -State $state
    } catch {
        Write-Host "Operation failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
