# X8 Brawl updater (11-06). Shipped next to X8Brawl.exe. Run through Update.bat (manual) or launch.bat (auto, then
# starts the game). It never needs admin rights, never writes to %TEMP% (everything goes to .update\ next to the
# exe) and never runs anything it downloads: only .pck / asset files from the manifest are accepted.
#
# Where updates come from: update_source.txt next to the exe (first line that is not blank and not a # comment):
#   a local or network folder   D:\Clod\x8-builds\publish   or   \\PC\share\X8 Brawl
#   an https folder URL         https://example.com/x8/            (files = <url><path>)
#   an https manifest URL       https://example.com/x8/manifest.json
#   a OneDrive folder share link  https://1drv.ms/f/...  (files fetched through the OneDrive shares API)
#   a OneDrive file share link to manifest.json  https://1drv.ms/u/...  (11-07: each big file then has its own share
#     link as "url" in the manifest; small files come inline as base64 "data")
# The manifest lists every file of the current cumulative patch (path, sha256, size). Only files whose sha256
# differs or that are missing get downloaded; each one is verified before it replaces anything.
param([switch]$Launch, [switch]$Quiet, [string]$Source = "")

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$Root = $PSScriptRoot
$Exe = Join-Path $Root "X8Brawl.exe"
$Work = Join-Path $Root ".update"
$Dl = Join-Path $Work "dl"
$Orig = Join-Path $Work "base"
$StateFile = Join-Path $Work "installed.json"
$Allowed = @(".pck", ".wav", ".mp3", ".ogg", ".png", ".jpg", ".jpeg", ".webp", ".glb", ".txt")
$TimeoutMs = if ($Launch) { 8000 } else { 30000 }

function Say([string]$t, [string]$c = "Gray") { Write-Host $t -ForegroundColor $c }

function Start-Game {
    if (-not $Launch) { return }
    if (-not (Test-Path $Exe)) { Say "X8Brawl.exe not found in $Root" Red; Start-Sleep 8; return }
    Say "Starting X8 Brawl..." Green
    Start-Process -FilePath $Exe -WorkingDirectory $Root | Out-Null
}

function Finish([int]$code) {
    if ($Launch) { Start-Game } elseif (-not $Quiet) { Write-Host ""; Read-Host "Press Enter to close" | Out-Null }
    exit $code
}

function Read-FirstLine([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return "" }
    foreach ($l in Get-Content -LiteralPath $path) {
        $t = $l.Trim()
        if ($t -ne "" -and -not $t.StartsWith("#")) { return $t }
    }
    return ""
}

function Get-Sha([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }

# ---------- source ----------
function Is-OneDrive([string]$u) { return $u -match '^https://([a-z0-9-]+\.)?(1drv\.ms|onedrive\.live\.com|sharepoint\.com|my\.microsoftpersonalcontent\.com)/' }

function Resolve-Src([string]$s) {
    $s = $s.Trim().Trim('"')
    if ($s -match '^https?://') {
        if ((Is-OneDrive $s) -and $s -match '1drv\.ms/u/') { return @{ Kind = "odfile"; Manifest = $s } }
        if ((Is-OneDrive $s) -and $s -notmatch '/manifest\.json(\?|$)') {
            $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)).TrimEnd('=').Replace('/', '_').Replace('+', '-')
            return @{ Kind = "onedrive"; Share = "u!$b64" }
        }
        if ($s -match '\.json(\?.*)?$') {
            $u = [Uri]$s
            $base = $u.GetLeftPart([UriPartial]::Path)
            $base = $base.Substring(0, $base.LastIndexOf('/') + 1)
            return @{ Kind = "http"; Base = $base; Manifest = $s }
        }
        if (-not $s.EndsWith("/")) { $s += "/" }
        return @{ Kind = "http"; Base = $s; Manifest = $s + "manifest.json" }
    }
    return @{ Kind = "folder"; Base = $s }
}

