param(
  [Parameter(Mandatory=$true)]
  [string]$RepoName,

  [string]$GitHubUser  = "mnoorchenar",
  [string]$HFUser      = "mnoorchenar",
  [string]$Description = "",
  [switch]$Private,
  [switch]$Force
)

# ─── Capture script directory BEFORE any Set-Location calls ──────────────────
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

# ─── Validation ───────────────────────────────────────────────────────────────
if ($RepoName -notmatch '^[\w-]+$') {
  Write-Host "ERROR: RepoName can only contain letters, numbers, hyphens, and underscores"
  exit 1
}
if (-not $env:GITHUB_TOKEN -or $env:GITHUB_TOKEN.Trim().Length -lt 10) {
  Write-Host "ERROR: GITHUB_TOKEN not set. Set it with:"
  Write-Host '[Environment]::SetEnvironmentVariable("GITHUB_TOKEN","YOUR_TOKEN","User")'
  exit 1
}
if (-not $env:HF_TOKEN -or $env:HF_TOKEN.Trim().Length -lt 10) {
  Write-Host "ERROR: HF_TOKEN not set. Set it with:"
  Write-Host '[Environment]::SetEnvironmentVariable("HF_TOKEN","YOUR_TOKEN","User")'
  exit 1
}

$ghHeaders = @{
  Authorization          = "Bearer $env:GITHUB_TOKEN"
  Accept                 = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
}
$hfHeaders = @{
  Authorization  = "Bearer $env:HF_TOKEN"
  "Content-Type" = "application/json"
}

# ══════════════════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════════════════

function Check-LFS {
  git lfs version 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] Git LFS not installed! Install: winget install -e --id GitHub.GitLFS"
    $cont = Read-Host "Continue without LFS? [Y/N]"
    if ($cont -notmatch '^[Yy]$') { exit 1 }
    return $false
  }
  Write-Host "[OK] Git LFS detected"
  return $true
}

function Write-GitAttributes {
  Set-Content -Path ".gitattributes" -Encoding UTF8 -Value @"
*.png    filter=lfs diff=lfs merge=lfs -text
*.jpg    filter=lfs diff=lfs merge=lfs -text
*.jpeg   filter=lfs diff=lfs merge=lfs -text
*.gif    filter=lfs diff=lfs merge=lfs -text
*.ico    filter=lfs diff=lfs merge=lfs -text
*.svg    filter=lfs diff=lfs merge=lfs -text
*.pdf    filter=lfs diff=lfs merge=lfs -text
*.mp4    filter=lfs diff=lfs merge=lfs -text
*.mov    filter=lfs diff=lfs merge=lfs -text
*.avi    filter=lfs diff=lfs merge=lfs -text
*.zip    filter=lfs diff=lfs merge=lfs -text
*.tar.gz filter=lfs diff=lfs merge=lfs -text
*.db     filter=lfs diff=lfs merge=lfs -text
*.sqlite filter=lfs diff=lfs merge=lfs -text
*.pkl    filter=lfs diff=lfs merge=lfs -text
*.h5     filter=lfs diff=lfs merge=lfs -text
*.pth    filter=lfs diff=lfs merge=lfs -text
*.onnx   filter=lfs diff=lfs merge=lfs -text
*.pt     filter=lfs diff=lfs merge=lfs -text
"@
  Write-Host "[OK] Created .gitattributes (LFS enabled)"
}

function Write-SyncScript([string]$repoPath) {
  $dest = Join-Path $repoPath "sync.ps1"
  if (Test-Path $dest) { Write-Host "[OK] sync.ps1 already exists"; return }

  $content = @'
param(
  [string]$Message  = "",
  [switch]$PullOnly,
  [switch]$Verbose
)

if ($Message -eq "" -and -not $PullOnly) {
  $Message = "Update " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

if (-not $env:HF_TOKEN -or $env:HF_TOKEN.Trim().Length -lt 10) {
  Write-Host "Error: HF_TOKEN not set"
  Write-Host "Set with: [Environment]::SetEnvironmentVariable('HF_TOKEN','YOUR_TOKEN','User')"
  exit 1
}

$repoRoot = git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "Error: Not a git repository"; exit 1 }
Set-Location $repoRoot

$hfRemote = git remote get-url huggingface 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "Error: HuggingFace remote not configured"; exit 1 }

