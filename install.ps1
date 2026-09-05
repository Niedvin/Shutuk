<#
.SYNOPSIS
    Install CCShut and BeQuiet into every agent on this machine that reads skills.

.DESCRIPTION
    The PowerShell twin of install.py. Needs nothing but Windows PowerShell 5.1, which
    ships with Windows 10 and 11. The zips are looked for next to this file first, then
    in the current directory.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1 -DryRun
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$List,
    [string]$Only = '',
    [string]$Skip = '',
    [switch]$NoAlwaysOn,
    [switch]$NoHooks,
    [switch]$KeepCaveman
)

$ErrorActionPreference = 'Stop'

$UserHome  = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }
$Here      = Split-Path -Parent $PSCommandPath
$Marker    = '.shut-install.json'
$Backups   = Join-Path $UserHome '.shut-backups'
$CavemanStateFile = Join-Path $Backups 'caveman-state.json'
$HookPrefix = 'shut-'
$OutputStyle = 'Shut'
$ScanDepth = 4

$ClaudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $UserHome '.claude' }
$ClaudeOutputStyles = Join-Path $ClaudeHome 'output-styles'

$PackageZips = [ordered]@{ ccshut = 'CCShut.zip'; bequiet = 'BeQuiet.zip' }

# Read by the installers only; a Claude Code plugin has no use for them — 2026-09-05
$InstallerOnly = @('manifest.json', 'always-on.md', 'flat')

$CodexHooksFile = Join-Path $UserHome '.codex\hooks.json'
$CodexHookDir   = Join-Path $UserHome '.codex\hooks'
$CodexConfig    = Join-Path $UserHome '.codex\config.toml'

# State lives outside the repo so a clone stays clean and `git pull` cannot clobber it — 2026-09-05
$UninstallState = Join-Path $Backups 'uninstall.json'
$LegacyState    = Join-Path $Here 'uninstall.json'

$ClaudeEnv = [ordered]@{
    CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'
    CLAUDE_CODE_ENABLE_AWAY_SUMMARY      = '0'
}

# probe: the agent is installed if any of these exist. form: how a skill is laid out there.
$Targets = @(
    [pscustomobject]@{ Name = 'claude'; Form = 'plugin'
        Probes = @($ClaudeHome); Dest = (Join-Path $ClaudeHome 'skills') }
    [pscustomobject]@{ Name = 'agents'; Form = 'flat'
        Probes = @((Join-Path $UserHome '.agents'), (Join-Path $UserHome '.codex'),
                   (Join-Path $UserHome '.config\opencode'))
        Dest = (Join-Path $UserHome '.agents\skills') }
    [pscustomobject]@{ Name = 'codex'; Form = 'flat'
        Probes = @((Join-Path $UserHome '.codex')); Dest = (Join-Path $UserHome '.codex\skills') }
    [pscustomobject]@{ Name = 'opencode'; Form = 'flat'
        Probes = @((Join-Path $UserHome '.config\opencode'), (Join-Path $UserHome '.opencode'))
        Dest = (Join-Path $UserHome '.config\opencode\skills') }
    [pscustomobject]@{ Name = 'cursor'; Form = 'flat'
        Probes = @((Join-Path $UserHome '.cursor')); Dest = (Join-Path $UserHome '.cursor\skills-cursor') }
    [pscustomobject]@{ Name = 'gemini'; Form = 'flat'
        Probes = @((Join-Path $UserHome '.gemini')); Dest = (Join-Path $UserHome '.gemini\skills') }
)

# Skills load on demand; these files are read every session, so the rule holds without a trigger.
# Claude Code is absent on purpose: its SessionStart hook already injects the same text.
$AlwaysOn = @(
    [pscustomobject]@{ Name = 'codex';    Path = (Join-Path $UserHome '.codex\AGENTS.md') }
    [pscustomobject]@{ Name = 'opencode'; Path = (Join-Path $UserHome '.config\opencode\AGENTS.md') }
    [pscustomobject]@{ Name = 'gemini';   Path = (Join-Path $UserHome '.gemini\GEMINI.md') }
)

