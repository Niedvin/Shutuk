<#
.SYNOPSIS
    Remove CCShut and Shut from every agent install.ps1 put them in, and put caveman back.

.DESCRIPTION
    The PowerShell twin of uninstall.py. Needs nothing but Windows PowerShell 5.1, and no zips.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File uninstall.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File uninstall.ps1 -DryRun
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [switch]$KeepCavemanOff
)

$ErrorActionPreference = 'Stop'

$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }
$Here     = Split-Path -Parent $PSCommandPath
$Marker   = '.shut-install.json'
$HookPrefix = 'shut-'
$Packages = @('ccshut', 'shut')
$Backups  = Join-Path $UserHome '.shut-backups'
$CavemanStateFile = Join-Path $Backups 'caveman-state.json'
$UninstallState   = Join-Path $Backups 'uninstall.json'
$LegacyState      = Join-Path $Here 'uninstall.json'

$ClaudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $UserHome '.claude' }
$ClaudeOutputStyles = Join-Path $ClaudeHome 'output-styles'

$CodexHooksFile = Join-Path $UserHome '.codex\hooks.json'
$CodexHookDir   = Join-Path $UserHome '.codex\hooks'
$CodexConfig    = Join-Path $UserHome '.codex\config.toml'

$SkillDirs = @(
    [pscustomobject]@{ Name = 'claude';   Path = (Join-Path $ClaudeHome 'skills') }
    [pscustomobject]@{ Name = 'agents';   Path = (Join-Path $UserHome '.agents\skills') }
    [pscustomobject]@{ Name = 'codex';    Path = (Join-Path $UserHome '.codex\skills') }
    [pscustomobject]@{ Name = 'opencode'; Path = (Join-Path $UserHome '.config\opencode\skills') }
    [pscustomobject]@{ Name = 'cursor';   Path = (Join-Path $UserHome '.cursor\skills-cursor') }
    [pscustomobject]@{ Name = 'gemini';   Path = (Join-Path $UserHome '.gemini\skills') }
)

$AlwaysOn = @(
    [pscustomobject]@{ Name = 'codex';    Path = (Join-Path $UserHome '.codex\AGENTS.md') }
    [pscustomobject]@{ Name = 'opencode'; Path = (Join-Path $UserHome '.config\opencode\AGENTS.md') }
    [pscustomobject]@{ Name = 'gemini';   Path = (Join-Path $UserHome '.gemini\GEMINI.md') }
)


# ----------------------------------------------------------------- small helpers

function Write-Utf8([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Utf8([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

function Copy-Aside([string]$Path) {
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $DryRun) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak-uninstall" -Force
    }
}

function ConvertTo-Ordered($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($prop in $Value.PSObject.Properties) { $out[$prop.Name] = ConvertTo-Ordered $prop.Value }
        return $out
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($key in $Value.Keys) { $out[$key] = ConvertTo-Ordered $Value[$key] }
        return $out
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $out = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$out.Add((ConvertTo-Ordered $item)) }
        return , $out.ToArray()
    }
    return $Value
}

function Read-JsonFile([string]$Path) {
    $text = Read-Utf8 $Path
    if (-not $text.Trim()) { return [ordered]@{} }
    try { return ConvertTo-Ordered ($text | ConvertFrom-Json) } catch { return [ordered]@{} }
}