if ($hfRemote -match 'huggingface\.co/spaces/([^/]+)/(.+?)(?:\.git)?$') {
  $hfUser  = $Matches[1]
  $hfSpace = $Matches[2]
} else { Write-Host "Error: Cannot parse HF remote"; exit 1 }

$config = @{ max_file_size_mb = 10; ask_before_upload = $true }
if (Test-Path ".syncconfig") {
  try {
    $configData = Get-Content ".syncconfig" -Raw | ConvertFrom-Json
    $config.max_file_size_mb  = $configData.max_file_size_mb
    $config.ask_before_upload = $configData.ask_before_upload
  } catch {}
}

Write-Host "`n=== 3-Way Date-Priority Sync ===`n"

function Get-RemoteCommit($remote) {
  $commit = git rev-parse "$remote/main" 2>$null
  if ($LASTEXITCODE -eq 0) { return $commit }; return $null
}
function Get-RemoteDate($remote) {
  $date = git log "$remote/main" -1 --format=%ci 2>$null
  if ($LASTEXITCODE -eq 0 -and $date) { return [datetime]$date }
  return [datetime]::MinValue
}
function Get-FileSize($path) {
  if (Test-Path $path) { return (Get-Item $path).Length / 1MB }; return 0
}
function Ask-Upload($fileName, $sizeMB) {
  Write-Host "`n[WARN] Large file: $fileName ($([math]::Round($sizeMB,2)) MB)"
  Write-Host "  1. Yes   - Upload this file"
  Write-Host "  2. No    - Skip this file"
  Write-Host "  3. All   - Upload all large files"
  Write-Host "  4. Skip  - Skip all large files"
  $c = Read-Host "Choice [1-4] (default: 2)"; if ($c -eq "") { $c = "2" }; return $c
}

git add -A
$skipAll = $false; $uploadAll = $false

if ($config.ask_before_upload) {
  $allFiles   = git diff --cached --name-only --diff-filter=ACMR
  $largeFiles = @()
  foreach ($file in $allFiles) {
    if (Test-Path $file) {
      $sizeMB = Get-FileSize $file
      if ($sizeMB -gt $config.max_file_size_mb) { $largeFiles += @{ Path=$file; Size=$sizeMB } }
    }
  }
  if ($largeFiles.Count -gt 0) {
    Write-Host "Found $($largeFiles.Count) large file(s) (>$($config.max_file_size_mb) MB)"
    $filesToSkip = @()
    foreach ($fileInfo in $largeFiles) {
      if ($uploadAll) { continue }
      if ($skipAll)   { $filesToSkip += $fileInfo.Path; continue }
      $c = Ask-Upload $fileInfo.Path $fileInfo.Size
      switch ($c) {
        "1" { continue } "2" { $filesToSkip += $fileInfo.Path }
        "3" { $uploadAll = $true } "4" { $skipAll = $true; $filesToSkip += $fileInfo.Path }
      }
    }
    if ($filesToSkip.Count -gt 0) {
      Write-Host "Skipping $($filesToSkip.Count) file(s):"
      foreach ($f in $filesToSkip) { git reset HEAD $f 2>$null | Out-Null; Write-Host "  - $f" }
    }
  }
}

Write-Host "Fetching from remotes..."
git fetch github 2>$null;      $ghExists = $LASTEXITCODE -eq 0
git fetch huggingface 2>$null; $hfExists = $LASTEXITCODE -eq 0
$isFirstPush = (-not $ghExists -and -not $hfExists)

