#Requires -Version 5.1
<#
.SYNOPSIS
    kpsec — use secrets from a local KeePassXC database without printing them (Windows).
.DESCRIPTION
    The master password lives in Windows Credential Manager; secrets are resolved
    in-process and handed to the child through its environment, never through argv.
    Linux and macOS use the bash version in the same directory.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = "Stop"

$Db = if ($env:KPSEC_DB) { $env:KPSEC_DB } else { Join-Path $HOME ".pass\agents.kdbx" }
$Target = "kpsec master key:$Db"

function Die($msg, $code = 1) { Write-Error "kpsec: $msg"; exit $code }

function Get-KeepassxcCli {
    if ($env:KPSEC_KEEPASSXC_CLI) { return $env:KPSEC_KEEPASSXC_CLI }
    $cmd = Get-Command keepassxc-cli -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:ProgramFiles\KeePassXC\keepassxc-cli.exe",
                     "${env:ProgramFiles(x86)}\KeePassXC\keepassxc-cli.exe")) {
        if (Test-Path $p) { return $p }
    }
    return "keepassxc-cli"
}

# Credential Manager through the native API: no extra modules, no file on disk.
$CredApi = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class KpsecCred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL {
        public uint Flags; public uint Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist;
        public uint AttributeCount; public IntPtr Attributes;
        public string TargetAlias; public string UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, uint type, uint flags, out IntPtr cred);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref CREDENTIAL cred, uint flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, uint type, uint flags);
    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    public static string Read(string target) {
        IntPtr ptr;
        if (!CredReadW(target, 1, 0, out ptr)) return null;
        try {
            CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
            return Encoding.Unicode.GetString(
                ReadBlob(cred.CredentialBlob, (int)cred.CredentialBlobSize));
        } finally { CredFree(ptr); }
    }

    private static byte[] ReadBlob(IntPtr p, int size) {
        byte[] buf = new byte[size];
        Marshal.Copy(p, buf, 0, size);
        return buf;
    }

    public static void Write(string target, string secret) {
        byte[] blob = Encoding.Unicode.GetBytes(secret);
        CREDENTIAL cred = new CREDENTIAL();
        cred.Type = 1;                 // CRED_TYPE_GENERIC
        cred.TargetName = target;
        cred.UserName = "kpsec";
        cred.Persist = 2;              // CRED_PERSIST_LOCAL_MACHINE
        cred.CredentialBlobSize = (uint)blob.Length;
        cred.CredentialBlob = Marshal.AllocHGlobal(blob.Length);
        try {
            Marshal.Copy(blob, 0, cred.CredentialBlob, blob.Length);
            if (!CredWriteW(ref cred, 0))
                throw new Exception("CredWrite failed: " + Marshal.GetLastWin32Error());
        } finally { Marshal.FreeHGlobal(cred.CredentialBlob); }
    }

    public static bool Delete(string target) { return CredDeleteW(target, 1, 0); }
}
'@
if (-not ("KpsecCred" -as [type])) { Add-Type -TypeDefinition $CredApi }

function Get-MasterFromKeyring { try { [KpsecCred]::Read($Target) } catch { $null } }
function Set-MasterInKeyring($secret) { [KpsecCred]::Write($Target, $secret) }
function Remove-MasterFromKeyring { try { [KpsecCred]::Delete($Target) } catch { $false } }

function Read-MasterPassword {
    $master = Get-MasterFromKeyring
    if ($master) { return $master }
    if ($env:KPSEC_NO_GUI) { return $null }
    $cred = Get-Credential -UserName kpsec -Message "Master password for $(Split-Path -Leaf $Db)"
    if (-not $cred) { return $null }
    return $cred.GetNetworkCredential().Password
}

# The master password goes in on stdin, never in argv.
function Invoke-Kp {
    param([string[]]$KpArgs, [string]$ExtraStdin = "", [switch]$Quiet)
    $master = Read-MasterPassword
    if (-not $master) { Die "cannot obtain the database master password" 4 }
    $stdin = "$master`n$ExtraStdin"
    if ($Quiet) { $stdin | & (Get-KeepassxcCli) @KpArgs 2>$null }
    else { $stdin | & (Get-KeepassxcCli) @KpArgs }
}

function Split-Ref($ref) {
    if ($ref -notmatch '^kp://') { Die "malformed reference: $ref (expected kp://group/entry#Attribute)" 2 }
    $body = $ref.Substring(5)
    $parts = $body -split '#', 2
    return @{ Path = $parts[0]; Attr = if ($parts.Count -gt 1) { $parts[1] } else { "Password" } }
}

function Resolve-Ref($ref, [switch]$Soft) {
    $r = Split-Ref $ref
    $kpArgs = if ($r.Attr.StartsWith("@")) {
        @("attachment-export", "-q", "--stdout", $Db, $r.Path, $r.Attr.Substring(1), "NUL")
    } else {
        @("show", "-q", "-s", "-a", $r.Attr, $Db, $r.Path)
    }
    $value = Invoke-Kp -KpArgs $kpArgs -Quiet:$Soft
    if ($value) { return ($value -join "`n").TrimEnd("`r", "`n") }
    return $null
}

