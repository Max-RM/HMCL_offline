<#
.SYNOPSIS
    Generates the release note text for the artifacts in the Publish folder.

.DESCRIPTION
    Reads HMCL-<version>.jar, .exe and .sh from Publish together with their .sha256
    files and writes a Markdown release note in the same shape the official HMCL
    releases use: a download table with a link and the SHA-256 checksum of every file.

    The version is taken from the jar manifest (Implementation-Version), so the note
    always describes the artifacts that are actually in Publish. Run this script after
    Build-HMCL.ps1 and paste the result into GitHub Releases.

    Before writing anything the script checks every .sha256 file against the artifact
    itself, so a note with wrong checksums cannot be produced. A missing checksum file
    is an error too; rebuild instead of publishing an artifact that cannot be verified.

.PARAMETER Version
    Version to describe, for example 3.18.1. Defaults to the version of the newest jar
    in the Publish folder.

.PARAMETER Tag
    Release tag used in the download links. Defaults to "v<version>", the convention
    used by the upstream HMCL releases (for example v3.18.1).

.PARAMETER Repository
    Repository in the "owner/name" form, used to build the download links. Defaults to
    the origin remote of this repository.

.PARAMETER OutputPath
    File to write the note to. Defaults to Publish\RELEASE-NOTES-<tag>.md.

.PARAMETER NoPause
    Closes the console immediately instead of waiting for a key press.

.EXAMPLE
    .\New-ReleaseNotes.ps1

.EXAMPLE
    .\New-ReleaseNotes.ps1 -Version 3.18.1 -Tag v3.18.1
#>
param(
    [string]$Version = "",
    [string]$Tag = "",
    [string]$Repository = "",
    [string]$OutputPath = "",
    [switch]$NoPause
)

. (Join-Path $PSScriptRoot "_Common.ps1")
. (Join-Path $PSScriptRoot "_ExeVersion.ps1")

# Artifact extensions that a release contains, in the order they appear in the note.
$Script:ReleaseExtensions = @(".exe", ".jar", ".sh")

# Returns the version of the newest jar in the publish folder, or an empty string when
# the folder has no jar with an Implementation-Version in its manifest.
function Get-PublishedVersion {
    $jars = @(Get-ChildItem -LiteralPath $Script:PublishDirectory -File -Filter "HMCL-*.jar" -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)

    foreach ($jar in $jars) {
        $jarVersion = Get-JarVersion -JarPath $jar.FullName
        if (-not [string]::IsNullOrWhiteSpace($jarVersion)) {
            return $jarVersion
        }
    }

    return ""
}

# Converts a byte count into the "11.56 MB" form used in release notes.
# The invariant culture keeps the decimal point on machines with a comma separator.
function Format-FileSize {
    param([Parameter(Mandatory = $true)][long]$Bytes)

    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.00} MB", ($Bytes / 1MB))
}

# Reads the SHA-256 checksum of a file from its .sha256 file and verifies it.
# Stops the script when the file is missing or does not match the artifact, because
# publishing a release note with an incorrect checksum is worse than publishing none.
function Get-VerifiedSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $checksumFile = "$Path.sha256"
    if (-not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) {
        Write-Fail "Missing $checksumFile. Rebuild the artifacts instead of publishing unverifiable files."
        throw "Missing checksum file: $checksumFile"
    }

    $expected = ([System.IO.File]::ReadAllText($checksumFile)).Trim().Split(" ")[0].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($expected -ne $actual) {
        Write-Fail "The checksum in $checksumFile does not match $([System.IO.Path]::GetFileName($Path))."
        Write-Fail "  file: $expected"
        Write-Fail "  real: $actual"
        throw "Checksum mismatch: $checksumFile"
    }

    return $actual
}

# Extracts "owner/name" from the origin remote, so the download links point at the
# repository the release is published in. Returns an empty string when the remote is
# missing or does not point at GitHub.
function Get-OriginRepository {
    $remote = ""
    try {
        $remote = (& git -C $Script:ProjectRoot remote get-url origin 2>$null | Select-Object -First 1)
    }
    catch {
        return ""
    }
    if ([string]::IsNullOrWhiteSpace($remote)) {
        return ""
    }

    if ($remote -match 'github\.com[:/](?<slug>[^/]+/[^/]+?)(\.git)?/?$') {
        return $Matches['slug']
    }

    return ""
}