$CavemanDirs = @('caveman', 'caveman-*', 'cavecrew')

# Directory names that are never worth descending into, whatever machine this runs on.
$ScanSkip = @(
    'appdata', 'application data', 'local settings', 'cookies', 'temp',
    'program files', 'program files (x86)', 'programs', 'programdata', 'windows',
    'windows.old', 'windowsapps', 'winsxs', 'system32', 'syswow64',
    'common files', 'internet explorer', 'microsoft', 'boot', 'recovery',
    'perflogs', 'msocache', 'intel', 'amd', 'nvidia', 'drivers',
    'system volume information', '$recycle.bin', 'documents and settings',
    'onedrive', 'onedrivetemp',
    'library', 'obj', 'bin', 'builds', 'build', 'dist', 'logs', 'packages',
    'target', 'site-packages', 'dist-packages', 'scripts',
    'node_modules', '__pycache__', 'venv', '.venv', '.cargo', '.npm', '.nuget',
    'python27', 'python36', 'python37', 'python38', 'python39',
    'python310', 'python311', 'python312', 'python313'
)


# ----------------------------------------------------------------- small helpers

function Get-Stamp { (Get-Date).ToString('yyyyMMdd-HHmmss') }

function Write-Utf8([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Utf8([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

function Backup-One([string]$Path) {
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $DryRun) {
        Copy-Item -LiteralPath $Path -Destination "$Path.bak-$(Get-Stamp)" -Force
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

# Hand-rolled: ConvertTo-Json in 5.1 caps depth, aligns instead of indenting, and \u-escapes — 2026-09-05
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
    Backup-One $Path
    Write-Utf8 $Path ((ConvertTo-PrettyJson $Data) + "`n")
}

function Test-Empty($Value) { return ($null -eq $Value) -or ($Value -is [string] -and $Value -eq '') }


# ----------------------------------------------------------------- the one dialog

function Show-Nag([string[]]$MissingNames) {
    $text = 'No ' + ($MissingNames -join '\') + '. Where?'
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $form = New-Object Windows.Forms.Form
        $form.Text = 'Shut'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.StartPosition = 'CenterScreen'
        $form.ClientSize = New-Object Drawing.Size(380, 130)
        $label = New-Object Windows.Forms.Label
        $label.Text = $text
        $label.AutoSize = $false
        $label.TextAlign = 'MiddleCenter'
        $label.Font = New-Object Drawing.Font('Segoe UI', 11)
        $label.SetBounds(20, 20, 340, 40)
        $button = New-Object Windows.Forms.Button
        $button.Text = 'Where?'
        $button.SetBounds(140, 78, 100, 30)
        $button.Add_Click({ $form.Close() })
        $form.Controls.AddRange(@($label, $button))
        $form.AcceptButton = $button
        $form.CancelButton = $button
        [void]$form.ShowDialog()
    } catch {
        [Console]::Error.WriteLine($text)
    }
}


# ----------------------------------------------------------------- packages

function Get-Detected {
    $found = foreach ($t in $Targets) {
        $hit = $false
        foreach ($p in $t.Probes) { if (Test-Path -LiteralPath $p) { $hit = $true; break } }
        if ($hit) { $t }
    }
    return @($found)
}

function Expand-Packages([string]$Temp) {
    $found = [ordered]@{}
    $missing = New-Object System.Collections.ArrayList
    foreach ($name in $PackageZips.Keys) {
        $loose = $null
        foreach ($dir in @($Here, (Get-Location).Path)) {
            $candidate = Join-Path (Join-Path $dir 'plugins') $name
            if (Test-Path -LiteralPath (Join-Path $candidate 'manifest.json') -PathType Leaf) { $loose = $candidate; break }
        }
        if ($loose) { $found[$name] = $loose; continue }

        $archive = $null
        foreach ($dir in @((Join-Path $Here 'dist'), $Here, (Get-Location).Path)) {
            $candidate = Join-Path $dir $PackageZips[$name]
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $archive = $candidate; break }
        }
        if (-not $archive) { [void]$missing.Add($PackageZips[$name]); continue }
        # The zip's root is the plugin itself, so Claude Desktop takes it as a drag-and-drop.
        Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $Temp $name) -Force
        $found[$name] = Join-Path $Temp $name
    }
    if ($missing.Count -gt 0) {
        Show-Nag $missing.ToArray()
        exit 1
    }
    return $found
}

function Install-Package([string]$Source, [string]$Dest, [string]$Form) {
    $note = 'installed'
    if (Test-Path -LiteralPath $Dest) {
        if (Test-Path -LiteralPath (Join-Path $Dest $Marker) -PathType Leaf) {
            $note = 'updated'
            if (-not $DryRun) { Remove-Item -LiteralPath $Dest -Recurse -Force }
        } else {
            # Outside the skills tree on purpose: a backup left inside it loads as a second plugin.
            $backup = Join-Path $Backups ('{0}-{1}-{2}' -f (Split-Path -Leaf (Split-Path -Parent $Dest)), (Split-Path -Leaf $Dest), (Get-Stamp))
            $note = "replaced (yours saved to $backup)"
            if (-not $DryRun) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
                Move-Item -LiteralPath $Dest -Destination $backup -Force
            }
        }
    }
    if ($DryRun) { return $note }

    New-Item -ItemType Directory -Path (Split-Path -Parent $Dest) -Force | Out-Null
    if ($Form -eq 'plugin') {
        Copy-Item -LiteralPath $Source -Destination $Dest -Recurse -Force
        foreach ($name in $InstallerOnly) {
            $extra = Join-Path $Dest $name
            if (Test-Path -LiteralPath $extra) { Remove-Item -LiteralPath $extra -Recurse -Force }
        }
    } else {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $Source 'flat\SKILL.md') -Destination (Join-Path $Dest 'SKILL.md') -Force
        Copy-Item -LiteralPath (Join-Path $Source 'README.md') -Destination (Join-Path $Dest 'README.md') -Force
    }

    $manifest = Read-JsonFile (Join-Path $Source 'manifest.json')
    Write-Utf8 (Join-Path $Dest $Marker) ((ConvertTo-PrettyJson ([ordered]@{
        package      = $manifest['name']
        version      = $manifest['version']
        form         = $Form
        installed_at = (Get-Date).ToString('s')
    })) + "`n")
    return $note
}