function Get-ShaPrefix($value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($value))
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 8)
}

switch ($Command) {
    "status" {
        $state = if (Test-Path $Db) { "present" } else { "MISSING" }
        Write-Host "db:             $Db ($state)"
        Write-Host "keepassxc-cli:  $(Get-KeepassxcCli)"
        $key = if (Get-MasterFromKeyring) { "key present" } else { "no key" }
        Write-Host "keyring:        credential manager ($key)"
        Write-Host "cache:          unsupported on this platform"
        if (Test-Path $Db) {
            Invoke-Kp -KpArgs @("db-info", "-q", $Db) -Quiet | Out-Null
            $ok = if ($LASTEXITCODE -eq 0) { "ok" } else { "FAILED" }
            Write-Host "unlock:         $ok"
        }
    }

    "ls" {
        $group = if ($Rest) { $Rest[0] } else { "/" }
        Invoke-Kp -KpArgs @("ls", "-q", "-R", "-f", $Db, $group)
    }

    "show" {
        if (-not $Rest) { Die "usage: kpsec show <group>/<entry>" 2 }
        $path = ($Rest[0] -replace '^kp://', '').Split('#')[0]
        $out = (Invoke-Kp -KpArgs @("show", "-q", "--all", "--show-attachments", $Db, $path)) -join "`n"
        $notes = (Invoke-Kp -KpArgs @("show", "-q", "-a", "Notes", $Db, $path)) -join "`n"
        $out = $out.Replace("Notes: $notes", "")
        $names = @(); $atts = @(); $inAtts = $false
        foreach ($line in $out -split "`n") {
            if ($line -match '^Attachments:') { $inAtts = $true; continue }
            if ($inAtts) { $atts += $line; continue }
            if ($line -match '^(Title|UserName|URL|Tags): .') { Write-Host $line; continue }
            if ($line -match '^(Title|UserName|URL|Tags|Password|Uuid): ') { continue }
            if ($line -match '^([^ :][^:]*): ') { $names += $Matches[1] }
        }
        if ($names) { Write-Host "Attributes: $($names -join ', ')" }
        if ($atts) { Write-Host "Attachments:"; $atts | ForEach-Object { Write-Host $_ } }
        if ($notes) { Write-Host "Notes:"; Write-Host $notes }
    }

    "check" {
        if (-not $Rest) { Die "usage: kpsec check <ref>..." 2 }
        $rc = 0
        foreach ($ref in $Rest) {
            $value = Resolve-Ref $ref -Soft
            if ($value) {
                Write-Host ("OK   {0}  len={1} sha256:{2}" -f $ref, $value.Length, (Get-ShaPrefix $value))
            } else {
                Write-Host "FAIL $ref  (no such entry or attribute)"
                $rc = 1
            }
        }
        exit $rc
    }

    "run" {
        $pairs = @(); $files = @(); $envFile = $null; $i = 0
        while ($i -lt $Rest.Count) {
            switch -regex ($Rest[$i]) {
                '^--env-file$' { $envFile = $Rest[$i + 1]; $i += 2 }
                '^--env-file=' { $envFile = $Rest[$i].Split('=', 2)[1]; $i++ }
                '^(-e|--env)$' { $pairs += $Rest[$i + 1]; $i += 2 }
                '^(-f|--file)$' { $files += $Rest[$i + 1]; $i += 2 }
                '^--$'         { $i++; break }
                default        { break }
            }
            if ($Rest[$i - 1] -eq '--') { break }
        }
        $cmd = $Rest[$i..($Rest.Count - 1)]
        if (-not $cmd) { Die "no command given after --" 2 }
        if ($envFile) {
            foreach ($line in Get-Content $envFile) {
                if ($line.Trim() -and -not $line.StartsWith("#")) { $pairs += $line.Trim() }
            }
        }
        foreach ($pair in $pairs) {
            $name, $value = $pair.Split('=', 2)
            $value = $value.Trim('"', "'")
            if ($value -like "kp://*") { $value = Resolve-Ref $value }
            Set-Item -Path "env:$name" -Value $value
        }
        $tmp = $null
        if ($files) {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "kpsec.$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $tmp | Out-Null
        }
        try {
            foreach ($pair in $files) {
                $name, $ref = $pair.Split('=', 2)
                $file = Join-Path $tmp $name
                [IO.File]::WriteAllText($file, (Resolve-Ref $ref) + "`n")
                Set-Item -Path "env:$name" -Value $file
            }
            & $cmd[0] @($cmd[1..($cmd.Count - 1)])
            $rc = $LASTEXITCODE
        } finally {
            if ($tmp) { Remove-Item -Recurse -Force $tmp }
        }
        exit $rc
    }

    "add" {
        $path = $null; $username = $null; $url = $null; $generate = $false; $length = 32
        for ($i = 0; $i -lt $Rest.Count; $i++) {
            switch ($Rest[$i]) {
                { $_ -in "-u", "--username" } { $username = $Rest[++$i] }
                "--url"                       { $url = $Rest[++$i] }
                { $_ -in "-g", "--generate" } { $generate = $true }
                { $_ -in "-L", "--length" }   { $length = $Rest[++$i] }
                default                       { $path = $Rest[$i] }
            }
        }
        if (-not $path) { Die "usage: kpsec add <group>/<entry> [-u user] [--url u] [-g]" 2 }

        $group = Split-Path $path -Parent
        if ($group) {
            $prefix = ""
            foreach ($part in ($group -split '[\\/]')) {
                $prefix = if ($prefix) { "$prefix/$part" } else { $part }
                Invoke-Kp -KpArgs @("mkdir", "-q", $Db, $prefix) -Quiet | Out-Null
            }
        }
        $verb = if (Resolve-Ref "kp://$path#Title" -Soft) { "edit" } else { "add" }
        $kpArgs = @($verb, "-q")
        if ($username) { $kpArgs += @("-u", $username) }
        if ($url) { $kpArgs += @("--url", $url) }

        if ($generate) {
            Invoke-Kp -KpArgs ($kpArgs + @("-g", "-L", "$length", "-l", "-U", "-n", "-s", $Db, $path))
        } else {
            $cred = Get-Credential -UserName kpsec -Message "Value for $path"
            if (-not $cred) { Die "no value entered" 3 }
            Invoke-Kp -KpArgs ($kpArgs + @("-p", $Db, $path)) `
                      -ExtraStdin ($cred.GetNetworkCredential().Password + "`n")
        }
        Write-Host "$($verb)ed $path"
    }

    "clip" {
        if (-not $Rest) { Die "usage: kpsec clip <ref> [seconds]" 2 }
        $r = Split-Ref $Rest[0]
        $seconds = if ($Rest.Count -gt 1) { $Rest[1] } else { "15" }
        Invoke-Kp -KpArgs @("clip", "-q", "-a", $r.Attr, $Db, $r.Path, $seconds)
        Write-Host "copied $($Rest[0]) to clipboard for ${seconds}s"
    }

    "init" {
        if (Test-Path $Db) { Die "database already exists: $Db" 3 }
        New-Item -ItemType Directory -Force -Path (Split-Path $Db -Parent) | Out-Null
        $cli = Get-KeepassxcCli
        $master = (& $cli generate -L 40 -l -U -n).Trim()
        "$master`n$master" | & $cli db-create -q -p $Db
        if ($LASTEXITCODE -ne 0) { Die "db-create failed" 5 }
        Set-MasterInKeyring $master
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "Created $Db`n`nMaster password (back it up in your main KeePassXC):`n`n$master`n`n" +
            "It is also stored in Credential Manager, which is where the scripts read it from.",
            "kpsec master password") | Out-Null
        Write-Host "created $Db; master key stored in Credential Manager, shown in a dialog"
    }

    "show-master" {
        $master = Get-MasterFromKeyring
        if (-not $master) { Die "master password not found in Credential Manager" 4 }
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "Database: $Db`n`nMaster password:`n`n$master", "kpsec master password") | Out-Null
        Write-Host "master key shown in a dialog"
    }

    "relocate" {
        if (-not $Rest) { Die "usage: kpsec relocate <new-path>" 2 }
        $newDb = $Rest[0]
        if (-not (Test-Path $newDb)) { Die "no database at $newDb" 3 }
        $master = Read-MasterPassword
        if (-not $master) { Die "no master password known for $Db" 4 }
        $oldTarget = $Target
        $script:Target = "kpsec master key:$newDb"
        Set-MasterInKeyring $master
        $script:Db = $newDb
        Invoke-Kp -KpArgs @("db-info", "-q", $newDb) -Quiet | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Remove-MasterFromKeyring | Out-Null
            Die "$newDb does not open with that master password — nothing changed" 5
        }
        [KpsecCred]::Delete($oldTarget) | Out-Null
        Write-Host "relocated to $newDb"
        Write-Host "set KPSEC_DB if the new path is not the default"
    }

    "lock" { Write-Host "no cache on this platform; the key stays in Credential Manager" }

    default {
        @"
kpsec — use secrets from a local KeePassXC database without printing them

  kpsec.ps1 status                    database, keyring, unlock check
  kpsec.ps1 ls [group]                list entries (never values)
  kpsec.ps1 show <group>/<entry>      fields, attribute names, notes — never values
  kpsec.ps1 check <ref>...            verify refs resolve: length + sha256 prefix
  kpsec.ps1 run [--env-file F] [-e VAR=ref] [-f VAR=ref] -- cmd
  kpsec.ps1 add <group>/<entry> [-u user] [--url u] [-g] [-L n]
  kpsec.ps1 clip <ref> [seconds]
  kpsec.ps1 init
  kpsec.ps1 relocate <path>
  kpsec.ps1 show-master

References: kp://<group>/<entry>[#<Attribute>|#@<attachment>], default Password.
Environment: KPSEC_DB, KPSEC_KEEPASSXC_CLI, KPSEC_NO_GUI.
"@ | Write-Host
    }
}
