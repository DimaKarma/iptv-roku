# tools/install-hooks.ps1 and the pre-push hook it writes. The hook is run with Git for
# Windows sh against a stub scanner in a throwaway repository under $TestDrive, so the
# real scanner, the real repository and the real secrets are never involved.
$projectRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $projectRoot 'tools\install-hooks.ps1'

# GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE, inherited from a parent git process (a hook, an
# alias), make every git call below act on THAT repository instead of the throwaway one.
# Clear them for the test and put them back afterwards.
function Push-CleanGitEnv {
    $saved = @{}
    foreach ($name in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE')) {
        $saved[$name] = [System.Environment]::GetEnvironmentVariable($name)
        [System.Environment]::SetEnvironmentVariable($name, $null)
    }
    return $saved
}
function Pop-CleanGitEnv($saved) {
    foreach ($name in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE')) {
        [System.Environment]::SetEnvironmentVariable($name, $saved[$name])
    }
}

function Get-ThrownMessage([scriptblock] $block) {
    try { & $block } catch { return $_.Exception.Message }
    return $null
}

# git runs a hook with the repository root as its working directory, so do the same.
function Invoke-Hook([string] $sh, [string] $hook, [string] $repo, [string] $line) {
    Push-Location $repo
    try {
        $out = ($line | & $sh $hook origin 2>&1 | Out-String)
        return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
    } finally {
        Pop-Location
    }
}

