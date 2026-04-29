#description: Generates an on-demand login diagnostics report showing GPO processing times, CSE breakdown, and FSLogix profile load durations from local event logs. Useful for quick troubleshooting without waiting for Log Analytics ingestion.
#execution mode: Individual
#tags: Diagnostics, AVD, Login, GPO, FSLogix, Report

<#notes:
The report is saved as a transcript log on the session host at:
  C:\Windows\Temp\NMWLogs\ScriptedActions\Generate-LoginDiagnosticsReport-<timestamp>.log

After running, retrieve the log file from the VM to review the full output. You can do
this via the NME portal (Files tab on the session host) or by copying it off the VM
directly. The NME job's VM Extension Details panel also shows the script output inline,
but the local log file is retained for later reference.
#>

<#variables:
{
  "HoursBack": {
    "Description": "Number of hours of event log history to analyze.",
    "DisplayName": "Hours of history",
    "IsRequired": false,
    "Type": "string"
  }
}
#>

param(
    [string]$HoursBack
)

$ErrorActionPreference = 'Continue'

$logDir = 'C:\Windows\Temp\NMWLogs\ScriptedActions'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
Start-Transcript -Path "$logDir\Generate-LoginDiagnosticsReport-$(Get-Date -Format 'yyyyMMdd-HHmmss').log" -Append

if ([string]::IsNullOrWhiteSpace($HoursBack)) { $HoursBack = 24 }
$HoursBack = [int]$HoursBack
$startTime = (Get-Date).AddHours(-$HoursBack)

Write-Output "========================================="
Write-Output "AVD Login Diagnostics Report"
Write-Output "========================================="
Write-Output "VM:         $env:COMPUTERNAME"
Write-Output "Generated:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output "Period:     Last $HoursBack hours (since $($startTime.ToString('yyyy-MM-dd HH:mm')))"
Write-Output "========================================="

# =============================================================================
# 1. GP Total Processing Time (Event 8001)
# =============================================================================

Write-Output "`n"
Write-Output "============================================"
Write-Output "  GROUP POLICY - TOTAL PROCESSING TIME"
Write-Output "============================================"

$gpEvents8001 = Get-WinEvent -FilterHashtable @{
    LogName = "Microsoft-Windows-GroupPolicy/Operational"
    Id = 8001
    StartTime = $startTime
} -ErrorAction SilentlyContinue