# Describes how a file with the given extension is started.
function Get-LaunchDescription {
    param([Parameter(Mandatory = $true)][string]$Extension)

    switch ($Extension) {
        ".exe" { return "Windows, запускается двойным щелчком" }
        ".jar" { return "любая ОС с Java 17+, запускается командой java -jar" }
        ".sh" { return "Linux и macOS, запускается как ./HMCL-<version>.sh" }
        default { return "" }
    }
}

# Builds the Markdown release note for one version.
function New-ReleaseNoteText {
    param(
        [Parameter(Mandatory = $true)][string]$NoteVersion,
        [Parameter(Mandatory = $true)][string]$NoteTag,
        [Parameter(Mandatory = $true)][string]$NoteRepository
    )

    $downloadBase = "https://github.com/$NoteRepository/releases/download/$NoteTag"
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("Неофициальная сборка HMCL $NoteVersion для личного использования, собранная из форка https://github.com/$NoteRepository")
    $lines.Add("")
    $lines.Add("| File | Size | SHA-256 Checksum |")
    $lines.Add("| --- | --- | --- |")

    $launchLines = New-Object System.Collections.Generic.List[string]

    foreach ($extension in $Script:ReleaseExtensions) {
        $name = "HMCL-$NoteVersion$extension"
        $file = Join-Path $Script:PublishDirectory $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Missing artifact: $file"
        }

        $item = Get-Item -LiteralPath $file
        $sha256 = Get-VerifiedSha256 -Path $file
        $size = Format-FileSize -Bytes $item.Length

        $lines.Add("| [$name]($downloadBase/$name) | $size | ``$sha256`` |")

        $description = Get-LaunchDescription -Extension $extension
        $description = $description.Replace("<version>", $NoteVersion)
        $launchLines.Add("- ``$name`` - $description")
    }

    $lines.Add("")
    $lines.Add("Все три файла — одна и та же сборка, отличается только способ запуска:")
    $lines.Add("")
    foreach ($line in $launchLines) {
        $lines.Add($line)
    }
    $lines.Add("")
    $lines.Add("Проверить контрольную сумму перед запуском:")
    $lines.Add("")
    $lines.Add('```powershell')
    $lines.Add("Get-FileHash .\HMCL-$NoteVersion.exe -Algorithm SHA256")
    $lines.Add('```')
    $lines.Add("")
    $lines.Add('```bash')
    $lines.Add("sha256sum -c HMCL-$NoteVersion.exe.sha256")
    $lines.Add('```')

    return ($lines -join "`n")
}

try {
    if (-not (Test-Path -LiteralPath $Script:PublishDirectory -PathType Container)) {
        Write-Fail "The Publish folder does not exist: $($Script:PublishDirectory)"
        Write-Fail "Run Build-HMCL.ps1 first."
        throw "Publish folder is missing"
    }

    if ([string]::IsNullOrWhiteSpace($Version)) {
        $Version = Get-PublishedVersion
        if ([string]::IsNullOrWhiteSpace($Version)) {
            Write-Fail "Could not find the version: Publish has no HMCL-*.jar with an Implementation-Version."
            throw "Version not detected"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Tag)) {
        $Tag = "v$Version"
    }

    if ([string]::IsNullOrWhiteSpace($Repository)) {
        $Repository = Get-OriginRepository
        if ([string]::IsNullOrWhiteSpace($Repository)) {
            Write-Fail "Could not read the GitHub repository from the origin remote."
            Write-Fail "Pass it explicitly, for example: -Repository owner/HMCL_offline"
            throw "Repository not detected"
        }
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Join-Path $Script:PublishDirectory "RELEASE-NOTES-$Tag.md"
    }

    Write-Step "=== Release note for HMCL $Version (tag $Tag) ==="
    $note = New-ReleaseNoteText -NoteVersion $Version -NoteTag $Tag -NoteRepository $Repository

    [System.IO.File]::WriteAllText($OutputPath, $note + "`n", (New-Object System.Text.UTF8Encoding($false)))

    Write-Ok "Checksums verified and written to $OutputPath"
    Write-Step ""
    Write-Host $note
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}

Wait-ForExit -NoPause:$NoPause
