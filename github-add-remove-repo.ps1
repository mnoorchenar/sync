param(
  [Parameter(Mandatory=$true)]
  [string]$RepoName,

  [string]$GitHubUser  = "mnoorchenar",
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

# ─── Python Check ─────────────────────────────────────────────────────────────
python --version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "[WARN] Python not found — sync.ps1 requires Python to generate index.json"
  $cont = Read-Host "Continue anyway? (Y/N)"
  if ($cont -notmatch '^[Yy]$') { exit 1 }
}

$ghHeaders = @{
  Authorization          = "Bearer $env:GITHUB_TOKEN"
  Accept                 = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
}

# ─── Helper: generate sync.ps1 for this repo ─────────────────────────────────
function Write-SyncScript([string]$repoRoot) {
  $dest = Join-Path $repoRoot "sync.ps1"
  if (Test-Path $dest) {
    Write-Host "[OK] sync.ps1 already exists"
    return
  }

  $content = @'
param(
  [string]$Message = "",
  [switch]$PullOnly
)

if ($Message -eq "" -and -not $PullOnly) {
  $Message = "Update " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

$repoRoot = git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Error: Not a git repository"
  exit 1
}
Set-Location $repoRoot

Write-Host "`n=== GitHub Sync ===`n"

# ── STEP 1: Auto-generate index.json by scanning all folders ─────────────────
Write-Host "Scanning folders and generating index.json..."

$pythonScript = @"
import os, re, json

ROOT = r'REPO_ROOT_PLACEHOLDER'

SKIP_FOLDERS = {'.git', '__pycache__', 'node_modules', '.venv', 'venv', 'debug', '.github'}
SKIP_FILES   = {'index.html', 'index.json', 'sync.ps1', 'readme.md', '404.html'}

def normalize(name):
    return re.sub(r'^\d+\.\s*', '', name).strip()

def sort_key(name):
    m = re.match(r'^(\d+)', name)
    return (int(m.group(1)), name) if m else (999999, name)

def safe_listdir(path):
    try:    return sorted(os.listdir(path), key=sort_key)
    except: return []

def collect_html(folder_path, rel_prefix):
    files = []
    for fn in safe_listdir(folder_path):
        if fn.lower() in SKIP_FILES:  continue
        if not fn.endswith('.html'):   continue
        if not os.path.isfile(os.path.join(folder_path, fn)): continue
        files.append({'name': normalize(os.path.splitext(fn)[0]), 'html': f'{rel_prefix}/{fn}'})
    return files

structure = []
for folder_name in safe_listdir(ROOT):
    if folder_name in SKIP_FOLDERS: continue
    folder_path = os.path.join(ROOT, folder_name)
    if not os.path.isdir(folder_path) or os.path.islink(folder_path): continue
    direct_files = collect_html(folder_path, folder_name)
    subfolders = []
    for sub_name in safe_listdir(folder_path):
        if sub_name in SKIP_FOLDERS: continue
        sub_path = os.path.join(folder_path, sub_name)
        if not os.path.isdir(sub_path) or os.path.islink(sub_path): continue
        sub_files = collect_html(sub_path, f'{folder_name}/{sub_name}')
        if sub_files:
            subfolders.append({'name': normalize(sub_name), 'folder': sub_name, 'files': sub_files})
    if direct_files or subfolders:
        structure.append({'name': normalize(folder_name), 'folder': folder_name, 'files': direct_files, 'subfolders': subfolders})

out = os.path.join(ROOT, 'index.json')
with open(out, 'w', encoding='utf-8') as f:
    json.dump(structure, f, indent=2, ensure_ascii=False)

total = sum(len(s['files']) + sum(len(sf['files']) for sf in s['subfolders']) for s in structure)
print(f'index.json -> {len(structure)} folder(s), {total} file(s)')
"@

python -c $pythonScript
if ($LASTEXITCODE -ne 0) {
  Write-Host "[ERROR] index.json generation failed — aborting"
  exit 1
}

# ── STEP 2: Stage everything ──────────────────────────────────────────────────
git add -A

# ── STEP 3: Fetch + merge from GitHub ────────────────────────────────────────
Write-Host "`nFetching from GitHub..."
git fetch origin 2>$null
$remoteExists = $LASTEXITCODE -eq 0

if ($remoteExists) {
  $localCommit  = git rev-parse HEAD 2>$null
  $remoteCommit = git rev-parse origin/main 2>$null
  if ($localCommit -ne $remoteCommit) {
    Write-Host "Merging from GitHub..."
    git diff HEAD --quiet
    if ($LASTEXITCODE -ne 0) { git commit -m "Local changes before merge" 2>$null | Out-Null }
    git merge origin/main --no-edit 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "[!] Merge conflict — keeping local version..."
      git merge --abort 2>$null
    } else {
      Write-Host "[OK] Merged from GitHub"
    }
  } else {
    Write-Host "[OK] Already up-to-date"
  }
}

