<#
.SYNOPSIS
    Builds all three runnable HMCL variants: .jar, .exe and .sh.

.DESCRIPTION
    Runs the Gradle task ":HMCL:makeExecutables", which produces:
        HMCL/build/libs/HMCL-<version>.jar
        HMCL/build/libs/HMCL-<version>.exe
        HMCL/build/libs/HMCL-<version>.sh
    plus the matching .sha1, .sha256 and .sha512 checksum files.

    The Windows executable is the HMCLauncher stub with the jar appended. Its version
    resource is rewritten so the file properties show the version from config/project.properties
    (taken from the jar manifest) instead of the stub's own 3.7.0.1.

    The .deb package and the release archives are not built by this script;
    run Gradle directly if you need them.

.PARAMETER GradlePath
    Path to the Gradle launcher (gradle.bat or gradle.exe), a "bin" folder or the root
    of an installed Gradle distribution, for example C:\gradle\gradle-9.9.1.

    Normally the script first checks the "gradle" command in PATH, then the path it asked
    for in scripts\gradle-path.txt. This parameter overrides both, for example on a machine
    where several Gradle versions are installed.

.PARAMETER Clean
    Runs "clean" before building, so every class is compiled from scratch.

.PARAMETER RunTests
    Runs the unit tests of every module before the launcher is packaged.

.PARAMETER NoDaemon
    Starts Gradle without the background daemon. Use it on machines with little RAM.

.PARAMETER NoPublish
    Keeps the artifacts only in HMCL\build\libs instead of copying them to Publish.

.PARAMETER NoPause
    Closes the console immediately instead of waiting for a key press.

.EXAMPLE
    .\Build-HMCL.ps1

.EXAMPLE
    .\Build-HMCL.ps1 -Clean -RunTests

.EXAMPLE
    .\Build-HMCL.ps1 -GradlePath C:\gradle\gradle-9.9.1
#>
param(
    [string]$GradlePath = "",
    [switch]$Clean,
    [switch]$RunTests,
    [switch]$NoDaemon,
    [switch]$NoPublish,
    [switch]$NoPause
)

. (Join-Path $PSScriptRoot "_Common.ps1")
. (Join-Path $PSScriptRoot "_ExeVersion.ps1")

# Reads the version of the artifacts that the build has just produced. It comes from the
# manifest of the newest jar, because Gradle derives it from config/project.properties and
# the VERSION_ROOT / BUILD_NUMBER / VERSION_TYPE environment variables.
#
# Returns an empty string when no jar with an Implementation-Version is present.
function Get-BuildVersion {
    $jars = @(Get-ChildItem -LiteralPath $Script:LibsDirectory -File -Filter "HMCL-*.jar" -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)

    foreach ($jar in $jars) {
        $jarVersion = Get-JarVersion -JarPath $jar.FullName
        if (-not [string]::IsNullOrWhiteSpace($jarVersion)) {
            return $jarVersion
        }
    }

    return ""
}

# Returns the jar/exe/sh artifacts of the given version, sorted by name.
# Files from earlier builds stay in build\libs, so they are filtered out here; otherwise
# an older release would be copied to Publish next to the new one.
function Get-BuiltArtifacts {
    param([Parameter(Mandatory = $true)][string]$Version)

    if (-not (Test-Path -LiteralPath $Script:LibsDirectory)) {
        return @()
    }

    $pattern = '^HMCL-' + [regex]::Escape($Version) + '\.(jar|exe|sh)$'

    return @(Get-ChildItem -LiteralPath $Script:LibsDirectory -File |
        Where-Object { $_.Name -match $pattern } |
        Sort-Object -Property Name)
}

# Prints a warning for every artifact of another version left in build\libs, so a stale
# file cannot be mistaken for a result of this build.
function Show-StaleArtifacts {
    param([Parameter(Mandatory = $true)][string]$Version)

    if (-not (Test-Path -LiteralPath $Script:LibsDirectory)) {
        return
    }

    $pattern = '^HMCL-' + [regex]::Escape($Version) + '\.'
    $stale = @(Get-ChildItem -LiteralPath $Script:LibsDirectory -File |
        Where-Object { $_.Extension -in @(".jar", ".exe", ".sh") -and $_.Name -notmatch $pattern })

    foreach ($file in $stale) {
        Write-Warn "Ignoring $($file.Name): it belongs to another version. Pass -Clean to remove stale files."
    }
}

# Prints the produced artifacts with their sizes so the result is easy to find.
function Show-Artifacts {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo[]]$Artifacts)

    if ($Artifacts.Count -eq 0) {
        Write-Warn "No artifacts were found in $($Script:LibsDirectory)."
        return
    }

    Write-Host ""
    Write-Host "Artifacts:"
    foreach ($artifact in $Artifacts) {
        $size = "{0,8:N1} MB" -f ($artifact.Length / 1MB)
        Write-Host ("  {0,-32} {1}  {2}" -f $artifact.Name, $size, $artifact.LastWriteTime)
    }
}