if (-not $isFirstPush) {
  $localCommit   = git rev-parse HEAD 2>$null
  $ghCommit      = Get-RemoteCommit "github"
  $hfCommit      = Get-RemoteCommit "huggingface"
  $localDate     = git log HEAD -1 --format=%ci 2>$null
  $localDateTime = if ($localDate) { [datetime]$localDate } else { [datetime]::MinValue }
  $ghDate        = Get-RemoteDate "github"
  $hfDate        = Get-RemoteDate "huggingface"

  Write-Host "Last update dates:"
  Write-Host "  Local:       $($localDateTime.ToString('yyyy-MM-dd HH:mm:ss'))"
  if ($ghExists) { Write-Host "  GitHub:      $($ghDate.ToString('yyyy-MM-dd HH:mm:ss'))" }
  if ($hfExists) { Write-Host "  HuggingFace: $($hfDate.ToString('yyyy-MM-dd HH:mm:ss'))" }
  Write-Host ""

  $remotesToMerge = @()
  if ($ghExists -and $ghCommit -and $localCommit -ne $ghCommit) {
    $remotesToMerge += @{ Name="github";      Date=$ghDate; Commit=$ghCommit }
  }
  if ($hfExists -and $hfCommit -and $localCommit -ne $hfCommit) {
    $remotesToMerge += @{ Name="huggingface"; Date=$hfDate; Commit=$hfCommit }
  }
  $remotesToMerge = $remotesToMerge | Sort-Object -Property Date -Descending

  foreach ($remote in $remotesToMerge) {
    $rName = $remote.Name; $rDate = $remote.Date.ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "Merging from $rName (updated: $rDate)..."
    git diff HEAD --quiet
    if ($LASTEXITCODE -ne 0) { git commit -m "Local changes before $rName merge" 2>$null | Out-Null }
    git merge "$rName/main" --no-edit 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "[WARN] Conflict detected — keeping local version"; git merge --abort 2>$null }
    else { Write-Host "[OK] Merged from $rName" }
    $localCommit = git rev-parse HEAD 2>$null
  }

  $localCommit = git rev-parse HEAD 2>$null
  if ($ghCommit -and $hfCommit -and $localCommit -eq $ghCommit -and $localCommit -eq $hfCommit) {
    Write-Host "[OK] All 3 locations already in sync"
  } elseif ($remotesToMerge.Count -eq 0) { Write-Host "[OK] Already in sync" }
}

if ($PullOnly) { Write-Host "`n[OK] Pull complete`n"; exit 0 }

git diff HEAD --quiet
if ($LASTEXITCODE -ne 0) {
  git commit -m $Message; Write-Host "[OK] Committed: $Message"
} else {
  $localCommit = git rev-parse HEAD 2>$null; $needsPush = $false
  if ($ghExists) { $ghCommit = Get-RemoteCommit "github"; if ($localCommit -ne $ghCommit) { $needsPush = $true } } else { $needsPush = $true }
  if ($hfExists) { $hfCommit = Get-RemoteCommit "huggingface"; if ($localCommit -ne $hfCommit) { $needsPush = $true } } else { $needsPush = $true }
  if (-not $needsPush) { Write-Host "`n[OK] Already up-to-date`n"; exit 0 }
}

Write-Host "`nPushing to remotes..."
git push github main 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "[OK] GitHub" }
else {
  git push github main --force 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Host "[OK] GitHub (forced)" } else { Write-Host "[ERROR] GitHub push failed" }
}

$hfUrl      = "https://${hfUser}:$($env:HF_TOKEN)@huggingface.co/spaces/${hfUser}/${hfSpace}"
$pushOutput = git push $hfUrl main --force 2>&1
if ($Verbose) { Write-Host "Git output: $pushOutput" }
if ($LASTEXITCODE -eq 0) { Write-Host "[OK] HuggingFace" }
else {
  Write-Host "[ERROR] HuggingFace push failed!"
  Write-Host "  $pushOutput"
  Write-Host "  Check: space exists at huggingface.co/spaces/${hfUser}/${hfSpace}"
  Write-Host "  Try:   .\sync.ps1 -Verbose"
  exit 1
}

Write-Host "`n[OK] Sync complete!`n"
'@

  Set-Content -Path $dest -Encoding UTF8 -Value $content
  Write-Host "[OK] Generated sync.ps1"
}

