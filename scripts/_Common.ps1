# Common helpers shared by the build scripts in this folder.
# Dot-source this file:  . (Join-Path $PSScriptRoot "_Common.ps1")

$ErrorActionPreference = "Stop"

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$Script:LibsDirectory = Join-Path $Script:ProjectRoot "HMCL\build\libs"
$Script:PublishDirectory = Join-Path $Script:ProjectRoot "Publish"
$Script:RequiredJavaVersion = 17

# Gradle launcher used by the scripts. It is resolved on every build: an explicit
# -GradlePath, then Gradle from PATH, then the saved path, then (after asking the user)
# a path entered in the terminal. ./gradlew.bat is only the last resort.
$Script:GradleCommand = Join-Path $Script:ProjectRoot "gradlew.bat"

# Remembers the Gradle path entered by the user, so the question is asked only once.
# This file is generated locally and is ignored by git.
$Script:GradlePathFile = Join-Path $PSScriptRoot "gradle-path.txt"

# Extra arguments appended to every Gradle invocation.
# local.settings.ps1 may replace this array, for example with "--max-workers=1".
$Script:DefaultGradleArguments = @()

# Machine-specific overrides (Gradle cache, repository mirror, JVM options) are kept
# in an untracked file so the scripts themselves stay portable.
$localSettings = Join-Path $PSScriptRoot "local.settings.ps1"
if (Test-Path -LiteralPath $localSettings -PathType Leaf) {
    . $localSettings
}

function Write-Step {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
}

# Keeps the console window open so the user can read the output.
# Skipped when -NoPause is passed (useful for CI).
function Wait-ForExit {
    param([switch]$NoPause)
    if ($NoPause) { return }
    Write-Host ""
    Write-Host "Press any key to exit..." -ForegroundColor DarkGray
    try {
        $null = [System.Console]::ReadKey($true)
    }
    catch {
        try { $null = Read-Host }
        catch { Start-Sleep -Seconds 3 }
    }
}

# Returns the java.exe that Gradle will use, or $null when Java is not installed.
function Resolve-JavaExecutable {
    if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
        $candidate = Join-Path ($env:JAVA_HOME.Trim('"')) "bin\java.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $command = Get-Command java -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Path
    }

    return $null
}

# Returns the java.exe that Gradle will use, or $null when a JRE (no javac) is installed.
function Resolve-JavaCompiler {
    param([Parameter(Mandatory = $true)][string]$JavaExecutable)

    $candidate = Join-Path (Split-Path -Parent $JavaExecutable) "javac.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    $command = Get-Command javac -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Path
    }

    return $null
}

# Reads the major version from the output of "java -version", for example 17 for "17.0.12".
function Get-JavaMajorVersion {
    param([Parameter(Mandatory = $true)][string]$JavaExecutable)

    # java prints its version to stderr, and "Stop" would turn that into an exception.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $JavaExecutable -version 2>&1 | Out-String
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($output -match 'version "(?<major>\d+)') {
        $major = [int]$Matches['major']
        if ($major -eq 1 -and $output -match 'version "1\.(?<legacy>\d+)') {
            return [int]$Matches['legacy']
        }
        return $major
    }

    return 0
}

# Returns a list of human readable problems. Empty list means everything is ready.
function Test-JavaPrerequisites {
    $problems = New-Object System.Collections.Generic.List[string]

    $java = Resolve-JavaExecutable
    if (-not $java) {
        $problems.Add("Java was not found. Install a JDK 17 or newer and set JAVA_HOME, or add java.exe to PATH.")
        return $problems
    }

    $major = Get-JavaMajorVersion -JavaExecutable $java
    if ($major -lt $Script:RequiredJavaVersion) {
        $problems.Add("JDK $($Script:RequiredJavaVersion) or newer is required (found Java $major at '$java').")
    }

    if (-not (Resolve-JavaCompiler -JavaExecutable $java)) {
        $problems.Add("javac was not found next to '$java'. A full JDK is required, a JRE is not enough.")
    }

    return $problems
}

function Show-PrerequisiteHelp {
    param($Problems)

    Write-Fail ""
    Write-Fail "Cannot start the build because some required components are missing:"
    foreach ($problem in $Problems) {
        Write-Fail "  - $problem"
    }
    Write-Host ""
    Write-Warn "How to fix:"
    Write-Host "  1. Install a JDK 17 or newer: https://adoptium.net/"
    Write-Host "  2. Point JAVA_HOME at that JDK (or put its bin folder on PATH)."
    Write-Host "     Make sure javac.exe is in the same bin folder, otherwise it is a JRE, not a JDK."
    Write-Host "  3. The first build downloads Gradle and all dependencies, so it needs internet access."
}

# Returns $true when a launcher jar in the build output is still open, which means
# HMCL is running from there and Windows keeps its files locked.
function Test-LauncherRunning {
    if (-not (Test-Path -LiteralPath $Script:LibsDirectory)) {
        return $false
    }

    $jars = @(Get-ChildItem -LiteralPath $Script:LibsDirectory -File -Filter "HMCL-*.jar" -ErrorAction SilentlyContinue)
    foreach ($jar in $jars) {
        try {
            $stream = [System.IO.File]::Open(
                $jar.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::None)
            $stream.Dispose()
        }
        catch {
            return $true
        }
    }

    return $false
}