# Copies the artifacts and their checksums into the Publish folder, which is where the
# ready-to-use files are collected. The folder is recreated so files from an older build
# never stay next to the new ones.
function Publish-Artifacts {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo[]]$Artifacts)

    if (Test-Path -LiteralPath $Script:PublishDirectory) {
        Remove-Item -LiteralPath $Script:PublishDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Script:PublishDirectory -Force | Out-Null

    foreach ($artifact in $Artifacts) {
        Copy-Item -LiteralPath $artifact.FullName -Destination $Script:PublishDirectory -Force

        # The checksum files are produced for the jar and its wrappers, so copy them too.
        foreach ($extension in @(".sha1", ".sha256", ".sha512")) {
            $checksum = "$($artifact.FullName)$extension"
            if (Test-Path -LiteralPath $checksum -PathType Leaf) {
                Copy-Item -LiteralPath $checksum -Destination $Script:PublishDirectory -Force
            }
        }
    }
}

$failed = $false
try {
    Write-Step "=== Checking prerequisites ==="
    $problems = Test-JavaPrerequisites
    if ($problems.Count -gt 0) {
        Show-PrerequisiteHelp -Problems $problems
        throw "Prerequisites are missing."
    }

    # The Gradle launcher is taken from -GradlePath, PATH, the saved path, or a question
    # in the terminal. The disk is never scanned for a Gradle installation.
    $Script:GradleCommand = Resolve-GradleCommand -RequestedPath $GradlePath

    $java = Resolve-JavaExecutable
    Write-Ok "Java $((Get-JavaMajorVersion -JavaExecutable $java)): $java"
    Write-Host "Gradle: $($Script:GradleCommand)"
    if (-not [string]::IsNullOrWhiteSpace($env:GRADLE_USER_HOME)) {
        Write-Host "Gradle user home: $($env:GRADLE_USER_HOME)"
    }

    # The running launcher keeps HMCL-<version>.jar open, so Gradle cannot replace it.
    if (Test-LauncherRunning) {
        throw "HMCL is running from $($Script:LibsDirectory). Close the launcher and run the script again."
    }

    $tasks = New-Object System.Collections.Generic.List[string]
    if ($Clean) { $tasks.Add("clean") }
    if ($RunTests) { $tasks.Add("test") }
    $tasks.Add(":HMCL:makeExecutables")

    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($task in $tasks) { $arguments.Add($task) }
    $arguments.Add("--console=plain")
    if ($NoDaemon) { $arguments.Add("--no-daemon") }

    Write-Step ""
    Write-Step "=== Building HMCL (jar, exe, sh) ==="
    Invoke-Gradle -Arguments $arguments.ToArray()

    $version = Get-BuildVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Could not read the HMCL version from the jar manifest in $($Script:LibsDirectory)."
    }

    $artifacts = Get-BuiltArtifacts -Version $version
    Show-Artifacts -Artifacts $artifacts
    Show-StaleArtifacts -Version $version

    # The .exe is the HMCLauncher stub with the jar appended; the stub reports its own
    # version (3.7.0.1) in the file properties, so the resource is rewritten with the
    # version Gradle stamped into the jar manifest.
    $exe = $artifacts | Where-Object { $_.Extension -eq ".exe" } | Select-Object -First 1
    $jar = $artifacts | Where-Object { $_.Extension -eq ".jar" } | Select-Object -First 1
    if ($null -ne $exe -and $null -ne $jar) {
        Write-Step ""
        Write-Step "=== Writing the HMCL version into the executable ==="
        if (Update-HmclExecutable -ExePath $exe.FullName -JarPath $jar.FullName) {
            Write-Ok "Version set to $version in $($exe.Name)"
        }
    }

    if ($NoPublish) {
        Write-Host ""
        Write-Warn "Artifacts were not copied to Publish (-NoPublish)."
    }
    else {
        Write-Step ""
        Write-Step "=== Copying artifacts to Publish ==="
        Publish-Artifacts -Artifacts $artifacts
        Write-Ok "Published to: $($Script:PublishDirectory)"
    }

    Write-Host ""
    Write-Ok "Build complete."
}
catch {
    if ($_.Exception.Message -ne "Prerequisites are missing.") {
        Write-Fail ""
        Write-Fail "BUILD FAILED: $($_.Exception.Message)"
        Write-Host "If the error mentions downloading Gradle or dependencies, check the internet connection."
        Write-Host "If the error mentions JavaFX or missing symbols, make sure JAVA_HOME points at a JDK 17 or newer."
    }
    $failed = $true
}

if ($failed) {
    Wait-ForExit -NoPause:$NoPause
    exit 1
}

Wait-ForExit -NoPause:$NoPause