if ($gpEvents8001) {
    Write-Output "`nFound $($gpEvents8001.Count) GP processing completion event(s):`n"
    Write-Output ("{0,-22} {1,-12} {2,-30} {3,-10} {4}" -f "Time", "Mode", "Principal", "Time(ms)", "Time(sec)")
    Write-Output ("{0,-22} {1,-12} {2,-30} {3,-10} {4}" -f "----", "----", "---------", "--------", "--------")

    $totalMs = 0
    foreach ($evt in $gpEvents8001 | Sort-Object TimeCreated -Descending) {
        $xml = [xml]$evt.ToXml()
        $dataItems = @{}
        foreach ($d in $xml.Event.EventData.Data) {
            $dataItems[$d.Name] = $d.'#text'
        }

        $processingTimeMs = [int]$dataItems['ProcessingTimeInMilliseconds']
        $principal = $dataItems['PrincipalSamName']
        $mode = if ($dataItems['PolicyProcessingMode'] -eq '0') { 'Computer' } else { 'User' }
        $totalMs += $processingTimeMs

        Write-Output ("{0,-22} {1,-12} {2,-30} {3,-10} {4}" -f `
            $evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), `
            $mode, `
            $principal, `
            $processingTimeMs, `
            [math]::Round($processingTimeMs / 1000, 2))
    }

    $avgMs = [math]::Round($totalMs / $gpEvents8001.Count, 0)
    $maxMs = ($gpEvents8001 | ForEach-Object {
        $x = [xml]$_.ToXml()
        [int]($x.Event.EventData.Data | Where-Object { $_.Name -eq 'ProcessingTimeInMilliseconds' }).'#text'
    } | Measure-Object -Maximum).Maximum

    Write-Output ""
    Write-Output "  Summary: Avg=$($avgMs)ms  Max=$($maxMs)ms  Count=$($gpEvents8001.Count)"
    if ($avgMs -gt 10000) {
        Write-Output "  ** WARNING: Average GP processing time exceeds 10 seconds **"
    }
    if ($maxMs -gt 30000) {
        Write-Output "  ** CRITICAL: Max GP processing time exceeds 30 seconds **"
    }
} else {
    Write-Output "`n  No Event 8001 found in the last $HoursBack hours."
    Write-Output "  (No user or computer GP processing has completed in this period)"
}

# =============================================================================
# 2. CSE (Client Side Extension) Breakdown (Events 6003-6007)
# =============================================================================

Write-Output "`n"
Write-Output "============================================"
Write-Output "  GROUP POLICY - CSE BREAKDOWN"
Write-Output "============================================"

$cseEvents = Get-WinEvent -FilterHashtable @{
    LogName = "Microsoft-Windows-GroupPolicy/Operational"
    Id = @(6003, 6004, 6005, 6006, 6007)
    StartTime = $startTime
} -ErrorAction SilentlyContinue

if ($cseEvents) {
    $cseData = @{}
    foreach ($evt in $cseEvents) {
        $xml = [xml]$evt.ToXml()
        $dataItems = @{}
        foreach ($d in $xml.Event.EventData.Data) {
            $dataItems[$d.Name] = $d.'#text'
        }

        $cseName = $dataItems['CSEExtensionName']
        $elapsedMs = [int]$dataItems['ElapsedTimeInMilliseconds']

        if (-not $cseName) { continue }

        if (-not $cseData.ContainsKey($cseName)) {
            $cseData[$cseName] = @{
                Times = @()
                Count = 0
            }
        }
        if ($elapsedMs -gt 0) {
            $cseData[$cseName].Times += $elapsedMs
        }
        $cseData[$cseName].Count++
    }

    Write-Output "`nCSE processing times (sorted by average, descending):`n"
    Write-Output ("{0,-45} {1,-10} {2,-10} {3,-10} {4}" -f "CSE Name", "Avg(ms)", "Max(ms)", "Min(ms)", "Count")
    Write-Output ("{0,-45} {1,-10} {2,-10} {3,-10} {4}" -f "--------", "-------", "-------", "-------", "-----")

    $sortedCses = $cseData.GetEnumerator() | Sort-Object {
        if ($_.Value.Times.Count -gt 0) {
            ($_.Value.Times | Measure-Object -Average).Average
        } else { 0 }
    } -Descending

    foreach ($cse in $sortedCses) {
        if ($cse.Value.Times.Count -gt 0) {
            $stats = $cse.Value.Times | Measure-Object -Average -Maximum -Minimum
            Write-Output ("{0,-45} {1,-10} {2,-10} {3,-10} {4}" -f `
                $cse.Key, `
                [math]::Round($stats.Average, 0), `
                $stats.Maximum, `
                $stats.Minimum, `
                $cse.Value.Count)
        } else {
            Write-Output ("{0,-45} {1,-10} {2,-10} {3,-10} {4}" -f $cse.Key, "N/A", "N/A", "N/A", $cse.Value.Count)
        }
    }

    # Flag slow CSEs
    $slowCses = $sortedCses | Where-Object {
        $_.Value.Times.Count -gt 0 -and ($_.Value.Times | Measure-Object -Average).Average -gt 3000
    }
    if ($slowCses) {
        Write-Output ""
        Write-Output "  ** SLOW CSEs detected (avg > 3 seconds):"
        foreach ($slow in $slowCses) {
            $avg = [math]::Round(($slow.Value.Times | Measure-Object -Average).Average / 1000, 1)
            Write-Output "     - $($slow.Key): avg ${avg}s"
        }
    }
} else {
    Write-Output "`n  No CSE events (6003-6007) found in the last $HoursBack hours."
}

# =============================================================================
# 3. Applied GPOs (Event 5312)
# =============================================================================

Write-Output "`n"
Write-Output "============================================"
Write-Output "  GROUP POLICY - APPLIED GPOs"
Write-Output "============================================"

$gpoListEvents = Get-WinEvent -FilterHashtable @{
    LogName = "Microsoft-Windows-GroupPolicy/Operational"
    Id = 5312
    StartTime = $startTime
} -MaxEvents 5 -ErrorAction SilentlyContinue

if ($gpoListEvents) {
    foreach ($evt in $gpoListEvents | Select-Object -First 3) {
        $xml = [xml]$evt.ToXml()
        $descData = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'DescriptionString' }).'#text'

        Write-Output "`n  [$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] Applied GPOs:"
        if ($descData) {
            $gpoNames = $descData -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { "    - $($_.Trim())" }
            $gpoNames | ForEach-Object { Write-Output $_ }
        }
    }
} else {
    Write-Output "`n  No Event 5312 found in the last $HoursBack hours."
}

# =============================================================================
# 4. FSLogix Profile Load Events
# =============================================================================

Write-Output "`n"
Write-Output "============================================"
Write-Output "  FSLOGIX - PROFILE LOAD EVENTS"
Write-Output "============================================"

# Discover FSLogix log channel
$fslogixLogName = $null
foreach ($candidate in @("Microsoft-FSLogix-Apps/Operational", "FSLogix-Apps/Operational")) {
    if (Get-WinEvent -ListLog $candidate -ErrorAction SilentlyContinue) {
        $fslogixLogName = $candidate
        break
    }
}

if (-not $fslogixLogName) {
    $discovered = Get-WinEvent -ListLog *FSLogix* -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($discovered) { $fslogixLogName = $discovered.LogName }
}

if ($fslogixLogName) {
    Write-Output "  Channel: $fslogixLogName"

    $fslEvents = Get-WinEvent -FilterHashtable @{
        LogName = $fslogixLogName
        StartTime = $startTime
    } -ErrorAction SilentlyContinue

    if ($fslEvents) {
        # Group by key event IDs
        $profileStarts = $fslEvents | Where-Object { $_.Id -eq 25 }
        $profileEnds = $fslEvents | Where-Object { $_.Id -eq 26 }
        $containerAttach = $fslEvents | Where-Object { $_.Id -eq 57 }

        Write-Output "  Profile loads started (Event 25):    $($profileStarts.Count)"
        Write-Output "  Profile loads completed (Event 26):  $($profileEnds.Count)"
        Write-Output "  Container attaches (Event 57):       $($containerAttach.Count)"

        if ($profileEnds) {
            Write-Output "`n  Recent profile load completions:`n"
            Write-Output ("  {0,-22} {1,-25} {2}" -f "Time", "User", "Message")
            Write-Output ("  {0,-22} {1,-25} {2}" -f "----", "----", "-------")

            foreach ($evt in $profileEnds | Sort-Object TimeCreated -Descending | Select-Object -First 10) {
                # Extract user info from message
                $msg = $evt.Message
                $shortMsg = if ($msg.Length -gt 80) { $msg.Substring(0, 80) + "..." } else { $msg }

                Write-Output ("  {0,-22} {1,-25} {2}" -f `
                    $evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), `
                    "", `
                    $shortMsg)
            }
        }

        # Show all FSLogix events with timing info
        Write-Output "`n  All FSLogix events in period (by ID):"
        $fslEvents | Group-Object Id | Sort-Object Name | ForEach-Object {
            $sampleMsg = ($_.Group | Select-Object -First 1).Message
            $shortSample = if ($sampleMsg.Length -gt 60) { $sampleMsg.Substring(0, 60) + "..." } else { $sampleMsg }
            Write-Output "    EventID $($_.Name): $($_.Count) events (e.g., $shortSample)"
        }
    } else {
        Write-Output "  No FSLogix events found in the last $HoursBack hours."
    }

    # Check text logs for additional detail
    Write-Output "`n  --- FSLogix Text Logs ---"
    $logDir = "C:\ProgramData\FSLogix\Logs"
    if (Test-Path $logDir) {
        $profileLogs = Get-ChildItem "$logDir\Profile*.log" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $startTime } |
            Sort-Object LastWriteTime -Descending

        if ($profileLogs) {
            Write-Output "  Recent profile log files:"
            foreach ($log in $profileLogs | Select-Object -First 5) {
                Write-Output "    $($log.Name) ($([math]::Round($log.Length / 1KB, 1)) KB, modified $($log.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"
            }

            # Parse the latest log for timing data
            $latestLog = $profileLogs | Select-Object -First 1
            Write-Output "`n  Key entries from latest log ($($latestLog.Name)):"
            $logContent = Get-Content $latestLog.FullName -ErrorAction SilentlyContinue
            $timingLines = $logContent | Where-Object {
                $_ -match 'LoadProfile|UnloadProfile|attachVHD|detachVHD|seconds|duration|completed' -and $_ -notmatch '^\s*$'
            } | Select-Object -Last 20
            foreach ($line in $timingLines) {
                Write-Output "    $line"
            }
        } else {
            Write-Output "  No recent profile log files found."
        }
    } else {
        Write-Output "  Log directory not found: $logDir"
    }
} else {
    Write-Output "  FSLogix event log not found on this VM."
    Write-Output "  FSLogix may not be installed."
}

# =============================================================================
# 5. gpresult summary
# =============================================================================

Write-Output "`n"
Write-Output "============================================"
Write-Output "  GPRESULT SUMMARY"
Write-Output "============================================"

# Get computer policy summary
$gpresultOutput = gpresult /r /scope:computer 2>&1

$inAppliedSection = $false
$appliedGpos = @()
foreach ($line in $gpresultOutput) {
    if ($line -match 'Applied Group Policy Objects') {
        $inAppliedSection = $true
        continue
    }
    if ($inAppliedSection) {
        if ($line -match '^\s*$' -or $line -match '^\S') {
            $inAppliedSection = $false
            continue
        }
        $gpoName = $line.Trim()
        if ($gpoName) { $appliedGpos += $gpoName }
    }
}

if ($appliedGpos) {
    Write-Output "`n  Applied Computer GPOs ($($appliedGpos.Count)):"
    foreach ($gpo in $appliedGpos) {
        Write-Output "    - $gpo"
    }
} else {
    Write-Output "  Could not parse applied GPOs from gpresult."
}

# =============================================================================
# Summary & Recommendations
# =============================================================================

Write-Output "`n"
Write-Output "========================================="
Write-Output "  RECOMMENDATIONS"
Write-Output "========================================="

$recommendations = @()

if ($gpEvents8001) {
    $maxGpMs = ($gpEvents8001 | ForEach-Object {
        $x = [xml]$_.ToXml()
        [int]($x.Event.EventData.Data | Where-Object { $_.Name -eq 'ProcessingTimeInMilliseconds' }).'#text'
    } | Measure-Object -Maximum).Maximum

    if ($maxGpMs -gt 30000) {
        $recommendations += "CRITICAL: GP processing exceeds 30s. Check CSE breakdown above for the slowest extensions."
    } elseif ($maxGpMs -gt 10000) {
        $recommendations += "WARNING: GP processing exceeds 10s. Review applied GPOs and consider using loopback processing or WMI filters."
    }
}

if ($slowCses) {
    foreach ($slow in $slowCses) {
        $cseName = $slow.Key
        $avgSec = [math]::Round(($slow.Value.Times | Measure-Object -Average).Average / 1000, 1)
        switch -Wildcard ($cseName) {
            "*Drive Maps*"         { $recommendations += "Slow drive mapping (${avgSec}s avg): Check if mapped drives are reachable and consider using GP Preferences Item-Level Targeting." }
            "*Folder Redirection*" { $recommendations += "Slow folder redirection (${avgSec}s avg): Check network path accessibility and ensure redirected folders are on a fast, nearby file server." }
            "*Scripts*"            { $recommendations += "Slow logon scripts (${avgSec}s avg): Review logon scripts for unnecessary operations, timeouts, or network dependencies." }
            "*Registry*"           { $recommendations += "Slow registry policy (${avgSec}s avg): Large number of registry preferences. Consider consolidating or using Administrative Templates instead." }
            "*Preferences*"        { $recommendations += "Slow GP Preferences (${avgSec}s avg): Review GP Preference items for unnecessary entries or unreachable targets." }
            default                { $recommendations += "Slow CSE '$cseName' (${avgSec}s avg): Investigate this policy extension for performance issues." }
        }
    }
}

if ($recommendations.Count -eq 0) {
    Write-Output "  No critical issues detected in the analyzed time period."
    Write-Output "  GP processing times appear within normal range."
} else {
    foreach ($rec in $recommendations) {
        Write-Output "  * $rec"
    }
}

Write-Output "`n========================================="
Write-Output "  Report Complete"
Write-Output "========================================="

Stop-Transcript