function Find-GitSh {
    $git = (Get-Command git -ErrorAction Stop).Source
    $base = Split-Path -Parent (Split-Path -Parent $git)
    foreach ($rel in @('bin\sh.exe', 'usr\bin\sh.exe')) {
        $c = Join-Path $base $rel
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

Describe 'git environment isolation' {
    It 'clears the git variables for the test, makes git work on the throwaway repository, and restores them' {
        $env:GIT_DIR = 'bogus-dir'
        $env:GIT_WORK_TREE = 'bogus-tree'
        $env:GIT_INDEX_FILE = 'bogus-index'
        $saved = $null
        try {
            $saved = Push-CleanGitEnv
            $env:GIT_DIR | Should BeNullOrEmpty
            $env:GIT_WORK_TREE | Should BeNullOrEmpty
            $env:GIT_INDEX_FILE | Should BeNullOrEmpty
            $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $repo | Out-Null
            & git -C $repo init -q 2>&1 | Out-Null
            (Test-Path -LiteralPath (Join-Path $repo '.git')) | Should Be $true
            Pop-CleanGitEnv $saved
            $saved = $null
            $env:GIT_DIR | Should Be 'bogus-dir'
            $env:GIT_WORK_TREE | Should Be 'bogus-tree'
            $env:GIT_INDEX_FILE | Should Be 'bogus-index'
        } finally {
            $env:GIT_DIR = $null
            $env:GIT_WORK_TREE = $null
            $env:GIT_INDEX_FILE = $null
        }
    }
}

Describe 'install-hooks.ps1' {
    BeforeEach {
        $savedGitEnv = Push-CleanGitEnv
        $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $repo | Out-Null
        & git -C $repo init -q 2>&1 | Out-Null
        $hook = Join-Path $repo '.git\hooks\pre-push'
    }
    AfterEach {
        Pop-CleanGitEnv $savedGitEnv
    }

    It 'writes a POSIX sh hook with LF endings and no byte order mark' {
        & $installer -RepoRoot $repo | Out-Null
        (Test-Path -LiteralPath $hook) | Should Be $true
        $bytes = [System.IO.File]::ReadAllBytes($hook)
        $bytes[0] | Should Be 0x23
        $bytes[1] | Should Be 0x21
        (@($bytes | Where-Object { $_ -eq 13 }).Count) | Should Be 0
        [System.IO.File]::ReadAllText($hook) | Should Match 'installed by tools/install-hooks.ps1'
    }

    It 'never overwrites a pre-push hook it did not write' {
        New-Item -ItemType Directory -Path (Split-Path -Parent $hook) -Force | Out-Null
        [System.IO.File]::WriteAllText($hook, "#!/bin/sh`necho foreign`n")
        $msg = Get-ThrownMessage { & $installer -RepoRoot $repo }
        $msg | Should Match 'refusing to overwrite'
        [System.IO.File]::ReadAllText($hook) | Should Match 'foreign'
    }

    It 'disables the hook by renaming it, deleting nothing' {
        & $installer -RepoRoot $repo | Out-Null
        & $installer -RepoRoot $repo -Uninstall | Out-Null
        (Test-Path -LiteralPath $hook) | Should Be $false
        (Test-Path -LiteralPath ($hook + '.disabled')) | Should Be $true
    }
}

Describe 'pre-push hook behaviour' {
    BeforeEach {
        $savedGitEnv = Push-CleanGitEnv
        $sh = Find-GitSh
        $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path (Join-Path $repo 'tools') -Force | Out-Null
        & git -C $repo init -q 2>&1 | Out-Null
        & $installer -RepoRoot $repo | Out-Null
        $hook = Join-Path $repo '.git\hooks\pre-push'
        $log = Join-Path $repo 'args.log'
        # A stub scanner: records its arguments and the secrets dir it was given, and exits
        # with the code in STUB_RC.
        $stub = @'
import os, sys
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "args.log"), "a") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\n")
sys.exit(int(os.environ.get("STUB_RC", "0")))
'@
        [System.IO.File]::WriteAllText((Join-Path $repo 'tools\check_secrets.py'), $stub)
        $sha = 'a' * 40
        $zero = '0' * 40
        $env:STUB_RC = '0'
        $env:CHECK_SECRETS_DIR = $null
    }
    AfterEach {
        $env:STUB_RC = $null
        $env:CHECK_SECRETS_DIR = $null
        Pop-CleanGitEnv $savedGitEnv
    }

    It 'finds a POSIX shell to run the hook with' {
        $sh | Should Not BeNullOrEmpty
    }

    It 'scans the pushed sha against the remote and lets a clean scan through' {
        $line = "refs/heads/main $sha refs/heads/main $zero`n"
        $r = Invoke-Hook $sh $hook $repo $line
        $r.Exit | Should Be 0
        (Get-Content -LiteralPath $log) | Should Be "$sha --not --remotes=origin"
    }

    It 'skips an all-zero local sha because a deletion publishes nothing' {
        $line = "(delete) $zero refs/heads/old $sha`n"
        $r = Invoke-Hook $sh $hook $repo $line
        $r.Exit | Should Be 0
        (Test-Path -LiteralPath $log) | Should Be $false
    }

    It 'refuses the push on a scanner failure and names the ref' {
        $env:STUB_RC = '1'
        $line = "refs/tags/v9 $sha refs/tags/v9 $zero`n"
        $r = Invoke-Hook $sh $hook $repo $line
        $r.Exit | Should Not Be 0
        $r.Out | Should Match 'REFUSING refs/tags/v9'
    }

    It 'refuses the push when the scanner could not run (exit 3)' {
        $env:STUB_RC = '3'
        $line = "refs/heads/main $sha refs/heads/main $zero`n"
        $r = Invoke-Hook $sh $hook $repo $line
        $r.Exit | Should Not Be 0
    }

    It 'checks every ref of a multi-ref push and refuses if any fails' {
        $sha2 = 'b' * 40
        $line = "refs/heads/a $sha refs/heads/a $zero`nrefs/heads/b $sha2 refs/heads/b $zero`n"
        $env:STUB_RC = '1'
        $r = Invoke-Hook $sh $hook $repo $line
        $r.Exit | Should Not Be 0
        @(Get-Content -LiteralPath $log).Count | Should Be 2
    }

    It 'forwards CHECK_SECRETS_DIR as --secrets-dir for tests' {
        $env:CHECK_SECRETS_DIR = 'fakedir'
        $line = "refs/heads/main $sha refs/heads/main $zero`n"
        $r = Invoke-Hook $sh $hook $repo $line
        (Get-Content -LiteralPath $log) | Should Be "--secrets-dir fakedir $sha --not --remotes=origin"
    }

    It 'warns on stderr, without the value, whenever CHECK_SECRETS_DIR is set' {
        $env:CHECK_SECRETS_DIR = 'fakedir-secret-name'
        $line = "refs/heads/main $sha refs/heads/main $zero`n"
        $r = Invoke-Hook $sh $hook $repo $line
        $r.Exit | Should Be 0
        $r.Out | Should Match 'WARNING: scanning with CHECK_SECRETS_DIR=<set> \(test override\)'
        $r.Out | Should Not Match 'fakedir-secret-name'
    }

    It 'prints no override warning when CHECK_SECRETS_DIR is unset' {
        $line = "refs/heads/main $sha refs/heads/main $zero`n"
        $r = Invoke-Hook $sh $hook $repo $line
        $r.Out | Should Not Match 'CHECK_SECRETS_DIR'
    }

    It 'refuses a local sha that is not 40 hex characters and never calls the scanner' {
        foreach ($bad in @('abc123', ('g' * 40), ('a' * 41), ('a' * 39))) {
            if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }
            $line = "refs/heads/main $bad refs/heads/main $zero`n"
            $r = Invoke-Hook $sh $hook $repo $line
            $r.Exit | Should Not Be 0
            $r.Out | Should Match 'REFUSING refs/heads/main'
            $r.Out | Should Match 'not 40 hex characters'
            (Test-Path -LiteralPath $log) | Should Be $false
        }
    }

    It 'accepts an upper-case 40 hex sha' {
        $upper = 'A' * 40
        $line = "refs/heads/main $upper refs/heads/main $zero`n"
        $r = Invoke-Hook $sh $hook $repo $line
        $r.Exit | Should Be 0
    }
}