if ($PullOnly) { Write-Host "`n[OK] Pull complete`n"; exit 0 }

# ── STEP 4: Commit ────────────────────────────────────────────────────────────
git diff HEAD --quiet
if ($LASTEXITCODE -ne 0) {
  git commit -m $Message
  Write-Host "[OK] Committed: $Message"
} else {
  Write-Host "[OK] Nothing new to commit"
}

# ── STEP 5: Push ──────────────────────────────────────────────────────────────
Write-Host "`nPushing to GitHub..."
git push origin main 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
  Write-Host "[OK] Push complete"
} else {
  git push origin main --force 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Host "[OK] Push complete (forced)" }
  else                      { Write-Host "[ERROR] Push failed"; exit 1 }
}

Write-Host "`n[OK] Sync complete`n"
'@

  # Replace the ROOT placeholder with the actual repo path (escaped for Python)
  $escapedRoot = $repoRoot -replace '\\', '\\'
  $content     = $content -replace 'REPO_ROOT_PLACEHOLDER', $escapedRoot

  Set-Content -Path $dest -Encoding UTF8 -Value $content
  Write-Host "[OK] Generated sync.ps1"
}

# ─── Helper: Git LFS Check ───────────────────────────────────────────────────
function Check-LFS {
  git lfs version 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARN] Git LFS not installed. Install: winget install -e --id GitHub.GitLFS"
    $cont = Read-Host "Continue without LFS? [Y/N]"
    if ($cont -notmatch '^[Yy]$') { exit 1 }
    return $false
  }
  Write-Host "[OK] Git LFS detected"
  return $true
}

# ─── Helper: create .gitattributes ───────────────────────────────────────────
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
*.zip    filter=lfs diff=lfs merge=lfs -text
*.pkl    filter=lfs diff=lfs merge=lfs -text
*.h5     filter=lfs diff=lfs merge=lfs -text
*.pth    filter=lfs diff=lfs merge=lfs -text
*.onnx   filter=lfs diff=lfs merge=lfs -text
*.pt     filter=lfs diff=lfs merge=lfs -text
*.sqlite filter=lfs diff=lfs merge=lfs -text
"@
  Write-Host "[OK] Created .gitattributes (LFS enabled)"
}

# ─── Check GitHub + local state ───────────────────────────────────────────────
Write-Host ""
Write-Host "Checking status of '$RepoName'..."

$ghExists    = $false
$localExists = Test-Path $RepoName

