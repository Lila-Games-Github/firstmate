# Query the Windows host process table for Firstmate harness identity.
# Usage: fm-windows-harness-process.ps1 ancestry
#        fm-windows-harness-process.ps1 alive <pid>
#
# The Bash session-lock owner invokes this only as a Windows/MSYS fallback when
# its Unix process table cannot cross the shell boundary to the host harness.
# ancestry prints "<pid> <harness> <source>" where source is ancestry or
# playbot. The Playbot fallback is allowed only when one Playbot-owned Codex
# app-server exists; Bash separately binds it to the exact persisted thread.
# alive exits 0 only when the exact pid still names a verified harness process.
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("ancestry", "alive")]
    [string]$Mode,

    [Parameter(Position = 1)]
    [int]$TargetPid = 0
)

$ErrorActionPreference = "Stop"

function Get-HarnessName {
    param([object]$Process)

    $name = [System.IO.Path]::GetFileNameWithoutExtension([string]$Process.Name).ToLowerInvariant()
    switch ($name) {
        "claude" { return "claude" }
        "codex" { return "codex" }
        "opencode" { return "opencode" }
        "grok" { return "grok" }
        "kimi" { return "kimi" }
        "pi" { return "pi" }
        "pi-signed" { return "pi" }
    }

    if ($name -like "node*" -or $name -like "python*") {
        $arguments = [string]$Process.CommandLine
        foreach ($harness in @("claude", "codex", "opencode", "grok", "kimi")) {
            if ($arguments.IndexOf($harness, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $harness
            }
        }
    }

    return $null
}

function Get-ProcessTable {
    $table = @{}
    Get-CimInstance Win32_Process | ForEach-Object {
        $table[[int]$_.ProcessId] = $_
    }
    return $table
}

function Find-HarnessAncestry {
    param([hashtable]$Processes)

    $current = $Processes[[int]$PID]
    if (-not $current) {
        return $null
    }

    $processId = [int]$current.ParentProcessId
    $bestProcessId = 0
    $bestHarness = $null
    $extendingClaude = $false

    foreach ($hop in 1..32) {
        if ($processId -le 1 -or -not $Processes.ContainsKey($processId)) {
            break
        }

        $process = $Processes[$processId]
        $harness = Get-HarnessName $process
        if ($harness) {
            $bestProcessId = $processId
            $bestHarness = $harness
            if ($harness -eq "claude") {
                $extendingClaude = $true
            }
            else {
                break
            }
        }
        elseif ($extendingClaude) {
            break
        }

        $processId = [int]$process.ParentProcessId
    }

    if ($bestProcessId -le 1 -or -not $bestHarness) {
        return $null
    }
    return "$bestProcessId $bestHarness ancestry"
}

function Find-PlaybotCodexHost {
    param([hashtable]$Processes)

    if (-not $env:CODEX_THREAD_ID -or -not $env:PLAYBOT_APP_RUN_ID) {
        return $null
    }

    $candidates = @()
    foreach ($process in $Processes.Values) {
        if ((Get-HarnessName $process) -ne "codex") {
            continue
        }
        if ([string]$process.CommandLine -notmatch "(?i)(^|\s)app-server(\s|$)") {
            continue
        }
        $parentId = [int]$process.ParentProcessId
        if (-not $Processes.ContainsKey($parentId)) {
            continue
        }
        $parentName = [System.IO.Path]::GetFileNameWithoutExtension([string]$Processes[$parentId].Name)
        if ($parentName -ne "Playbot") {
            continue
        }
        $candidates += $process
    }

    if ($candidates.Count -ne 1) {
        return $null
    }
    return "$($candidates[0].ProcessId) codex playbot"
}

try {
    if ($Mode -eq "alive") {
        $processes = Get-ProcessTable
        if ($TargetPid -le 1 -or -not $processes.ContainsKey($TargetPid)) {
            exit 1
        }
        if (Get-HarnessName $processes[$TargetPid]) {
            exit 0
        }
        exit 1
    }

    foreach ($attempt in 1..4) {
        $processes = Get-ProcessTable
        $result = Find-HarnessAncestry $processes
        if ($result) {
            Write-Output $result
            exit 0
        }
        if ($attempt -lt 4) {
            Start-Sleep -Milliseconds 75
        }
    }

    $result = Find-PlaybotCodexHost (Get-ProcessTable)
    if ($result) {
        Write-Output $result
        exit 0
    }
    exit 1
}
catch {
    exit 1
}
