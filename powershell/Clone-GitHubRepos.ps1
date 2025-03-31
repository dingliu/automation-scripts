[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$ReposPath
)

#region Functions
# Function to check if GitHub CLI is installed and user is logged in
function Test-GitHubLogin {
    try {
        $userInfo = gh auth status -h github.com 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "You are not logged into GitHub. Please run 'gh auth login' first."
            exit 1
        }
        return $true
    }
    catch {
        Write-Error "GitHub CLI is not installed or accessible. Please make sure it's installed and in your PATH."
        exit 1
    }
}

# Function to ensure the target directory exists
function New-DirectoryIfNotExists {
    param (
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        try {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-Host "Created directory: $Path" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to create directory at '$Path': $_"
            exit 1
        }
    }
    else {
        # Check if it's actually a directory
        $item = Get-Item -Path $Path
        if (-not $item.PSIsContainer) {
            Write-Error "Path '$Path' exists but is not a directory."
            exit 1
        }

        # Check read permission
        try {
            $null = Get-ChildItem -Path $Path -ErrorAction Stop
        }
        catch {
            Write-Error "Directory '$Path' is not readable: $_"
            exit 1
        }

        # Check write permission
        try {
            $testFile = Join-Path -Path $Path -ChildPath "write-test-$([Guid]::NewGuid()).tmp"
            $null = New-Item -ItemType File -Path $testFile -Force -ErrorAction Stop
            Remove-Item -Path $testFile -Force -ErrorAction Stop
        }
        catch {
            Write-Error "Directory '$Path' is not writable: $_"
            exit 1
        }
    }
}

# Function to clone a repository if it doesn't exist
function Invoke-RepositoryClone {
    param (
        [string]$RepoName,
        [string]$CloneUrl,
        [string]$BasePath
    )

    $repoPath = Join-Path -Path $BasePath -ChildPath $RepoName

    if (Test-Path -Path $repoPath) {
        # Check if it's a directory
        if (-not (Test-Path -Path $repoPath -PathType Container)) {
            Write-Warning "Path '$repoPath' exists but is not a directory. Cannot clone repository."
            return $null
        }

        # Check if it's a git repo
        if (-not (Test-Path -Path "$repoPath\.git")) {
            Write-Warning "Directory '$repoPath' exists but is not a git repository. Will clone to a different location."
            $repoPath = Join-Path -Path $BasePath -ChildPath "$RepoName-$(Get-Random)"
        }
        else {
            # Check if the origin remote matches the clone URL
            Push-Location $repoPath
            try {
                $originUrl = (git config --get remote.origin.url) 2>$null
                if ($originUrl -and ($originUrl -eq $CloneUrl)) {
                    Write-Host "Repository '$RepoName' already exists at '$repoPath'. Skipping clone." -ForegroundColor Yellow
                    return $repoPath
                }
                else {
                    Write-Warning "Directory '$repoPath' is a git repository but origin URL doesn't match. Will clone to a different location."
                    $repoPath = Join-Path -Path $BasePath -ChildPath "$RepoName-$(Get-Random)"
                }
            }
            finally {
                Pop-Location
            }
        }
    }


    Write-Host "Cloning repository '$RepoName' to '$repoPath'..." -ForegroundColor Cyan
    git clone $CloneUrl $repoPath

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to clone repository '$RepoName'."
        return $null
    }

    return $repoPath
}

# Function to update a repository with all remote branches
function Update-Repository {
    param (
        [string]$RepoPath,
        [string]$RepoName
    )

    if (-not $RepoPath -or -not (Test-Path -Path $RepoPath)) {
        return
    }

    Push-Location $RepoPath

    try {
        Write-Host "Updating repository '$RepoName'..." -ForegroundColor Cyan

        # Fetch all remote branches
        Write-Host "  Fetching all remote branches..." -ForegroundColor DarkCyan
        git fetch --all

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  Failed to fetch remote branches for '$RepoName'."
            return
        }

        # Get current branch
        $currentBranch = git rev-parse --abbrev-ref HEAD

        if ($LASTEXITCODE -ne 0 -or -not $currentBranch) {
            Write-Warning "  Failed to determine current branch for '$RepoName'."
            return
        }

        Write-Host "  Current branch: $currentBranch" -ForegroundColor DarkCyan

        # Try to fast-forward the current branch
        $remoteBranch = "origin/$currentBranch"

        # Check if remote branch exists
        $remoteBranchExists = git ls-remote --heads origin $currentBranch

        if (-not $remoteBranchExists) {
            Write-Host "  Remote branch '$remoteBranch' does not exist. Skipping update." -ForegroundColor Yellow
            return
        }

        # Check if fast-forward is possible
        $mergeBase = git merge-base HEAD $remoteBranch
        $headCommit = git rev-parse HEAD
        $remoteCommit = git rev-parse $remoteBranch

        if ($headCommit -eq $remoteCommit) {
            Write-Host "  Branch '$currentBranch' is already up to date." -ForegroundColor Green
        }
        elseif ($mergeBase -eq $headCommit) {
            # Fast-forward is possible
            Write-Host "  Fast-forwarding branch '$currentBranch'..." -ForegroundColor Green
            git merge --ff-only $remoteBranch

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "  Failed to fast-forward branch '$currentBranch'."
            }
        }
        else {
            # Fast-forward is not possible, perform merge
            Write-Host "  Fast-forward not possible for '$currentBranch'. Attempting merge..." -ForegroundColor Yellow
            git merge $remoteBranch

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "  Merge conflicts detected in '$RepoName' on branch '$currentBranch'. Manual resolution required."
            }
            else {
                Write-Host "  Successfully merged remote changes into '$currentBranch'." -ForegroundColor Green
            }
        }
    }
    finally {
        Pop-Location
    }
}
#endregion Functions

# Main script execution
try {
    # Check if GitHub user is logged in
    Test-GitHubLogin

    # Ensure the repos directory exists
    New-DirectoryIfNotExists -Path $ReposPath

    # Get all non-archived repositories of the current user
    Write-Host "Fetching all non-archived repositories for current GitHub user..." -ForegroundColor Cyan
    $repos = gh repo list --json name,url,isArchived --limit 1000 | ConvertFrom-Json | Where-Object { -not $_.isArchived }

    if (-not $repos -or $repos.Count -eq 0) {
        Write-Host "No repositories found for the current GitHub user." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "Found $($repos.Count) repositories." -ForegroundColor Green

    # Clone and update each repository
    foreach ($repo in $repos) {
        if (-not $repo.url.EndsWith(".git")) {
            $repo.url = "$($repo.url).git"
        }
        $repoPath = Invoke-RepositoryClone -RepoName $repo.name -CloneUrl $repo.url -BasePath $ReposPath
        Update-Repository -RepoPath $repoPath -RepoName $repo.name
    }

    Write-Host "All repositories have been processed successfully." -ForegroundColor Green
}
catch {
    Write-Error "An error occurred: $_"
    exit 1
}