function Esc-Path([string]$rel) { ($rel -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/' }

function Url-For($src, [string]$rel, [string]$explicit) {
    if ($explicit) { return $explicit }
    switch ($src.Kind) {
        "http" { return $src.Base + (Esc-Path $rel) }
        "onedrive" { return "https://api.onedrive.com/v1.0/shares/$($src.Share)/root:/$(Esc-Path $rel):/content" }
        "odfile" { throw "the manifest has no download link for $rel" }
    }
}

# OneDrive share links (11-07): the anonymous api.onedrive.com route answers 401 for new-style links, so fetch them
# with the anonymous "badger" token the OneDrive web viewer itself uses for "anyone with the link" shares.
$script:Badger = ""
function Get-Badger {
    if ($script:Badger) { return $script:Badger }
    $req = [Net.HttpWebRequest]::Create("https://api-badgerp.svc.ms/v1.0/token")
    $req.Method = "POST"; $req.ContentType = "application/json"; $req.Timeout = $TimeoutMs; $req.UserAgent = "X8Brawl-Updater/1"
    $body = [Text.Encoding]::UTF8.GetBytes('{"appId":"5cbed6ac-a083-4e14-b191-b4ba07653de2"}')
    $st = $req.GetRequestStream(); $st.Write($body, 0, $body.Length); $st.Close()
    $resp = $req.GetResponse()
    try { $j = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() | ConvertFrom-Json } finally { $resp.Close() }
    if (-not $j.token) { throw "OneDrive gave no download token" }
    $script:Badger = [string]$j.token
    return $script:Badger
}

function Open-Http([string]$url) {
    $badger = ""
    if ((Is-OneDrive $url) -and $url -notmatch '/_api/|api\.onedrive\.com') {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($url)).TrimEnd('=').Replace('/', '_').Replace('+', '-')
        $url = "https://my.microsoftpersonalcontent.com/_api/v2.0/shares/u!$b64/driveitem/content"
        $badger = Get-Badger
    }
    $req = [Net.HttpWebRequest]::Create($url)
    if ($badger) { $req.Headers.Add("Authorization", "Badger $badger"); $req.Headers.Add("Prefer", "autoredeem") }
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = 30000
    $req.AllowAutoRedirect = $true
    $req.UserAgent = "X8Brawl-Updater/1"
    return $req.GetResponse()
}

function Get-ManifestText($src) {
    if ($src.Kind -eq "folder") {
        $p = Join-Path $src.Base "manifest.json"
        if (-not (Test-Path -LiteralPath $p)) { throw "no manifest.json in $($src.Base)" }
        return [IO.File]::ReadAllText($p)
    }
    $url = if ($src.Kind -eq "onedrive") { Url-For $src "manifest.json" "" } else { $src.Manifest }
    $resp = Open-Http $url
    try { $r = New-Object IO.StreamReader($resp.GetResponseStream()); return $r.ReadToEnd() } finally { $resp.Close() }
}

# Copies/downloads one file to $dest, printing progress for big files.
function Fetch($src, $entry, [string]$dest) {
    $rel = [string]$entry.path
    if ($entry.data) { [IO.File]::WriteAllBytes($dest, [Convert]::FromBase64String([string]$entry.data)); return }  # small file inline
    if ($src.Kind -eq "folder") {
        $from = Join-Path $src.Base ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $from)) { throw "missing in update folder: $rel" }
        Copy-Item -LiteralPath $from -Destination $dest -Force
        return
    }
    $resp = Open-Http (Url-For $src $rel ([string]$entry.url))
    try {
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($dest)
        try {
            $buf = New-Object byte[] 1048576
            $done = 0L; $next = 8MB; $total = [int64]$entry.size
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n); $done += $n
                if ($done -ge $next) { Say ("      {0:N0} / {1:N0} MB" -f ($done / 1MB), ($total / 1MB)); $next += 8MB }
            }
        } finally { $out.Close() }
    } finally { $resp.Close() }
}