function Write-ProjectFiles([string]$spaceType) {
  $colorFrom = @{ "static"="purple"; "docker"="purple"; "gradio"="blue"; "streamlit"="green" }[$spaceType]
  $colorTo   = @{ "static"="red";    "docker"="blue";   "gradio"="purple"; "streamlit"="yellow" }[$spaceType]

  if ($spaceType -eq "static") {
    Set-Content -Path "README.md" -Encoding UTF8 -Value @"
---
title: $RepoName
colorFrom: $colorFrom
colorTo: $colorTo
sdk: static
pinned: false
---

# $RepoName

$(if ($Description) { $Description } else { "A static web application synced across GitHub and Hugging Face Spaces." })
"@
    Set-Content -Path "index.html" -Encoding UTF8 -Value @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>$RepoName</title>
  <style>
    body { font-family:-apple-system,sans-serif; background:linear-gradient(135deg,#667eea,#764ba2);
           min-height:100vh; display:flex; align-items:center; justify-content:center; }
    .box { background:#fff; border-radius:20px; padding:50px; text-align:center; }
    h1   { color:#2c3e50; }
    .badge { background:#28a745; color:#fff; padding:8px 16px; border-radius:20px; }
  </style>
</head>
<body>
  <div class="box">
    <h1>$RepoName</h1>
    <p>Synced across GitHub and Hugging Face.</p>
    <br/><div class="badge">Active</div>
  </div>
</body>
</html>
"@

  } elseif ($spaceType -eq "docker") {
    Set-Content -Path "README.md" -Encoding UTF8 -Value @"
---
title: $RepoName
colorFrom: $colorFrom
colorTo: $colorTo
sdk: docker
app_port: 7860
pinned: false
---
"@
    Set-Content -Path "requirements.txt" -Encoding UTF8 -Value "flask==3.0.0"
    Set-Content -Path "Dockerfile" -Encoding UTF8 -Value @"
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 7860
CMD ["python", "app.py"]
"@
    Set-Content -Path "app.py" -Encoding UTF8 -Value @"
from flask import Flask, render_template_string
app = Flask(__name__)
HTML = """<!DOCTYPE html>
<html><head><title>$RepoName</title></head>
<body style="font-family:Arial;max-width:800px;margin:50px auto;padding:20px">
  <h1>$RepoName</h1>
  <p>Running on port 7860.</p>
  <span style="background:#28a745;color:#fff;padding:5px 15px;border-radius:15px">Running</span>
</body></html>"""
@app.route('/')
def home(): return render_template_string(HTML)
if __name__ == '__main__': app.run(host='0.0.0.0', port=7860)
"@

  } elseif ($spaceType -eq "gradio") {
    Set-Content -Path "README.md" -Encoding UTF8 -Value @"
---
title: $RepoName
colorFrom: $colorFrom
colorTo: $colorTo
sdk: gradio
sdk_version: 4.19.0
app_file: app.py
pinned: false
---
"@
    Set-Content -Path "requirements.txt" -Encoding UTF8 -Value "gradio==4.19.0"
    Set-Content -Path "app.py" -Encoding UTF8 -Value @"
import gradio as gr
def greet(name): return f"Hello {name}! Welcome to $RepoName"
demo = gr.Interface(fn=greet, inputs=gr.Textbox(label="Name"),
                    outputs=gr.Textbox(label="Greeting"), title="$RepoName")
if __name__ == "__main__": demo.launch()
"@

  } else {  # streamlit
    Set-Content -Path "README.md" -Encoding UTF8 -Value @"
---
title: $RepoName
colorFrom: $colorFrom
colorTo: $colorTo
sdk: streamlit
sdk_version: 1.31.0
app_file: app.py
pinned: false
---
"@
    Set-Content -Path "requirements.txt" -Encoding UTF8 -Value "streamlit==1.31.0"
    Set-Content -Path "app.py" -Encoding UTF8 -Value @"
import streamlit as st
st.set_page_config(page_title="$RepoName")
st.title("$RepoName")
name = st.text_input("Enter your name:")
if name: st.success(f"Hello {name}!")
"@
  }
  Write-Host "[OK] Generated project files ($spaceType)"
}

function Select-SpaceType {
  Write-Host ""
  Write-Host "  Select HuggingFace Space type:"
  Write-Host "  1. Static     (HTML/CSS/JS only)"
  Write-Host "  2. Docker     (Python Flask/FastAPI backend)"
  Write-Host "  3. Gradio     (ML/AI demos)"
  Write-Host "  4. Streamlit  (Data apps)"
  Write-Host ""
  do { $c = Read-Host "  Choice (1-4)" } while ($c -notmatch '^[1-4]$')
  $t = @{ "1"="static"; "2"="docker"; "3"="gradio"; "4"="streamlit" }[$c]
  Write-Host "[OK] Selected: $t space"
  return $t
}

function Add-GitRemote([string]$name, [string]$url) {
  $existing = git remote get-url $name 2>$null
  if ($LASTEXITCODE -eq 0) { Write-Host "[OK] Remote '$name' already set" }
  else { git remote add $name $url; Write-Host "[OK] Remote '$name' added" }
}

function Get-GHRemoteUrl([string]$sshUrl, [string]$httpsUrl) {
  ssh -T git@github.com 2>&1 | Out-Null
  return if ($LASTEXITCODE -eq 1) { $sshUrl } else { $httpsUrl }
}

# ══════════════════════════════════════════════════════════════════════════════
#  CHECK STATUS
# ══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Checking status of '$RepoName'..."

$ghExists    = $false
$hfExists    = $false
$localExists = Test-Path $RepoName

try {
  Invoke-RestMethod -Uri "https://api.github.com/repos/${GitHubUser}/${RepoName}" `
    -Method GET -Headers $ghHeaders | Out-Null; $ghExists = $true
} catch {}

try {
  Invoke-RestMethod -Uri "https://huggingface.co/api/spaces/${HFUser}/${RepoName}" `
    -Method GET -Headers $hfHeaders | Out-Null; $hfExists = $true
} catch {}

$localFullPath = if ($localExists) { (Resolve-Path $RepoName).Path } else { Join-Path (Get-Location).Path $RepoName }
$syncExists    = $localExists -and (Test-Path (Join-Path $localFullPath "sync.ps1"))

Write-Host ""
Write-Host "========================================="
Write-Host "  STATUS: $RepoName"
Write-Host "========================================="
Write-Host ""
Write-Host "  GitHub:       $(if ($ghExists)    { '[FOUND]  https://github.com/' + $GitHubUser + '/' + $RepoName } else { '[NOT FOUND]' })"
Write-Host "  HuggingFace:  $(if ($hfExists)    { '[FOUND]  https://huggingface.co/spaces/' + $HFUser + '/' + $RepoName } else { '[NOT FOUND]' })"
Write-Host "  Local folder: $(if ($localExists) { '[FOUND]  .\' + $RepoName } else { '[NOT FOUND]' })"
Write-Host "  sync.ps1:     $(if ($syncExists)  { '[FOUND]' } else { '[NOT FOUND]' })"
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
#  MENU
# ══════════════════════════════════════════════════════════════════════════════
$nothingExists = -not $ghExists -and -not $hfExists -and -not $localExists

if ($nothingExists) {
  $ans = Read-Host "Nothing found. Add it? (Y/N)"
  if ($ans -notmatch '^[Yy]$') { Write-Host "Cancelled."; exit 0 }
  $choice = "add"
} else {
  Write-Host "  1. Edit   (fix missing pieces)"
  Write-Host "  2. Remove"
  Write-Host ""
  do { $choice = Read-Host "Select (1 or 2)" } while ($choice -notmatch '^[12]$')
}

# ══════════════════════════════════════════════════════════════════════════════
#  REMOVE
# ══════════════════════════════════════════════════════════════════════════════
if ($choice -eq "2") {

  if (-not $Force) {
    $confirm = Read-Host "Type the repo name to confirm deletion"
    if ($confirm -ne $RepoName) { Write-Host "Aborted — name did not match."; exit 1 }
  }

  $anyError = $false

  if ($ghExists) {
    Write-Host "Deleting GitHub repo..."
    try {
      Invoke-RestMethod -Uri "https://api.github.com/repos/${GitHubUser}/${RepoName}" `
        -Method DELETE -Headers $ghHeaders | Out-Null
      Write-Host "[OK] GitHub repo deleted"
    } catch {
      Write-Host "ERROR (HTTP $($_.Exception.Response.StatusCode.value__)): $($_.ErrorDetails.Message)"
      $anyError = $true
    }
  }

  if ($hfExists) {
    Write-Host "Deleting HuggingFace Space..."
    try {
      Invoke-RestMethod -Uri "https://huggingface.co/api/repos/delete" `
        -Method DELETE -Headers $hfHeaders `
        -Body (@{ type="space"; name="${HFUser}/${RepoName}" } | ConvertTo-Json) | Out-Null
      Write-Host "[OK] HF Space deleted"
    } catch {
      Write-Host "[WARN] Could not auto-delete HF Space (HTTP $($_.Exception.Response.StatusCode.value__))"
      Write-Host "       Delete manually: huggingface.co/spaces/${HFUser}/${RepoName} → Settings → Delete"
    }
  }

  if ($localExists) {
    $ans = Read-Host "Delete local folder './$RepoName' too? (Y/N)"
    if ($ans -match '^[Yy]$') {
      try { Remove-Item -Recurse -Force $RepoName; Write-Host "[OK] Local folder deleted" }
      catch { Write-Host "ERROR: $($_.Exception.Message)"; $anyError = $true }
    }
  }

  Write-Host ""
  if ($anyError) { Write-Host "[WARN] Done with some errors."; exit 1 }
  else           { Write-Host "[OK] Removal complete." }
  Write-Host ""
  exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  ADD / EDIT
# ══════════════════════════════════════════════════════════════════════════════
$spaceType     = $null
$ghSshUrl      = $null
$ghHttpsUrl    = $null
$hasLFS        = $false
$justCreatedGH = $false

# ── Create GitHub repo if missing ────────────────────────────────────────────
if (-not $ghExists) {
  Write-Host ""
  $ans = Read-Host "GitHub repo not found. Create it? (Y/N)"
  if ($ans -match '^[Yy]$') {
    Write-Host "Creating GitHub repository..."
    $body = @{
      name        = $RepoName
      description = if ($Description) { $Description } else { "$RepoName - created by repo-manager-hf" }
      private     = $Private.IsPresent
      auto_init   = $false
    } | ConvertTo-Json
    try {
      $res        = Invoke-RestMethod -Uri "https://api.github.com/user/repos" `
                      -Method POST -Headers $ghHeaders -Body $body -ContentType "application/json"
      $ghSshUrl   = $res.ssh_url
      $ghHttpsUrl = $res.clone_url
      $justCreatedGH = $true
      Write-Host "[OK] GitHub repo created: $($res.html_url)"
    } catch {
      Write-Host "ERROR creating GitHub repo (HTTP $($_.Exception.Response.StatusCode.value__)): $($_.ErrorDetails.Message)"
      exit 1
    }
  }
}

# ── Create HF Space if missing ───────────────────────────────────────────────
if (-not $hfExists) {
  Write-Host ""
  $ans = Read-Host "HuggingFace Space not found. Create it? (Y/N)"
  if ($ans -match '^[Yy]$') {
    $spaceType = Select-SpaceType
    Write-Host "Creating HuggingFace Space..."
    $body = @{
      type        = "space"
      name        = $RepoName
      sdk         = $spaceType
      private     = $Private.IsPresent
      description = if ($Description) { $Description } else { "$RepoName Space" }
    } | ConvertTo-Json
    try {
      Invoke-RestMethod -Uri "https://huggingface.co/api/repos/create" `
        -Method POST -Headers $hfHeaders -Body $body | Out-Null
      Write-Host "[OK] HF Space created: https://huggingface.co/spaces/${HFUser}/${RepoName}"
    } catch {
      $code = $_.Exception.Response.StatusCode.value__
      Write-Host "ERROR creating HF Space (HTTP $code): $($_.ErrorDetails.Message)"
      if ($justCreatedGH) {
        Write-Host "[WARN] Rolling back GitHub repo..."
        Invoke-RestMethod -Uri "https://api.github.com/repos/${GitHubUser}/${RepoName}" `
          -Method DELETE -Headers $ghHeaders -ErrorAction SilentlyContinue | Out-Null
        Write-Host "[OK] GitHub repo rolled back"
      }
      exit 1
    }
  }
}

# ── Create local folder if missing ───────────────────────────────────────────
if (-not $localExists) {
  $cloneUrl = if ($ghHttpsUrl) { $ghHttpsUrl } elseif ($ghExists) { "https://github.com/${GitHubUser}/${RepoName}.git" } else { $null }

  if ($cloneUrl) {
    Write-Host "Cloning from GitHub..."
    git clone $cloneUrl $RepoName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "[WARN] GitHub clone failed, trying HuggingFace..."
      git clone "https://huggingface.co/spaces/${HFUser}/${RepoName}" $RepoName 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { $hasLFS = Check-LFS; New-Item -ItemType Directory -Path $RepoName | Out-Null; Write-Host "[OK] Created empty local folder" }
      else { Write-Host "[OK] Cloned from HuggingFace" }
    } else { Write-Host "[OK] Cloned from GitHub" }
  } elseif ($hfExists) {
    Write-Host "Cloning from HuggingFace..."
    git clone "https://huggingface.co/spaces/${HFUser}/${RepoName}" $RepoName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $hasLFS = Check-LFS; New-Item -ItemType Directory -Path $RepoName | Out-Null; Write-Host "[OK] Created empty local folder" }
    else { Write-Host "[OK] Cloned from HuggingFace" }
  } else {
    $hasLFS = Check-LFS
    New-Item -ItemType Directory -Path $RepoName | Out-Null
    Write-Host "[OK] Local folder created"
  }
  $localFullPath = (Resolve-Path $RepoName).Path
}

Set-Location $localFullPath

# ── Init git if needed ───────────────────────────────────────────────────────
if (-not (Test-Path ".git")) {
  git init -b main | Out-Null
  git config pull.rebase false
  if ($hasLFS) { git lfs install | Out-Null }
  Write-Host "[OK] Git initialised"
}

# ── Add remotes if missing ───────────────────────────────────────────────────
if (-not $ghSshUrl)   { $ghSshUrl   = "git@github.com:${GitHubUser}/${RepoName}.git" }
if (-not $ghHttpsUrl) { $ghHttpsUrl = "https://github.com/${GitHubUser}/${RepoName}.git" }
$ghRemoteUrl = Get-GHRemoteUrl $ghSshUrl $ghHttpsUrl
Add-GitRemote "github"      $ghRemoteUrl
Add-GitRemote "huggingface" "https://${HFUser}:$($env:HF_TOKEN)@huggingface.co/spaces/${HFUser}/${RepoName}"

# ── Generate project files if this is a fresh empty folder ───────────────────
if (-not (Test-Path "README.md") -and $spaceType) {
  Write-ProjectFiles $spaceType
  Set-Content -Path ".gitignore" -Encoding UTF8 -Value @"
__pycache__/
*.pyc
.env
.DS_Store
*.log
.vscode/
*.tmp
"@
  Write-Host "[OK] Created .gitignore"
  if ($hasLFS) { Write-GitAttributes }
}

# ── .syncconfig ──────────────────────────────────────────────────────────────
if (-not (Test-Path ".syncconfig")) {
  Set-Content -Path ".syncconfig" -Encoding UTF8 -Value '{ "max_file_size_mb": 10, "ask_before_upload": true }'
  Write-Host "[OK] Created .syncconfig"
}

# ── sync.ps1 ─────────────────────────────────────────────────────────────────
Write-SyncScript $localFullPath

# ── Commit & push ─────────────────────────────────────────────────────────────
git add -A
git diff HEAD --quiet
if ($LASTEXITCODE -ne 0) { git commit -m "Initial commit" | Out-Null; Write-Host "[OK] Committed" }

Write-Host ""
Write-Host "Pushing to GitHub..."
git push github main 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "[OK] Pushed to GitHub" }
else {
  git push github main --force 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Host "[OK] Pushed to GitHub (forced)" }
  else                      { Write-Host "[WARN] GitHub push failed — run: .\sync.ps1" }
}