# Resolves a Gradle launcher from a gradle.bat/gradle.exe path, a "bin" folder or the
# root of an installed Gradle distribution.
#
# Returns the full path to the launcher, or $null when nothing usable was found.
function Resolve-GradleLauncher {
    param([Parameter(Mandatory = $true)][string]$Path)

    $trimmed = $Path.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $null
    }

    try {
        if (Test-Path -LiteralPath $trimmed -PathType Leaf) {
            return (Resolve-Path -LiteralPath $trimmed).Path
        }

        if (Test-Path -LiteralPath $trimmed -PathType Container) {
            foreach ($relative in @("bin\gradle.bat", "bin\gradle.exe", "gradle.bat", "gradle.exe")) {
                $candidate = Join-Path $trimmed $relative
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    return (Resolve-Path -LiteralPath $candidate).Path
                }
            }
        }
    }
    catch {
        # A path on a drive that does not exist is simply not a Gradle installation.
    }

    return $null
}

# Returns the "gradle" command found in PATH, or $null when Gradle is not installed there.
function Find-GradleOnPath {
    $command = Get-Command gradle -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return $null
    }
    return $command.Path
}

# Writes the Gradle launcher path to the file remembered for the next builds.
function Save-GradlePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        [System.IO.File]::WriteAllText($Script:GradlePathFile, $Path, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-Warn "Could not save the Gradle path to '$($Script:GradlePathFile)': $($_.Exception.Message)"
    }
}

# Reads the Gradle path remembered from a previous run.
#
# Returns $null when the file is missing or the remembered path no longer points to a Gradle
# launcher, which happens when the Gradle folder was moved or the script was copied from
# another computer.
function Read-SavedGradlePath {
    try {
        if (-not (Test-Path -LiteralPath $Script:GradlePathFile -PathType Leaf)) {
            return $null
        }

        $saved = [System.IO.File]::ReadAllText($Script:GradlePathFile).Trim()
        if ([string]::IsNullOrWhiteSpace($saved)) {
            return $null
        }

        $resolved = Resolve-GradleLauncher -Path $saved
        if ($null -ne $resolved) {
            return $resolved
        }

        Write-Warn "The saved Gradle path no longer exists: $saved"
        Remove-Item -LiteralPath $Script:GradlePathFile -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warn "Could not read '$($Script:GradlePathFile)': $($_.Exception.Message)"
    }

    return $null
}

# Asks the user for the Gradle path in the terminal and remembers it for the next builds.
#
# Returns the resolved launcher path, or $null when the user presses Enter.
function Read-GradleLauncherFromConsole {
    Write-Host ""
    Write-Warn "Gradle was not found in PATH."
    Write-Host "Enter the path to a Gradle installation or to gradle.bat, for example:"
    Write-Host "  C:\gradle\gradle-9.9.1"
    Write-Host "The path is saved to '$($Script:GradlePathFile)' and reused by the next builds."
    Write-Host ""
    Write-Host "Enter the path, or press Enter to use ./gradlew.bat: " -NoNewline

    try {
        $answer = Read-Host
    }
    catch {
        # The script is running in a non-interactive host (CI), so do not ask again.
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $null
    }

    $resolved = Resolve-GradleLauncher -Path $answer
    if (-not $resolved) {
        Write-Fail "Gradle was not found at '$answer'."
        return $null
    }

    Save-GradlePath -Path $resolved
    Write-Ok "Gradle path saved: $resolved"
    return $resolved
}

# Chooses the Gradle launcher for this run.
#
# The order is: the -GradlePath parameter, the "gradle" command from PATH, the path
# remembered from a previous run, and finally a question in the terminal. The Gradle wrapper
# is used only when the user declines to enter a path. The disk is never scanned.
function Resolve-GradleCommand {
    param([string]$RequestedPath = "")

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $resolved = Resolve-GradleLauncher -Path $RequestedPath
        if (-not $resolved) {
            throw "Gradle was not found at '$RequestedPath'. Pass a gradle.bat file or a Gradle installation folder."
        }
        return $resolved
    }

    $resolved = Find-GradleOnPath
    if ($null -ne $resolved) {
        return $resolved
    }

    $resolved = Read-SavedGradlePath
    if ($null -ne $resolved) {
        return $resolved
    }

    $resolved = Read-GradleLauncherFromConsole
    if ($null -ne $resolved) {
        return $resolved
    }

    if (Test-Path -LiteralPath $Script:GradleCommand -PathType Leaf) {
        return $Script:GradleCommand
    }

    throw "Gradle was not found. Install Gradle 9.9.1, add it to PATH, or pass -GradlePath."
}

# Runs Gradle in the repository root and fails on a non-zero exit code.
function Invoke-Gradle {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if (-not (Test-Path -LiteralPath $Script:GradleCommand -PathType Leaf)) {
        throw "Gradle launcher not found: $($Script:GradleCommand)"
    }

    $allArguments = @($Arguments) + @($Script:DefaultGradleArguments)

    Push-Location -LiteralPath $Script:ProjectRoot
    try {
        & $Script:GradleCommand @allArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Gradle failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}
