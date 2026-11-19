<#
.SYNOPSIS
    Removes the Gradle build output of every module.

.DESCRIPTION
    Walks the repository and deletes every "build" directory, which contains the
    compiled classes and the artifacts produced by Build-HMCL.ps1.

    HMCL/build/libs/.hmcl is preserved, because the launcher stores its settings,
    logs and downloaded dependencies there when it is started straight from the
    build output. Pass -IncludeRuntimeData to remove that folder as well.

    The Publish folder created by Build-HMCL.ps1 is removed, so the next build starts
    from a clean copy.

    The global Gradle cache (<Gradle user home>\caches) is never touched; it may be
    shared by other projects and would have to be downloaded again.

.PARAMETER IncludeRuntimeData
    Also deletes HMCL/build/libs/.hmcl, including the launcher settings and the
    downloaded JavaFX dependencies. Minecraft data stored there is lost.

.PARAMETER IncludeGradleCaches
    Also deletes the project-local ".gradle" folders. The next build recompiles the
    Gradle wrapper bootstrap and rebuilds the project cache from scratch.

.PARAMETER NoPause
    Closes the console immediately instead of waiting for a key press.

.EXAMPLE
    .\Clean-BuildOutput.ps1

.EXAMPLE
    .\Clean-BuildOutput.ps1 -IncludeRuntimeData -IncludeGradleCaches
#>
param(
    [switch]$IncludeRuntimeData,
    [switch]$IncludeGradleCaches,
    [switch]$NoPause
)

. (Join-Path $PSScriptRoot "_Common.ps1")

# Finds every "build" directory below the repository root, without descending into
# an already found build directory or into folders that never contain build output.
function Get-BuildDirectories {
    $result = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    $pending = New-Object System.Collections.Generic.Queue[string]
    $pending.Enqueue($Script:ProjectRoot)

    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        $children = @(Get-ChildItem -LiteralPath $current -Directory -Force -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            if ($child.Name -eq "build") {
                $result.Add($child)
                continue
            }
            if ($child.Name -in @(".git", ".gradle", ".idea", "node_modules")) {
                continue
            }
            $pending.Enqueue($child.FullName)
        }
    }

    return $result
}

# Removes the content of a build directory, optionally keeping the launcher runtime data.
function Remove-BuildDirectory {
    param([Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$Directory)

    $runtimeData = Join-Path $Directory.FullName "libs\.hmcl"
    $keepRuntimeData = -not $IncludeRuntimeData -and (Test-Path -LiteralPath $runtimeData)

    if ($keepRuntimeData) {
        Get-ChildItem -LiteralPath $Directory.FullName -Force |
            Where-Object { $_.Name -ne "libs" } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }

        Get-ChildItem -LiteralPath (Join-Path $Directory.FullName "libs") -Force |
            Where-Object { $_.Name -ne ".hmcl" } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }

        Write-Host "  cleaned: $($Directory.FullName)"
        Write-Ok "    kept runtime data: $runtimeData"
        return
    }

    Remove-Item -LiteralPath $Directory.FullName -Recurse -Force
    Write-Host "  removed: $($Directory.FullName)"
}

# Removes a folder when it exists, reporting problems instead of aborting the whole clean.
function Remove-Folder {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  not found: $Path"
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Host "  removed: $Path"
    }
    catch {
        Write-Warn "  could not remove: $Path"
        Write-Warn "    $($_.Exception.Message)"
    }
}

# Returns $true when a launcher jar is still open, which means HMCL is running from
# the build output and Windows keeps its files locked.
if (Test-LauncherRunning) {
    Write-Fail ""
    Write-Fail "HMCL is still running from '$($Script:LibsDirectory)'."
    Write-Fail "Close the launcher first: Windows keeps the jar files locked while it runs."
    Wait-ForExit -NoPause:$NoPause
    exit 1
}

$failed = $false
try {
    Write-Step "=== Cleaning build output ==="

    $buildDirectories = @(Get-BuildDirectories)
    if ($buildDirectories.Count -eq 0) {
        Write-Host "No build directories found."
    }
    else {
        foreach ($directory in $buildDirectories) {
            try {
                Remove-BuildDirectory -Directory $directory
            }
            catch {
                Write-Warn "  could not clean: $($directory.FullName)"
                Write-Warn "    $($_.Exception.Message)"
                Write-Warn "    Close the launcher if it is running and try again."
            }
        }
    }

    if ($IncludeGradleCaches) {
        Write-Host ""
        Write-Host "Removing project caches..."
        Remove-Folder -Path (Join-Path $Script:ProjectRoot ".gradle")
        Remove-Folder -Path (Join-Path $Script:ProjectRoot "buildSrc\.gradle")
    }
    else {
        Write-Host ""
        Write-Host "Project caches kept (pass -IncludeGradleCaches to remove them)."
    }

    Write-Host ""
    Write-Host "Removing published artifacts..."
    Remove-Folder -Path $Script:PublishDirectory

    Write-Host ""
    Write-Ok "Clean complete."
}
catch {
    Write-Fail ""
    Write-Fail "CLEAN FAILED: $($_.Exception.Message)"
    $failed = $true
}

if ($failed) {
    Wait-ForExit -NoPause:$NoPause
    exit 1
}

Wait-ForExit -NoPause:$NoPause
