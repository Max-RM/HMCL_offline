# Rewrites the version resource of the Windows launcher stub, so that the file
# properties of HMCL-<version>.exe show the HMCL version instead of the version of
# the bundled HMCLauncher.exe (which is 3.7.0.1 and never changes).
#
# The stub is patched before the jar is appended, because the Win32 resource API
# rewrites the whole PE image and would drop the data appended after it.

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

/// <summary>Builds and applies a VS_VERSION_INFO resource block.</summary>
public static class HmclExeVersion {
    private const int RtVersion = 16;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr BeginUpdateResource(string fileName, bool deleteExisting);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateResource(IntPtr hUpdate, IntPtr type, IntPtr name, ushort language, byte[] data, uint dataSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool EndUpdateResource(IntPtr hUpdate, bool discard);

    private static void U16(List<byte> l, int v) {
        l.Add((byte)(v & 0xFF));
        l.Add((byte)((v >> 8) & 0xFF));
    }

    private static void U32(List<byte> l, uint v) {
        for (int i = 0; i < 4; i++) l.Add((byte)((v >> (8 * i)) & 0xFF));
    }

    private static void Pad(List<byte> l) {
        while (l.Count % 4 != 0) l.Add(0);
    }

    private static void Key(List<byte> l, string s) {
        foreach (char c in s) U16(l, c);
        U16(l, 0);
    }

    private static byte[] StrBlock(string key, string value) {
        List<byte> b = new List<byte>();
        U16(b, 0);
        U16(b, value.Length + 1);
        U16(b, 1);
        Key(b, key);
        Pad(b);
        foreach (char c in value) U16(b, c);
        U16(b, 0);
        Pad(b);
        byte[] r = b.ToArray();
        r[0] = (byte)(r.Length & 0xFF);
        r[1] = (byte)((r.Length >> 8) & 0xFF);
        return r;
    }

    private static byte[] Container(string key, int valueLength, int type, List<byte> children) {
        List<byte> b = new List<byte>();
        U16(b, 0);
        U16(b, valueLength);
        U16(b, type);
        Key(b, key);
        Pad(b);
        b.AddRange(children);
        byte[] r = b.ToArray();
        r[0] = (byte)(r.Length & 0xFF);
        r[1] = (byte)((r.Length >> 8) & 0xFF);
        return r;
    }

    private static uint[] ParseParts(string version) {
        string[] raw = version.Split('.');
        uint[] parts = new uint[4];
        for (int i = 0; i < 4; i++) {
            uint v = 0;
            if (i < raw.Length) uint.TryParse(raw[i], out v);
            parts[i] = v;
        }
        return parts;
    }

    /// <summary>Creates a complete VS_VERSION_INFO block.</summary>
    public static byte[] Build(string fileVersion, string productVersion, string tableKey, string[] keys, string[] values) {
        uint[] fv = ParseParts(fileVersion);
        uint[] pv = ParseParts(productVersion);

        List<byte> fixedInfo = new List<byte>();
        U32(fixedInfo, 0xFEEF04BD);
        U32(fixedInfo, 0x00010000);
        U32(fixedInfo, (fv[0] << 16) | fv[1]);
        U32(fixedInfo, (fv[2] << 16) | fv[3]);
        U32(fixedInfo, (pv[0] << 16) | pv[1]);
        U32(fixedInfo, (pv[2] << 16) | pv[3]);
        U32(fixedInfo, 0x3F);
        U32(fixedInfo, 0);
        U32(fixedInfo, 0x00040004);
        U32(fixedInfo, 0x00000001);
        U32(fixedInfo, 0);
        U32(fixedInfo, 0);
        U32(fixedInfo, 0);

        List<byte> tableChildren = new List<byte>();
        for (int i = 0; i < keys.Length; i++) tableChildren.AddRange(StrBlock(keys[i], values[i]));
        byte[] table = Container(tableKey, 0, 1, tableChildren);

        byte[] stringFileInfo = Container("StringFileInfo", 0, 1, new List<byte>(table));

        List<byte> translation = new List<byte>();
        U16(translation, 0x0409);
        U16(translation, 0x04B0);
        byte[] varFileInfo = Container("VarFileInfo", 4, 1, new List<byte>(Container("Translation", 4, 0, translation)));

        List<byte> body = new List<byte>();
        body.AddRange(fixedInfo);
        Pad(body);
        body.AddRange(stringFileInfo);
        body.AddRange(varFileInfo);

        List<byte> root = new List<byte>();
        U16(root, 0);
        U16(root, 52);
        U16(root, 0);
        Key(root, "VS_VERSION_INFO");
        Pad(root);
        root.AddRange(body);

        byte[] result = root.ToArray();
        result[0] = (byte)(result.Length & 0xFF);
        result[1] = (byte)((result.Length >> 8) & 0xFF);
        return result;
    }

    /// <summary>Replaces the version resource of the given executable.</summary>
    public static void Apply(string path, byte[] block, ushort language) {
        IntPtr h = BeginUpdateResource(path, false);
        if (h == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());

        bool updated = UpdateResource(h, (IntPtr)RtVersion, (IntPtr)1, language, block, (uint)block.Length);
        int updateError = Marshal.GetLastWin32Error();
        bool closed = EndUpdateResource(h, false);
        int closeError = Marshal.GetLastWin32Error();

        if (!updated) throw new System.ComponentModel.Win32Exception(updateError);
        if (!closed) throw new System.ComponentModel.Win32Exception(closeError);
    }
}
"@

# The language of the version resource in HMCLauncher.exe. Windows reads the block for
# this language, so writing another one would leave the old version visible.
$Script:ExeVersionLanguage = 0x0409

# Splits "3.18.SNAPSHOT" into the numeric version "3.18.0.0" used by the fixed file info.
function Get-NumericVersion {
    param([Parameter(Mandatory = $true)][string]$Version)

    $parts = New-Object System.Collections.Generic.List[int]
    foreach ($piece in $Version.Split('.')) {
        $number = 0
        if (-not [int]::TryParse($piece, [ref]$number)) {
            break
        }
        $parts.Add($number)
    }

    while ($parts.Count -lt 4) {
        $parts.Add(0)
    }
    while ($parts.Count -gt 4) {
        $parts.RemoveAt($parts.Count - 1)
    }

    return ($parts -join '.')
}

# Rewrites the version resource of a single executable file.
function Set-ExeVersionResource {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $numeric = Get-NumericVersion -Version $Version
    $keys = @(
        "CompanyName",
        "FileDescription",
        "FileVersion",
        "InternalName",
        "LegalCopyright",
        "OriginalFilename",
        "ProductName",
        "ProductVersion"
    )
    $values = @(
        "huanghongxun",
        "Hello Minecraft! Launcher For Windows",
        $numeric,
        "HMCL.exe",
        "Copyright (C) 2025 huangyuhui",
        "HMCL.exe",
        "Hello Minecraft! Launcher",
        $Version
    )

    $block = [HmclExeVersion]::Build($numeric, $Version, "040904b0", $keys, $values)
    [HmclExeVersion]::Apply($Path, $block, $Script:ExeVersionLanguage)
}

# Rewrites the checksum files that Gradle produced for a file whose content changed.
function Update-FileChecksums {
    param([Parameter(Mandatory = $true)][string]$Path)

    foreach ($algorithm in @("SHA1", "SHA256", "SHA512")) {
        $hash = Get-FileHash -LiteralPath $Path -Algorithm $algorithm
        $file = "$Path.$($algorithm.ToLowerInvariant())"
        [System.IO.File]::WriteAllText($file, $hash.Hash.ToLowerInvariant() + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }
}

# Reads the version that Gradle stamped into the jar manifest. This is the same value
# that names the artifacts and is derived from config/project.properties (plus the
# VERSION_ROOT / BUILD_NUMBER / VERSION_TYPE environment variables), so the executable
# never shows the version of the bundled launcher stub.
#
# Returns $null when the manifest has no Implementation-Version attribute.
function Get-JarVersion {
    param([Parameter(Mandatory = $true)][string]$JarPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq "META-INF/MANIFEST.MF" } | Select-Object -First 1
        if ($null -eq $entry) {
            return $null
        }

        $reader = New-Object System.IO.StreamReader($entry.Open())
        try {
            $manifest = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $zip.Dispose()
    }

    # Manifest lines are limited to 72 bytes, so long values continue on lines that
    # start with a space.
    $unwrapped = $manifest -replace "`r`n ", "" -replace "`n ", ""
    foreach ($line in $unwrapped -split "`r?`n") {
        if ($line -match '^Implementation-Version:\s*(?<version>\S+)\s*$') {
            return $Matches['version']
        }
    }

    return $null
}

# Rebuilds HMCL-<version>.exe from the launcher stub inside the jar, with the stub
# version resource replaced, and the jar appended after it.
#
# Returns $true when the executable was rewritten.
function Update-HmclExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [Parameter(Mandatory = $true)][string]$JarPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $version = Get-JarVersion -JarPath $JarPath
    if ([string]::IsNullOrWhiteSpace($version)) {
        Write-Warn "Skipping the version patch: $JarPath has no Implementation-Version in its manifest."
        return $false
    }

    $stubPath = Join-Path ([System.IO.Path]::GetTempPath()) ("hmcl-stub-" + [System.Guid]::NewGuid().ToString("N") + ".exe")
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq "assets/HMCLauncher.exe" } | Select-Object -First 1
            if ($null -eq $entry) {
                Write-Warn "Skipping the version patch: assets/HMCLauncher.exe is not inside $JarPath."
                return $false
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $stubPath, $true)
        }
        finally {
            $zip.Dispose()
        }

        Set-ExeVersionResource -Path $stubPath -Version $version

        # The stub is written first and the jar is appended after it, exactly like the
        # Gradle task does, because the resource API cannot keep the appended data.
        $output = [System.IO.File]::Create($ExePath)
        try {
            $stubBytes = [System.IO.File]::ReadAllBytes($stubPath)
            $output.Write($stubBytes, 0, $stubBytes.Length)

            $jar = [System.IO.File]::OpenRead($JarPath)
            try {
                $jar.CopyTo($output)
            }
            finally {
                $jar.Dispose()
            }
        }
        finally {
            $output.Dispose()
        }

        Update-FileChecksums -Path $ExePath
        return $true
    }
    finally {
        Remove-Item -LiteralPath $stubPath -Force -ErrorAction SilentlyContinue
    }
}
