param(
    [Parameter(Mandatory = $true)]
    [string] $GamePath
)

$ErrorActionPreference = 'Stop'
$AppId = 2432110
$AllowedPaths = @(
    'WHITE ALBUM Memories like Falling Snow.exe',
    'Data/Game/ENG/AlbumModeParts.pck',
    'Data/Game/ENG/Caution_autosave.tex',
    'Data/Game/ENG/CautionParts.tex',
    'Data/Game/ENG/Font.pck',
    'Data/Game/ENG/GameParts.tex',
    'Data/Game/ENG/GuideParts.tex',
    'Data/Game/ENG/MouseSelect.tex',
    'Data/Game/ENG/MoveSelectParts.tex',
    'Data/Game/ENG/MovieReplayParts.tex',
    'Data/Game/ENG/MusicModeParts.tex',
    'Data/Game/ENG/OptionParts.tex',
    'Data/Game/ENG/SaveLoad.tex',
    'Data/Game/ENG/Script.sdat',
    'Data/Game/ENG/TitleParts.tex',
    'Data/Game/ENG/VoiceMessageParts.pck'
)

function Get-Sha256([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-SafePath([string] $Root, [string] $RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.Contains('\') -or
        $RelativePath.StartsWith('/') -or $RelativePath -match '(^|/)\.\.?(/|$)' -or
        [System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Unsafe manifest path: $RelativePath"
    }
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFull ($RelativePath.Replace('/', '\'))))
    $prefix = $rootFull + '\'
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest path escapes its root: $RelativePath"
    }
    return $candidate
}

function Read-Manifest {
    $manifestPath = Join-Path $PSScriptRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'manifest.json is missing.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.app_id -ne $AppId) { throw "This patch targets Steam App ID $AppId." }
    if ($manifest.version -notmatch '^[A-Za-z0-9._-]+$') { throw 'Invalid patch version in manifest.' }
    $rows = @($manifest.files)
    if ($rows.Count -ne $AllowedPaths.Count) { throw 'Manifest file list does not match the approved allowlist.' }
    for ($i = 0; $i -lt $AllowedPaths.Count; $i++) {
        if ($rows[$i].path -cne $AllowedPaths[$i]) { throw "Unexpected manifest file at position $i." }
        if ($rows[$i].original_sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
            $rows[$i].payload_sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
            [long]$rows[$i].original_size -lt 0 -or [long]$rows[$i].payload_size -lt 0) {
            throw "Invalid hash or size in manifest for $($rows[$i].path)."
        }
        if ($rows[$i].original_sha256 -eq $rows[$i].payload_sha256) {
            throw "Manifest marks an unchanged file as localized: $($rows[$i].path)."
        }
    }
    return ,$rows
}

function Test-FileRecord([string] $Path, $Record, [string] $Prefix) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $size = if ($Prefix -eq 'original') { [long]$Record.original_size } else { [long]$Record.payload_size }
    $hash = if ($Prefix -eq 'original') { [string]$Record.original_sha256 } else { [string]$Record.payload_sha256 }
    return ((Get-Item -LiteralPath $Path).Length -eq $size -and (Get-Sha256 $Path) -eq $hash.ToLowerInvariant())
}

function Replace-FromFile([string] $Source, [string] $Destination) {
    $parent = Split-Path -Parent $Destination
    $temporary = Join-Path $parent ('.ua-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    Copy-Item -LiteralPath $Source -Destination $temporary
    try {
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

$gameRoot = [System.IO.Path]::GetFullPath($GamePath)
if (-not (Test-Path -LiteralPath $gameRoot -PathType Container)) { throw "Game folder does not exist: $gameRoot" }
if (-not (Test-Path -LiteralPath (Join-Path $gameRoot 'WHITE ALBUM Memories like Falling Snow.exe') -PathType Leaf)) {
    throw 'The selected folder is missing the WHITE ALBUM game executable.'
}
$steamApps = Split-Path -Parent (Split-Path -Parent $gameRoot)
$appManifest = Join-Path $steamApps "appmanifest_$AppId.acf"
if (Test-Path -LiteralPath $appManifest -PathType Leaf) {
    $appText = Get-Content -LiteralPath $appManifest -Raw
    if ($appText -notmatch ('"appid"\s+"' + $AppId + '"')) { throw 'Steam appmanifest does not match this game.' }
}

$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$rows = Read-Manifest
$backupPath = Join-Path (Join-Path $gameRoot '.white-album-ua-backup') ([string]$manifest.version)
if (-not (Test-Path -LiteralPath $backupPath -PathType Container)) { throw "Original backup is missing: $backupPath" }
$stageRoot = Join-Path $gameRoot ('.white-album-ua-stage-' + [Guid]::NewGuid().ToString('N'))
$stageCreated = $false
$touched = New-Object 'System.Collections.Generic.List[object]'

try {
    $currentStates = @()
    foreach ($row in $rows) {
        $target = Get-SafePath $gameRoot ([string]$row.path)
        $backup = Get-SafePath $backupPath ([string]$row.path)
        if (-not (Test-FileRecord $backup $row 'original')) { throw "Original backup is missing or invalid: $($row.path)" }
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Game file is missing: $($row.path)" }
        $isOriginal = Test-FileRecord $target $row 'original'
        $isPatched = Test-FileRecord $target $row 'payload'
        if (-not $isOriginal -and -not $isPatched) { throw "Game file has changed since installation: $($row.path)" }
        $currentStates += [pscustomobject]@{ Row = $row; Target = $target; IsOriginal = $isOriginal; IsPatched = $isPatched }

        $payload = Get-SafePath (Join-Path $PSScriptRoot 'payload') ([string]$row.path)
        if (-not (Test-FileRecord $payload $row 'payload')) { throw "Patch payload is missing or invalid: $($row.path)" }
    }
    $allOriginal = $true
    foreach ($state in $currentStates) { if (-not $state.IsOriginal) { $allOriginal = $false } }
    if ($allOriginal) { Write-Output 'Original files are already restored; backup retained.'; exit 0 }

    New-Item -ItemType Directory -Path $stageRoot | Out-Null
    $stageCreated = $true
    foreach ($row in $rows) {
        $payload = Get-SafePath (Join-Path $PSScriptRoot 'payload') ([string]$row.path)
        $staged = Get-SafePath $stageRoot ([string]$row.path)
        New-Item -ItemType Directory -Path (Split-Path -Parent $staged) -Force | Out-Null
        Copy-Item -LiteralPath $payload -Destination $staged
        if (-not (Test-FileRecord $staged $row 'payload')) { throw "Staged payload verification failed: $($row.path)" }
    }

    try {
        foreach ($state in $currentStates) {
            if ($state.IsOriginal) { continue }
            $backup = Get-SafePath $backupPath ([string]$state.Row.path)
            $touched.Add($state)
            Replace-FromFile $backup $state.Target
        }
    }
    catch {
        $restoreError = $_
        foreach ($state in $touched) {
            $payload = Get-SafePath $stageRoot ([string]$state.Row.path)
            Replace-FromFile $payload $state.Target
        }
        throw "Restore failed; patched files were reapplied. $restoreError"
    }
    Write-Output "Original files restored. Verified backup retained at $backupPath."
}
finally {
    if ($stageCreated -and (Test-Path -LiteralPath $stageRoot)) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
}