function Get-JsonString([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if     ($code -eq 34) { [void]$sb.Append('\"') }
        elseif ($code -eq 92) { [void]$sb.Append('\\') }
        elseif ($code -eq 8)  { [void]$sb.Append('\b') }
        elseif ($code -eq 12) { [void]$sb.Append('\f') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -eq 9)  { [void]$sb.Append('\t') }
        elseif ($code -lt 32) { [void]$sb.AppendFormat('\u{0:x4}', $code) }
        else                  { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-PrettyJson($Value, [int]$Indent = 0) {
    $pad  = ' ' * $Indent
    $pad2 = ' ' * ($Indent + 2)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) { return (Get-JsonString $Value) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return '{}' }
        $parts = foreach ($key in $Value.Keys) {
            '{0}{1}: {2}' -f $pad2, (Get-JsonString ([string]$key)), (ConvertTo-PrettyJson $Value[$key] ($Indent + 2))
        }
        return "{`n" + (@($parts) -join ",`n") + "`n$pad}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = foreach ($item in $items) { $pad2 + (ConvertTo-PrettyJson $item ($Indent + 2)) }
        return "[`n" + (@($parts) -join ",`n") + "`n$pad]"
    }
    return (Get-JsonString ([string]$Value))
}

function Write-JsonFile([string]$Path, $Data) {
    if ($DryRun) { return }
    Copy-Aside $Path
    Write-Utf8 $Path ((ConvertTo-PrettyJson $Data) + "`n")
}


# ----------------------------------------------------------------- removal

function Remove-Skill([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    if (-not (Test-Path -LiteralPath (Join-Path $Path $Marker) -PathType Leaf) -and -not $Force) {
        return 'kept (not installed by install.ps1; -Force removes it)'
    }
    if (-not $DryRun) { Remove-Item -LiteralPath $Path -Recurse -Force }
    return 'removed'
}

function Remove-Graft([string]$Path, [string]$Name) {
    $begin = "<!-- shut:${Name}:begin -->"
    $end   = "<!-- shut:${Name}:end -->"
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $old = (Read-Utf8 $Path) -replace "`r`n", "`n"
    if (-not ($old.Contains($begin) -and $old.Contains($end))) { return '' }
    $head = $old.Substring(0, $old.IndexOf($begin))
    $after = $old.Substring($old.IndexOf($end) + $end.Length).TrimStart("`n")
    $new = $(if ($head.Trim()) { $head.TrimEnd("`n") + "`n" } else { '' }) + $after
    if (-not $DryRun) {
        Copy-Aside $Path
        Write-Utf8 $Path $new
    }
    return 'block removed'
}

function Remove-CodexHook([string]$Package) {
    # Drop our entries out of Codex's hooks.json; every other hook in it stays.
    $notes = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $CodexHookDir -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $CodexHookDir -Filter "$HookPrefix$Package-session-start.*" -File -ErrorAction SilentlyContinue)) {
            if (-not $notes.Contains('files removed')) { [void]$notes.Add('files removed') }
            if (-not $DryRun) { Remove-Item -LiteralPath $f.FullName -Force }
        }
    }

    if (Test-Path -LiteralPath $CodexHooksFile -PathType Leaf) {
        $conf = Read-JsonFile $CodexHooksFile
        if (-not $conf.Contains('hooks')) { return ($notes -join ', ') }
        $changed = $false
        foreach ($event in @($conf['hooks'].Keys)) {
            foreach ($group in @($conf['hooks'][$event])) {
                $keep = New-Object System.Collections.ArrayList
                foreach ($hook in @($group['hooks'])) {
                    if ([string]$hook['command'] -like "*$HookPrefix$Package*") { $changed = $true }
                    else { [void]$keep.Add($hook) }
                }
                $group['hooks'] = $keep.ToArray()
            }
        }
        if ($changed) {
            foreach ($event in @($conf['hooks'].Keys)) {
                $kept = @(@($conf['hooks'][$event]) | Where-Object { @($_['hooks']).Count -gt 0 })
                $conf['hooks'][$event] = $kept
            }
            foreach ($event in @($conf['hooks'].Keys)) {
                if (@($conf['hooks'][$event]).Count -eq 0) { $conf['hooks'].Remove($event) }
            }
            [void]$notes.Add('hooks.json entry removed')
            Write-JsonFile $CodexHooksFile $conf
        }
    }
    return ($notes -join ', ')
}

function Restore-Caveman {
    if (-not (Test-Path -LiteralPath $CavemanStateFile -PathType Leaf)) { return @() }
    $state = Read-JsonFile $CavemanStateFile
    $notes = New-Object System.Collections.ArrayList

    foreach ($pair in @($state['renamed'])) {
        $src = $pair[0]; $off = $pair[1]
        if ((Test-Path -LiteralPath $off -PathType Container) -and -not (Test-Path -LiteralPath $src)) {
            [void]$notes.Add("skill  $src")
            if (-not $DryRun) { Move-Item -LiteralPath $off -Destination $src -Force }
        }
    }

    $entries = @($state['hooks'])
    if ($entries.Count -gt 0 -and (Test-Path -LiteralPath $CodexHooksFile -PathType Leaf)) {
        $conf = Read-JsonFile $CodexHooksFile
        if (-not $conf.Contains('hooks')) { $conf['hooks'] = [ordered]@{} }
        foreach ($pair in $entries) {
            $event = $pair[0]; $hook = $pair[1]
            if (-not $conf['hooks'].Contains($event)) { $conf['hooks'][$event] = @() }
            $groups = New-Object System.Collections.ArrayList
            foreach ($g in @($conf['hooks'][$event])) { [void]$groups.Add($g) }
            $already = $false
            foreach ($g in $groups) {
                foreach ($h in @($g['hooks'])) {
                    if ((ConvertTo-PrettyJson $h) -eq (ConvertTo-PrettyJson $hook)) { $already = $true }
                }
            }
            if ($already) { continue }
            if ($groups.Count -eq 0) { [void]$groups.Add([ordered]@{ matcher = 'startup|resume|clear|compact'; hooks = @() }) }
            $hooks = New-Object System.Collections.ArrayList
            [void]$hooks.Add($hook)
            foreach ($h in @($groups[0]['hooks'])) { [void]$hooks.Add($h) }
            $groups[0]['hooks'] = $hooks.ToArray()
            $conf['hooks'][$event] = $groups.ToArray()
        }
        [void]$notes.Add("hooks  $($entries.Count) entries back in $CodexHooksFile")
        Write-JsonFile $CodexHooksFile $conf
    }

    $block = $state['developer_instructions']
    if ($block -and (Test-Path -LiteralPath $CodexConfig -PathType Leaf)) {
        $text = Read-Utf8 $CodexConfig
        if (-not $text.Contains('developer_instructions')) {
            [void]$notes.Add("config developer_instructions back in $CodexConfig")
            if (-not $DryRun) {
                Copy-Aside $CodexConfig
                Write-Utf8 $CodexConfig ($block + $text)
            }
        }
    }

    if ($state['gemini'] -and (Get-Command gemini -ErrorAction SilentlyContinue)) {
        $ok = $true
        if (-not $DryRun) {
            try { & gemini extensions enable caveman 2>&1 | Out-Null; $ok = ($LASTEXITCODE -eq 0) } catch { $ok = $false }
        }
        [void]$notes.Add($(if ($ok) { 'gemini extension caveman' } else { 'gemini extension caveman -- FAILED, enable it by hand' }))
    }

    if ($notes.Count -gt 0 -and -not $DryRun) { Remove-Item -LiteralPath $CavemanStateFile -Force }
    return @($notes)
}