Write-Host "Pushing to HuggingFace..."
$hfPushUrl = "https://${HFUser}:$($env:HF_TOKEN)@huggingface.co/spaces/${HFUser}/${RepoName}"
git push $hfPushUrl main --force 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "[OK] Pushed to HuggingFace" }
else                      { Write-Host "[WARN] HF push failed — run: .\sync.ps1" }

Set-Location $ScriptDir

Write-Host ""
Write-Host "========================================="
Write-Host "  SETUP COMPLETE"
Write-Host "========================================="
Write-Host ""
Write-Host "  GitHub:      https://github.com/${GitHubUser}/${RepoName}"
Write-Host "  HuggingFace: https://huggingface.co/spaces/${HFUser}/${RepoName}"
Write-Host ""
if ($spaceType -eq "static")      { Write-Host "  Files: README.md  index.html  .gitignore  .syncconfig  sync.ps1" }
elseif ($spaceType -eq "docker")  { Write-Host "  Files: README.md  app.py  requirements.txt  Dockerfile  .gitignore  .syncconfig  sync.ps1" }
elseif ($spaceType)               { Write-Host "  Files: README.md  app.py  requirements.txt  .gitignore  .syncconfig  sync.ps1" }
if ($hasLFS)                      { Write-Host "         .gitattributes (LFS)" }
Write-Host ""
Write-Host "  Next: cd $RepoName  then  .\sync.ps1 'Your message'"
Write-Host ""