# ----------------------------------------------------------------- always-on text

function Set-Graft([string]$Path, [string]$Name, [string]$Version, [string]$Body) {
    $begin = "<!-- shut:${Name}:begin -->"
    $end   = "<!-- shut:${Name}:end -->"
    $block = "$begin`n<!-- managed by Shut, v$Version. Edits here are overwritten. -->`n`n" +
             $Body.Trim() + "`n`n$end`n"
    $old = (Read-Utf8 $Path) -replace "`r`n", "`n"

    if ($old.Contains($begin) -and $old.Contains($end)) {
        $head = $old.Substring(0, $old.IndexOf($begin))
        $after = $old.Substring($old.IndexOf($end) + $end.Length).TrimStart("`n")
        $new = $head + $block + $(if ($after.Trim()) { "`n" + $after } else { '' })
    } else {
        $new = $(if ($old.Trim()) { $old.TrimEnd("`n") + "`n`n" } else { '' }) + $block
    }
    if ($new -eq $old) { return 'unchanged' }
    if (-not $DryRun) {
        Backup-One $Path
        Write-Utf8 $Path $new
    }
    if ($old.Contains($begin)) { return 'refreshed' } else { return 'added' }
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
        Backup-One $Path
        Write-Utf8 $Path $new
    }
    return 'removed (the hook carries it)'
}


# ----------------------------------------------------------------- Codex hooks