function Safe-Rel([string]$rel) {
    if (-not $rel -or $rel.Contains("..") -or $rel.Contains(":") -or $rel.StartsWith("/") -or $rel.Contains("\")) { return $false }
    if (-not $rel.StartsWith("patches/") -and -not $rel.StartsWith("assets/") -and $rel.Contains("/")) { return $false }
    return $Allowed -contains ([IO.Path]::GetExtension($rel).ToLower())
}

# ---------- main ----------
Say "X8 Brawl updater" Cyan
$srcText = if ($Source) { $Source } else { Read-FirstLine (Join-Path $Root "update_source.txt") }
if (-not $srcText -or $srcText -match 'PUT_') {
    Say "No update source set (update_source.txt) - skipping the update check." Yellow
    Finish 0
}
$localBase = Read-FirstLine (Join-Path $Root "base_build.txt")

try {
    $src = Resolve-Src $srcText
    Say "Checking for updates..."
    $m = (Get-ManifestText $src) | ConvertFrom-Json
    if ($m.game -ne "X8 Brawl" -or -not $m.base_build) { throw "that is not an X8 Brawl update manifest" }
} catch {
    Say "Could not check for updates: $($_.Exception.Message)" Yellow
    if ($Launch) { Say "Starting the game without updating." Yellow; Start-Sleep 2 }
    Finish 1
}

if ($localBase -and $m.base_build -ne $localBase) {
    Say ""
    Say "NEW FULL VERSION NEEDED" Yellow
    Say "  You have $localBase, the current version is $($m.version)." Yellow
    if ($m.setup_url) { Say "  Download the new Setup from: $($m.setup_url)" Yellow } else { Say "  Ask for the new Setup_X8Brawl installer." Yellow }
    Say "  (Online matches only connect players on the same version.)" Yellow
    if ($Launch) { Say ""; Say "Starting your current version in 15 seconds..."; Start-Sleep 15 }
    Finish 2
}

New-Item -ItemType Directory -Force $Dl | Out-Null
$state = $null
if (Test-Path $StateFile) { try { $state = Get-Content -Raw $StateFile | ConvertFrom-Json } catch { $state = $null } }
if ($state -and $state.base_build -ne $m.base_build) {
    $state = $null  # installed over by a new full build: old bookkeeping and saved originals are void
    if (Test-Path $Orig) { Remove-Item -LiteralPath $Orig -Recurse -Force }
}
$known = @{}  # path -> @{sha; size; mtime} from the last run (skips re-hashing unchanged big files)
if ($state -and $state.files) { foreach ($f in $state.files) { $known[[string]$f.path] = $f } }

$todo = @()
$keep = @{}
foreach ($e in $m.files) {
    $rel = [string]$e.path
    if (-not (Safe-Rel $rel)) { Say "  refused (not an allowed game file): $rel" Red; continue }
    $keep[$rel] = $true
    $local = Join-Path $Root ($rel -replace '/', '\')
    $ok = $false
    if (Test-Path -LiteralPath $local) {
        $fi = Get-Item -LiteralPath $local
        if ($fi.Length -eq [int64]$e.size) {
            $k = $known[$rel]
            if ($k -and $k.sha256 -eq $e.sha256 -and [int64]$k.size -eq $fi.Length -and $k.mtime -eq $fi.LastWriteTimeUtc.Ticks.ToString()) { $ok = $true }
            elseif ((Get-Sha $local) -eq ([string]$e.sha256).ToLower()) { $ok = $true }
        }
    }
    if (-not $ok) { $todo += $e }
}

# Files from an older patch that the new one no longer has: patch files go, replaced base assets get their original back.
$stale = @()
if ($state -and $state.files) { foreach ($f in $state.files) { if (-not $keep.ContainsKey([string]$f.path)) { $stale += [string]$f.path } } }
$pdir = Join-Path $Root "patches"
if (Test-Path $pdir) {
    foreach ($p in Get-ChildItem -LiteralPath $pdir -Filter *.pck -File) {
        $rel = "patches/" + $p.Name
        if (-not $keep.ContainsKey($rel) -and $stale -notcontains $rel) { $stale += $rel }
    }
}

if ($todo.Count -eq 0 -and $stale.Count -eq 0) {
    Say "Up to date: $($m.version)" Green
    Finish 0
}

$running = Get-Process -Name X8Brawl -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $Exe } catch { $false } }
if ($running) {
    Say "X8 Brawl is running - close the game, then run Update again." Yellow
    if ($Launch) { Start-Sleep 4; exit 1 }  # no Start-Game: it is already running
    Finish 1
}

$mb = (($todo | Measure-Object -Property size -Sum).Sum) / 1MB
Say ("Updating to {0}: {1} file(s), {2:N1} MB" -f $m.version, $todo.Count, $mb) Cyan
$i = 0
$failed = 0
foreach ($e in $todo) {
    $i++
    $rel = [string]$e.path
    Say ("  [{0}/{1}] {2} ({3:N1} MB)" -f $i, $todo.Count, $rel, ([int64]$e.size / 1MB))
    $part = Join-Path $Dl (([string]$e.sha256).Substring(0, 16) + ".part")
    try {
        Fetch $src $e $part
        $fi = Get-Item -LiteralPath $part
        if ($fi.Length -ne [int64]$e.size -or (Get-Sha $part) -ne ([string]$e.sha256).ToLower()) { throw "hash check failed" }
        $local = Join-Path $Root ($rel -replace '/', '\')
        $dir = Split-Path $local -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        if (-not $rel.StartsWith("patches/") -and (Test-Path -LiteralPath $local) -and -not $known.ContainsKey($rel)) {
            $save = Join-Path $Orig ($rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $save)) {
                New-Item -ItemType Directory -Force (Split-Path $save -Parent) | Out-Null
                Copy-Item -LiteralPath $local -Destination $save  # original base file, restored if a later patch drops it
            }
        }
        Move-Item -LiteralPath $part -Destination $local -Force
    } catch {
        $failed++
        Say "      FAILED: $($_.Exception.Message)" Red
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
    }
}

foreach ($rel in $stale) {
    $local = Join-Path $Root ($rel -replace '/', '\')
    $save = Join-Path $Orig ($rel -replace '/', '\')
    if (Test-Path -LiteralPath $save) { Move-Item -LiteralPath $save -Destination $local -Force; Say "  restored original $rel" }
    elseif ($rel.StartsWith("patches/") -and (Test-Path -LiteralPath $local)) { Remove-Item -LiteralPath $local -Force; Say "  removed old $rel" }
}

# Bookkeeping: what is installed now (verified files only).
$files = @()
foreach ($e in $m.files) {
    $rel = [string]$e.path
    if (-not $keep.ContainsKey($rel)) { continue }
    $local = Join-Path $Root ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $local)) { continue }
    $fi = Get-Item -LiteralPath $local
    if ($fi.Length -ne [int64]$e.size) { continue }
    $files += [pscustomobject]@{ path = $rel; sha256 = ([string]$e.sha256).ToLower(); size = $fi.Length; mtime = $fi.LastWriteTimeUtc.Ticks.ToString() }
}
$newState = [pscustomobject]@{ base_build = $m.base_build; patch = $m.patch; version = $m.version; updated = (Get-Date).ToString("s"); files = $files }
$newState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StateFile -Encoding UTF8

if ($failed -gt 0) {
    Say ""
    Say "$failed file(s) failed. Run Update again; if it keeps failing, the game still starts on the last good files." Red
    if ($Launch) { Start-Sleep 3 }
    Finish 1
}
Say ""
Say "Done: $($m.version). Launch X8Brawl.exe (or the X8 Brawl shortcut) to play." Green
Finish 0