try {
  Invoke-RestMethod -Uri "https://api.github.com/repos/${GitHubUser}/${RepoName}" `
    -Method GET -Headers $ghHeaders | Out-Null
  $ghExists = $true
} catch {}

Write-Host ""
Write-Host "========================================="
Write-Host "  STATUS: $RepoName"
Write-Host "========================================="
Write-Host ""
Write-Host "  GitHub:       $(if ($ghExists)    { '[FOUND]  https://github.com/' + $GitHubUser + '/' + $RepoName } else { '[NOT FOUND]' })"
Write-Host "  Local folder: $(if ($localExists) { '[FOUND]  .\' + $RepoName } else { '[NOT FOUND]' })"
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
#  CASE 1: Both exist — check sync.ps1, or offer remove
# ══════════════════════════════════════════════════════════════════════════════
if ($ghExists -and $localExists) {

  $localFullPath = (Resolve-Path $RepoName).Path
  $syncMissing   = -not (Test-Path (Join-Path $localFullPath "sync.ps1"))

  if ($syncMissing) {
    Write-Host "  [!] sync.ps1 missing from local folder"
    $ans = Read-Host "Add sync.ps1 to '$RepoName'? (Y/N)"
    if ($ans -match '^[Yy]$') {
      Write-SyncScript $localFullPath
      Write-Host ""
      Write-Host "[OK] Done. Run: cd $RepoName  then  .\sync.ps1 'Your message'"
      Write-Host ""
      exit 0
    }
    Write-Host ""
  } else {
    Write-Host "  [OK] sync.ps1 already present"
    Write-Host ""
  }

  $ans = Read-Host "Remove this repo? (Y/N)"
  if ($ans -notmatch '^[Yy]$') { Write-Host "Done."; exit 0 }

  if (-not $Force) {
    $confirm = Read-Host "Type the repo name to confirm deletion"
    if ($confirm -ne $RepoName) { Write-Host "Aborted — name did not match."; exit 1 }
  }

  $anyError = $false

  Write-Host "Deleting GitHub repo..."
  try {
    Invoke-RestMethod -Uri "https://api.github.com/repos/${GitHubUser}/${RepoName}" `
      -Method DELETE -Headers $ghHeaders | Out-Null
    Write-Host "[OK] GitHub repo deleted"
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    Write-Host "ERROR deleting GitHub repo (HTTP $code): $($_.ErrorDetails.Message)"
    $anyError = $true
  }

  $ans2 = Read-Host "Delete local folder './$RepoName' too? (Y/N)"
  if ($ans2 -match '^[Yy]$') {
    try {
      Remove-Item -Recurse -Force $RepoName
      Write-Host "[OK] Local folder deleted"
    } catch {
      Write-Host "ERROR deleting local folder: $($_.Exception.Message)"
      $anyError = $true
    }
  }

  Write-Host ""
  if ($anyError) { Write-Host "[WARN] Done with some errors."; exit 1 }
  else           { Write-Host "[OK] Removal complete." }
  Write-Host ""
  exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  CASE 2: Repo exists, no local folder — offer clone