function Set-CodexHook([string]$Package, [string]$Body) {
    # Codex takes Claude Code's hook schema, so the payload is the same JSON on stdout.
    $payload  = Join-Path $CodexHookDir "$HookPrefix$Package-session-start.json"
    $launcher = Join-Path $CodexHookDir "$HookPrefix$Package-session-start.cmd"
    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $CodexHookDir -Force | Out-Null
        Write-Utf8 $payload ((ConvertTo-PrettyJson ([ordered]@{
            hookSpecificOutput = [ordered]@{
                hookEventName     = 'SessionStart'
                additionalContext = $Body.Trim()
            }
        })) + "`n")
        [System.IO.File]::WriteAllText($launcher,
            "@echo off`r`ntype `"%~dp0$(Split-Path -Leaf $payload)`"`r`n",
            (New-Object System.Text.UTF8Encoding($false)))
    }

    $conf = Read-JsonFile $CodexHooksFile
    if (-not $conf.Contains('hooks')) { $conf['hooks'] = [ordered]@{} }
    if (-not $conf['hooks'].Contains('SessionStart')) { $conf['hooks']['SessionStart'] = @() }
    $groups = New-Object System.Collections.ArrayList
    foreach ($g in @($conf['hooks']['SessionStart'])) { [void]$groups.Add($g) }

    $entry = [ordered]@{ type = 'command'; command = $launcher; timeout = 5; statusMessage = "Loading $Package" }
    $entryJson = ConvertTo-PrettyJson $entry
    $placed = $false
    foreach ($group in $groups) {
        $hooks = New-Object System.Collections.ArrayList
        foreach ($h in @($group['hooks'])) { [void]$hooks.Add($h) }
        for ($i = 0; $i -lt $hooks.Count; $i++) {
            if ([string]$hooks[$i]['command'] -like "*$HookPrefix$Package*") {
                if ((ConvertTo-PrettyJson $hooks[$i]) -eq $entryJson) { return 'unchanged' }
                $hooks[$i] = $entry
                $group['hooks'] = $hooks.ToArray()
                $placed = $true
                break
            }
        }
        if ($placed) { break }
    }
    if (-not $placed) {
        $target = $null
        foreach ($group in $groups) { if ([string]$group['matcher'] -like 'startup*') { $target = $group; break } }
        if (-not $target) {
            $target = [ordered]@{ matcher = 'startup|resume|clear|compact'; hooks = @() }
            [void]$groups.Add($target)
        }
        $hooks = New-Object System.Collections.ArrayList
        foreach ($h in @($target['hooks'])) { [void]$hooks.Add($h) }
        [void]$hooks.Add($entry)
        $target['hooks'] = $hooks.ToArray()
    }
    $conf['hooks']['SessionStart'] = $groups.ToArray()
    Write-JsonFile $CodexHooksFile $conf
    return 'hook added'
}

function Get-CodexHooksFeature {
    # `hooks` defaults on since 2026; the key only exists to turn them off.
    if (-not (Test-Path -LiteralPath $CodexConfig -PathType Leaf)) { return '' }
    if ((Read-Utf8 $CodexConfig) -match '(?m)^\s*hooks\s*=\s*false') {
        return 'OFF -- set [features] hooks = true in config.toml or the hook will not run'
    }
    return 'on'
}

function Test-CodexHooksTrusted {
    # Codex skips a new or changed hook until it is trusted; /hooks in Codex does that.
    if (-not ((Test-Path -LiteralPath $CodexConfig -PathType Leaf) -and (Test-Path -LiteralPath $CodexHooksFile -PathType Leaf))) { return $false }
    $config = Read-Utf8 $CodexConfig
    $conf = Read-JsonFile $CodexHooksFile
    if (-not $conf.Contains('hooks')) { return $false }
    if (-not $conf['hooks'].Contains('SessionStart')) { return $false }
    $groups = @($conf['hooks']['SessionStart'])
    for ($gi = 0; $gi -lt $groups.Count; $gi++) {
        $hooks = @($groups[$gi]['hooks'])
        for ($hi = 0; $hi -lt $hooks.Count; $hi++) {
            if ([string]$hooks[$hi]['command'] -notlike "*$HookPrefix*") { continue }
            if (-not $config.Contains("hooks.json:session_start:${gi}:${hi}")) { return $false }
        }
    }
    return $true
}


# ----------------------------------------------------------------- Claude settings

function Get-ScanRoots {
    # HOME plus every fixed local drive; removable and network drives are skipped.
    $roots = New-Object System.Collections.ArrayList
    [void]$roots.Add($UserHome)
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -eq [System.IO.DriveType]::Fixed -and $drive.IsReady) {
            [void]$roots.Add($drive.RootDirectory.FullName)
        }
    }
    return $roots.ToArray()
}

function Get-ClaudeDirs {
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add($ClaudeHome)
    foreach ($root in (Get-ScanRoots)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@{ Path = $root; Depth = 0 })
        while ($queue.Count -gt 0) {
            $item = $queue.Dequeue()
            try { $kids = [System.IO.Directory]::GetDirectories($item.Path) } catch { continue }
            foreach ($kid in $kids) {
                $name = Split-Path -Leaf $kid
                if ($name -eq '.claude') { [void]$out.Add($kid); continue }
                if ($item.Depth -ge $ScanDepth) { continue }
                if ($name.StartsWith('.')) { continue }
                if ($ScanSkip -contains $name.ToLowerInvariant()) { continue }
                $queue.Enqueue(@{ Path = $kid; Depth = $item.Depth + 1 })
            }
        }
    }
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $uniq = New-Object System.Collections.ArrayList
    foreach ($dir in $out) {
        $key = try { [System.IO.Path]::GetFullPath($dir).ToLowerInvariant() } catch { $dir.ToLowerInvariant() }
        if ($seen.Add($key)) { [void]$uniq.Add($dir) }
    }
    return ($uniq.ToArray() | Sort-Object)
}

function Get-State {
    if (Test-Path -LiteralPath $UninstallState -PathType Leaf) { return Read-JsonFile $UninstallState }
    return [ordered]@{}
}

function Save-State($State) {
    if ($DryRun) { return }
    New-Item -ItemType Directory -Path $Backups -Force | Out-Null
    Write-Utf8 $UninstallState ((ConvertTo-PrettyJson $State) + "`n")
}

function Set-ClaudeSettings {
    <#
      `language` is not set and is actively removed: any value injects an "Always respond in
      <lang>" block covering all explanations, which overrides bequiet's English-label /
      Ukrainian-answer split whichever language it names.
    #>
    $notes = New-Object System.Collections.ArrayList
    $state = Get-State
    if (-not $state.Contains('settings')) { $state['settings'] = [ordered]@{} }
    $recorded = $state['settings']

    foreach ($dir in (Get-ClaudeDirs)) {
        $isGlobal = ([System.IO.Path]::GetFullPath($dir).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($ClaudeHome).TrimEnd('\'))
        $label = if ($isGlobal) { 'claude' } else { Split-Path -Leaf (Split-Path -Parent $dir) }
        if ($isGlobal) {
            $plan = @(
                @{ Path = (Join-Path $dir 'settings.json');       Keys = @('env') }
                @{ Path = (Join-Path $dir 'settings.local.json'); Keys = @('outputStyle') }
            )
        } else {
            $plan = @(@{ Path = (Join-Path $dir 'settings.local.json'); Keys = @('env', 'outputStyle') })
        }

        foreach ($step in $plan) {
            $path = $step.Path
            if (-not $recorded.Contains($path)) { $recorded[$path] = [ordered]@{} }
            $rec = $recorded[$path]
            if (-not $rec.Contains('existed')) { $rec['existed'] = (Test-Path -LiteralPath $path -PathType Leaf) }
            $conf = Read-JsonFile $path
            $new = [ordered]@{}
            foreach ($k in $conf.Keys) { $new[$k] = $conf[$k] }
            $changed = New-Object System.Collections.ArrayList

            foreach ($key in $step.Keys) {
                if (-not $rec.Contains($key)) { $rec[$key] = $(if ($conf.Contains($key)) { $conf[$key] } else { $null }) }
                if ($key -eq 'env') {
                    $env = [ordered]@{}
                    if ($conf.Contains('env') -and $conf['env'] -is [System.Collections.IDictionary]) {
                        foreach ($k in $conf['env'].Keys) { $env[$k] = $conf['env'][$k] }
                    }
                    $envChanged = $false
                    foreach ($k in $ClaudeEnv.Keys) {
                        if (-not $env.Contains($k) -or [string]$env[$k] -ne $ClaudeEnv[$k]) { $envChanged = $true }
                        $env[$k] = $ClaudeEnv[$k]
                    }
                    if ($envChanged) { [void]$changed.Add('env'); $new['env'] = $env }
                } else {
                    $before = $(if ($conf.Contains($key)) { $conf[$key] } else { $null })
                    if ([string]$before -ne $OutputStyle) { [void]$changed.Add($key); $new[$key] = $OutputStyle }
                }
            }
            if ($conf.Contains('language')) {
                if (-not $rec.Contains('language')) { $rec['language'] = $conf['language'] }
                $new.Remove('language')
                [void]$changed.Add('language dropped')
            }
            if ($changed.Count -gt 0) {
                [void]$notes.Add(@{ Label = $label; Detail = ("{0}  {1}" -f ($changed -join ', '), $path) })
                Write-JsonFile $path $new
            }
            Save-State $state
        }
    }

    $style = Join-Path $Here 'shut.md'
    if (Test-Path -LiteralPath $style -PathType Leaf) {
        $dest = Join-Path $ClaudeOutputStyles 'shut.md'
        $same = (Test-Path -LiteralPath $dest -PathType Leaf) -and
                ((Get-FileHash -LiteralPath $style).Hash -eq (Get-FileHash -LiteralPath $dest).Hash)
        if (-not $same) {
            [void]$notes.Add(@{ Label = 'claude'; Detail = 'output-styles/shut.md  installed' })
            if (-not $DryRun) {
                New-Item -ItemType Directory -Path $ClaudeOutputStyles -Force | Out-Null
                Copy-Item -LiteralPath $style -Destination $dest -Force
            }
        }
    }
    return @($notes)
}


# ----------------------------------------------------------------- caveman

function Get-CavemanTargets {
    $out = New-Object System.Collections.ArrayList
    foreach ($t in $Targets) {
        if (-not (Test-Path -LiteralPath $t.Dest -PathType Container)) { continue }
        foreach ($pattern in $CavemanDirs) {
            foreach ($dir in @(Get-ChildItem -LiteralPath $t.Dest -Directory -Filter $pattern -ErrorAction SilentlyContinue)) {
                [void]$out.Add($dir.FullName)
            }
        }
    }
    return ($out.ToArray() | Sort-Object -Unique)
}

function Disable-Caveman {
    # Caveman rewrites every reply too; two compressors fighting is not a defined state.
    $state = [ordered]@{
        disabled_at = (Get-Date).ToString('s')
        renamed = @(); hooks = @(); developer_instructions = $null; gemini = $false
    }
    $notes = New-Object System.Collections.ArrayList
    $renamed = New-Object System.Collections.ArrayList
    $lifted  = New-Object System.Collections.ArrayList

    # Written after every step: a crash later must still leave uninstall able to undo this.
    $save = {
        if ($DryRun) { return }
        New-Item -ItemType Directory -Path $Backups -Force | Out-Null
        $state['renamed'] = $renamed.ToArray()
        $state['hooks']   = $lifted.ToArray()
        Write-Utf8 $CavemanStateFile ((ConvertTo-PrettyJson $state) + "`n")
    }

    foreach ($dir in (Get-CavemanTargets)) {
        $off = "$dir.off-by-shut"
        [void]$notes.Add("skill  $dir")
        [void]$renamed.Add(@($dir, $off))
        & $save
        if (-not $DryRun) { Move-Item -LiteralPath $dir -Destination $off -Force }
    }

    if (Test-Path -LiteralPath $CodexHooksFile -PathType Leaf) {
        $conf = Read-JsonFile $CodexHooksFile
        if ($conf.Contains('hooks')) {
            $changed = $false
            foreach ($event in @($conf['hooks'].Keys)) {
                foreach ($group in @($conf['hooks'][$event])) {
                    $keep = New-Object System.Collections.ArrayList
                    foreach ($hook in @($group['hooks'])) {
                        if ([string]$hook['command'] -match '(?i)caveman') {
                            [void]$lifted.Add(@($event, $hook)); $changed = $true
                        } else { [void]$keep.Add($hook) }
                    }
                    $group['hooks'] = $keep.ToArray()
                }
            }
            if ($changed) {
                [void]$notes.Add("hooks  $($lifted.Count) caveman entries in $CodexHooksFile")
                & $save
                Write-JsonFile $CodexHooksFile $conf
            }
        }
    }

    if (Test-Path -LiteralPath $CodexConfig -PathType Leaf) {
        $text = Read-Utf8 $CodexConfig
        $m = [regex]::Match($text, '(?ms)^developer_instructions\s*=\s*"""(.*?)"""\s*\n')
        if ($m.Success -and $m.Groups[1].Value -match '(?i)caveman') {
            $state['developer_instructions'] = $m.Value
            [void]$notes.Add("config developer_instructions in $CodexConfig")
            & $save
            if (-not $DryRun) {
                Backup-One $CodexConfig
                Write-Utf8 $CodexConfig ($text.Remove($m.Index, $m.Length))
            }
        }
    }

    $geminiExt = Join-Path $UserHome '.gemini\extensions\caveman'
    if ((Test-Path -LiteralPath $geminiExt -PathType Container) -and (Get-Command gemini -ErrorAction SilentlyContinue)) {
        $state['gemini'] = $true
        & $save
        $done = $DryRun
        if (-not $DryRun) {
            try { & gemini extensions disable caveman 2>&1 | Out-Null; $done = ($LASTEXITCODE -eq 0) } catch { $done = $false }
        }
        [void]$notes.Add($(if ($done) { 'gemini extension caveman' } else { 'gemini extension caveman -- FAILED, disable it by hand' }))
        if (-not $done) { $state['gemini'] = $false; & $save }
    }

    return @($notes)
}

function Get-CavemanProse {
    # Hand-written mentions. Left alone: they are the user's own text, not a mechanism.
    $files = @(
        (Join-Path $ClaudeHome 'CLAUDE.md'), (Join-Path $UserHome '.codex\AGENTS.md'),
        (Join-Path $UserHome '.config\opencode\AGENTS.md'), (Join-Path $UserHome '.gemini\GEMINI.md')
    )
    return @($files | Where-Object { (Test-Path -LiteralPath $_ -PathType Leaf) -and ((Read-Utf8 $_) -match '(?i)caveman') })
}


# ----------------------------------------------------------------- main

if ((Test-Path -LiteralPath $LegacyState -PathType Leaf) -and -not (Test-Path -LiteralPath $UninstallState -PathType Leaf)) {
    New-Item -ItemType Directory -Path $Backups -Force | Out-Null
    Move-Item -LiteralPath $LegacyState -Destination $UninstallState -Force
}

$agents = Get-Detected
$onlySet = @($Only -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$skipSet = @($Skip -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($onlySet.Count -gt 0) { $agents = @($agents | Where-Object { $onlySet -contains $_.Name }) }
if ($skipSet.Count -gt 0) { $agents = @($agents | Where-Object { $skipSet -notcontains $_.Name }) }

if ($List) {
    foreach ($a in $agents) { '{0,-10} {1,-7} {2}' -f $a.Name, $a.Form, $a.Dest }
    exit 0
}
if ($agents.Count -eq 0) {
    [Console]::Error.WriteLine('no agents found. Nothing to install.')
    exit 1
}

$wanted = @($agents | ForEach-Object { $_.Name })
$tag = if ($DryRun) { ' (dry run)' } else { '' }
$trailer = New-Object System.Collections.ArrayList

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("shut-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $src = Expand-Packages $temp
    $bodies = [ordered]@{}
    $versions = [ordered]@{}
    foreach ($pkg in $src.Keys) {
        $bodies[$pkg] = Read-Utf8 (Join-Path $src[$pkg] 'always-on.md')
        $versions[$pkg] = (Read-JsonFile (Join-Path $src[$pkg] 'manifest.json'))['version']
    }

    "Skills$tag"
    foreach ($a in $agents) {
        foreach ($pkg in $src.Keys) {
            '  {0,-10} {1,-8} {2}' -f $a.Name, $pkg, (Install-Package $src[$pkg] (Join-Path $a.Dest $pkg) $a.Form)
        }
    }

    $hooked = @()
    if (-not $NoHooks -and $wanted -contains 'codex') {
        "Hooks$tag"
        $feature = Get-CodexHooksFeature
        foreach ($pkg in $src.Keys) { '  {0,-10} {1,-8} {2}' -f 'codex', $pkg, (Set-CodexHook $pkg $bodies[$pkg]) }
        if ($feature -and $feature -ne 'on') { '  {0,-10} {1,-8} {2}' -f 'codex', 'features', $feature }
        if (Test-CodexHooksTrusted) {
            $hooked = @('codex')
            '  {0,-10} {1,-8} {2}' -f 'codex', 'trust', 'trusted, the hook runs'
        } else {
            '  {0,-10} {1,-8} {2}' -f 'codex', 'trust', 'NOT trusted yet -- AGENTS.md block stays'
            [void]$trailer.Add('Codex skips a hook until you trust it: run /hooks inside Codex, trust the two `shut-` entries, then run install.ps1 again to drop the duplicate AGENTS.md block.')
        }
    }

    if (-not $NoAlwaysOn) {
        "Always-on rule$tag"
        foreach ($entry in $AlwaysOn) {
            if ($wanted -notcontains $entry.Name) { continue }
            if (-not (Test-Path -LiteralPath (Split-Path -Parent $entry.Path) -PathType Container)) { continue }
            foreach ($pkg in $src.Keys) {
                # A trusted hook and a block would inject the same text twice, every session.
                $note = if ($hooked -contains $entry.Name) { Remove-Graft $entry.Path $pkg }
                        else { Set-Graft $entry.Path $pkg $versions[$pkg] $bodies[$pkg] }
                if ($note) { '  {0,-10} {1,-8} {2}  {3}' -f $entry.Name, $pkg, $note, $entry.Path }
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($wanted -contains 'claude') {
    "Claude settings$tag"
    $notes = Set-ClaudeSettings
    foreach ($n in $notes) { '  {0,-10} {1}' -f $n.Label, $n.Detail }
    if ($notes.Count -eq 0) { '  {0,-10} unchanged' -f 'claude' }
}

if (-not $KeepCaveman) {
    "Caveman$tag"
    $notes = Disable-Caveman
    foreach ($n in $notes) { "  disabled  $n" }
    if ($notes.Count -eq 0) { '  not installed' }
    $prose = Get-CavemanProse
    if ($prose.Count -gt 0) {
        '  left alone (your own text, not a mechanism):'
        foreach ($f in $prose) { "      $f" }
        [void]$trailer.Add('Those files still tell the agent to use /caveman for commits and docs. Remove those lines yourself if you want caveman fully gone.')
    }
}

''
'Claude Code and Codex pick it up at the next /clear or restart; the rest next session.'
foreach ($line in $trailer) { ''; "! $line" }
''
'Remove it all with: powershell -ExecutionPolicy Bypass -File uninstall.ps1'
