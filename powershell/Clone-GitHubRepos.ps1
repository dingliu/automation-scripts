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

    # Add .git to the target repository path
    $repoPath = Join-Path -Path $BasePath -ChildPath "$RepoName.git"

    if (Test-Path -Path $repoPath) {
        # Check if it's a directory and a git repo
        if ((Test-Path -Path $repoPath -PathType Container) -and (Test-Path -Path "$repoPath\config")) {
            # Check if it's a mirror clone
            Push-Location $repoPath
            try {
                $isMirror = git config --get remote.origin.mirror 2>$null
                $originUrl = git config --get remote.origin.url 2>$null

                if ($isMirror -eq "true" -and $originUrl -eq $CloneUrl) {
                    Write-Host "Mirror repository '$RepoName' already exists at '$repoPath'. Updating instead of cloning." -ForegroundColor Yellow
                    Update-Repository -RepoPath $repoPath -RepoName $RepoName
                    return $repoPath
                } else {
                    Write-Host "Repository at '$repoPath' exists but is not a mirror of '$CloneUrl'. Removing and re-cloning." -ForegroundColor Yellow
                    Pop-Location
                    Remove-Item -Path $repoPath -Recurse -Force
                }
            }
            catch {
                Write-Warning "Error checking repository status: $_"
                Pop-Location
                Remove-Item -Path $repoPath -Recurse -Force
            }
        } else {
            # Path exists but is not a proper git repository
            Write-Host "Path '$repoPath' exists but is not a valid git repository. Removing and re-cloning." -ForegroundColor Yellow
            Remove-Item -Path $repoPath -Recurse -Force
        }
    }

    # Perform mirror clone
    Write-Host "Mirror cloning repository '$RepoName' to '$repoPath'..." -ForegroundColor Cyan
    git clone --mirror $CloneUrl $repoPath

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to mirror clone repository '$RepoName'."
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
        git fetch --prune --prune-tags origin

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  Failed to fetch remote branches for '$RepoName'."
            return
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