function Restore-ClaudeSettings {
    # Restore every settings file to its pre-install values from uninstall.json.
    if (-not (Test-Path -LiteralPath $UninstallState -PathType Leaf)) { return @() }
    $state = Read-JsonFile $UninstallState
    if (-not $state.Contains('settings')) { return @() }
    $notes = New-Object System.Collections.ArrayList

    foreach ($path in (@($state['settings'].Keys) | Sort-Object)) {
        $rec = $state['settings'][$path]
        if ($rec.Contains('existed') -and -not $rec['existed']) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                [void]$notes.Add("$path  removed (did not exist before install)")
                if (-not $DryRun) { Copy-Aside $path; Remove-Item -LiteralPath $path -Force }
            }
            continue
        }
        $conf = Read-JsonFile $path
        $new = [ordered]@{}
        foreach ($k in $conf.Keys) { $new[$k] = $conf[$k] }
        foreach ($key in @($rec.Keys)) {
            if ($key -eq 'existed') { continue }
            if ($null -eq $rec[$key]) { $new.Remove($key) } else { $new[$key] = $rec[$key] }
        }
        if ((ConvertTo-PrettyJson $new) -ne (ConvertTo-PrettyJson $conf)) {
            [void]$notes.Add("$path  restored")
            Write-JsonFile $path $new
        }
    }

    $style = Join-Path $ClaudeOutputStyles 'shut.md'
    if (Test-Path -LiteralPath $style -PathType Leaf) {
        [void]$notes.Add('output-styles/shut.md  removed')
        if (-not $DryRun) { Remove-Item -LiteralPath $style -Force }
    }
    if ($notes.Count -gt 0 -and -not $DryRun) { Remove-Item -LiteralPath $UninstallState -Force }
    return @($notes)
}


# ----------------------------------------------------------------- main

if ((Test-Path -LiteralPath $LegacyState -PathType Leaf) -and -not (Test-Path -LiteralPath $UninstallState -PathType Leaf)) {
    New-Item -ItemType Directory -Path $Backups -Force | Out-Null
    Move-Item -LiteralPath $LegacyState -Destination $UninstallState -Force
}

$tag = if ($DryRun) { ' (dry run)' } else { '' }
$touched = $false

"Skills$tag"
foreach ($entry in $SkillDirs) {
    foreach ($pkg in $Packages) {
        $note = Remove-Skill (Join-Path $entry.Path $pkg)
        if ($note) { $touched = $true; '  {0,-10} {1,-8} {2}' -f $entry.Name, $pkg, $note }
    }
}

"Hooks$tag"
foreach ($pkg in $Packages) {
    $note = Remove-CodexHook $pkg
    if ($note) { $touched = $true; '  {0,-10} {1,-8} {2}' -f 'codex', $pkg, $note }
}

"Always-on rule$tag"
foreach ($entry in $AlwaysOn) {
    foreach ($pkg in $Packages) {
        $note = Remove-Graft $entry.Path $pkg
        if ($note) { $touched = $true; '  {0,-10} {1,-8} {2}  {3}' -f $entry.Name, $pkg, $note, $entry.Path }
    }
}

"Claude settings$tag"
$notes = Restore-ClaudeSettings
foreach ($n in $notes) { $touched = $true; '  {0,-10} {1}' -f 'claude', $n }
if ($notes.Count -eq 0) { '  {0,-10} unchanged' -f 'claude' }

if (-not $KeepCavemanOff) {
    "Caveman$tag"
    $notes = Restore-Caveman
    foreach ($n in $notes) { $touched = $true; "  restored  $n" }
    if ($notes.Count -eq 0) { '  nothing to put back' }
}

if (-not $touched) {
    ''
    'Nothing found. Nothing removed.'
} else {
    ''
    'Backups of every edited file are alongside it as *.bak-uninstall.'
}