# ══════════════════════════════════════════════════════════════════════════════
if ($ghExists -and -not $localExists) {

  $ans = Read-Host "GitHub repo found but no local folder. Clone it? (Y/N)"
  if ($ans -notmatch '^[Yy]$') { Write-Host "Cancelled."; exit 0 }

  Write-Host "Cloning..."
  git clone "https://github.com/${GitHubUser}/${RepoName}.git" $RepoName 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Clone failed"; exit 1 }
  Write-Host "[OK] Cloned to .\$RepoName"

  $localFullPath = (Resolve-Path $RepoName).Path
  Write-SyncScript $localFullPath

  Write-Host ""
  Write-Host "[OK] Done. Run: cd $RepoName  then  .\sync.ps1 'Your message'"
  Write-Host ""
  exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  CASE 3: Local folder exists, no GitHub repo — offer create + link
# ══════════════════════════════════════════════════════════════════════════════
if (-not $ghExists -and $localExists) {

  $ans = Read-Host "Local folder found but no GitHub repo. Create repo and link it? (Y/N)"
  if ($ans -notmatch '^[Yy]$') { Write-Host "Cancelled."; exit 0 }

  Write-Host "Creating GitHub repository..."
  $ghBody = @{
    name        = $RepoName
    description = if ($Description) { $Description } else { "$RepoName repository" }
    private     = $Private.IsPresent
    auto_init   = $false
  } | ConvertTo-Json

  try {
    $res        = Invoke-RestMethod -Uri "https://api.github.com/user/repos" `
                    -Method POST -Headers $ghHeaders -Body $ghBody -ContentType "application/json"
    $ghSshUrl   = $res.ssh_url
    $ghHttpsUrl = $res.clone_url
    Write-Host "[OK] GitHub repo created: $($res.html_url)"
  } catch {
    Write-Host "ERROR creating GitHub repo (HTTP $($_.Exception.Response.StatusCode.value__)): $($_.ErrorDetails.Message)"
    exit 1
  }

  $localFullPath = (Resolve-Path $RepoName).Path
  Set-Location $localFullPath

  if (-not (Test-Path ".git")) {
    git init -b main | Out-Null
    git config pull.rebase false
    Write-Host "[OK] Git initialised"
  }

  $existingRemote = git remote get-url origin 2>$null
  if ($LASTEXITCODE -ne 0) {
    ssh -T git@github.com 2>&1 | Out-Null
    $ghRemote = if ($LASTEXITCODE -eq 1) { $ghSshUrl } else { $ghHttpsUrl }
    git remote add origin $ghRemote
    Write-Host "[OK] Remote 'origin' added"
  } else {
    Write-Host "[OK] Remote 'origin' already set: $existingRemote"
  }

  Write-SyncScript $localFullPath

  git add -A
  git commit -m "Initial commit" 2>$null | Out-Null
  git push origin main 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Host "[OK] Pushed to GitHub" }
  else                      { Write-Host "[WARN] Push failed — run: git push origin main" }

  Set-Location $ScriptDir

  Write-Host ""
  Write-Host "[OK] Done.  GitHub: https://github.com/${GitHubUser}/${RepoName}"
  Write-Host "     Next:  cd $RepoName  then  .\sync.ps1 'Your message'"
  Write-Host ""
  exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  CASE 4: Neither exists — full create
# ══════════════════════════════════════════════════════════════════════════════
$ans = Read-Host "Repo not found. Create it? (Y/N)"
if ($ans -notmatch '^[Yy]$') { Write-Host "Cancelled."; exit 0 }

$hasLFS = Check-LFS

Write-Host "Creating GitHub repository..."
$ghBody = @{
  name        = $RepoName
  description = if ($Description) { $Description } else { "$RepoName repository" }
  private     = $Private.IsPresent
  auto_init   = $false
} | ConvertTo-Json

try {
  $res        = Invoke-RestMethod -Uri "https://api.github.com/user/repos" `
                  -Method POST -Headers $ghHeaders -Body $ghBody -ContentType "application/json"
  $ghSshUrl   = $res.ssh_url
  $ghHttpsUrl = $res.clone_url
  Write-Host "[OK] GitHub repo created: $($res.html_url)"
} catch {
  Write-Host "ERROR creating GitHub repo (HTTP $($_.Exception.Response.StatusCode.value__)): $($_.ErrorDetails.Message)"
  exit 1
}

New-Item -ItemType Directory -Path $RepoName | Out-Null
$localFullPath = (Resolve-Path $RepoName).Path
Set-Location $localFullPath

git init -b main | Out-Null
git config pull.rebase false
if ($hasLFS) { git lfs install | Out-Null }

ssh -T git@github.com 2>&1 | Out-Null
$ghRemote   = if ($LASTEXITCODE -eq 1) { $ghSshUrl } else { $ghHttpsUrl }
$remoteMode = if ($ghRemote -eq $ghSshUrl) { "SSH" } else { "HTTPS" }
git remote add origin $ghRemote
Write-Host "[OK] Git remote 'origin' configured (GitHub: $remoteMode)"

$desc = if ($Description) { $Description } else { "$RepoName repository" }
Set-Content -Path "README.md" -Encoding UTF8 -Value @"
# $RepoName

$desc

---

> Created with repo-manager-github.ps1
"@

Set-Content -Path ".gitignore" -Encoding UTF8 -Value @"
__pycache__/
*.pyc
.env
.DS_Store
*.log
.vscode/
*.tmp
"@

if ($hasLFS) { Write-GitAttributes }

Write-SyncScript $localFullPath

git add -A
git commit -m "Initial commit" | Out-Null
Write-Host "[OK] Initial commit created"

git push origin main 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "[OK] Pushed to GitHub" }
else                      { Write-Host "[WARN] Push failed — run: git push origin main" }

Write-Host ""
Write-Host "========================================="
Write-Host "  SETUP COMPLETE"
Write-Host "========================================="
Write-Host ""
Write-Host "  GitHub: https://github.com/${GitHubUser}/${RepoName}"
Write-Host "  Files:  README.md  .gitignore$(if ($hasLFS) { '  .gitattributes' })  sync.ps1"
Write-Host ""
Write-Host "  Next: cd $RepoName  then  .\sync.ps1 'Your message'"
Write-Host ""