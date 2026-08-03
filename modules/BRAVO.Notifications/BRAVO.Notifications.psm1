# Shared BRAVO notification helpers with an explicit Compatibility dependency.

$compatibilityManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'BRAVO.Compatibility\BRAVO.Compatibility.psd1'
Import-Module -Name $compatibilityManifest -ErrorAction Stop

function Get-HostInformation {
    if ($null -ne $script:CachedHostInformation) {
        return $script:CachedHostInformation
    }

    $machineName = [Environment]::MachineName
    $localAddresses = @()

    try {
        $adapterAddresses = Get-BRAVOWmiInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled = TRUE" |
            ForEach-Object { @($_.IPAddress) }

        foreach ($address in $adapterAddresses) {
            $parsedAddress = $null
            if ([System.Net.IPAddress]::TryParse([string]$address, [ref]$parsedAddress) -and
                $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                -not [System.Net.IPAddress]::IsLoopback($parsedAddress) -and
                -not ([string]$address).StartsWith("169.254.")) {
                $localAddresses += [string]$address
            }
        }
    } catch {
        try {
            $localAddresses = @(
                [System.Net.Dns]::GetHostAddresses($machineName) |
                    Where-Object {
                        $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                        -not [System.Net.IPAddress]::IsLoopback($_) -and
                        -not $_.ToString().StartsWith("169.254.")
                    } |
                    ForEach-Object { $_.ToString() }
            )
        } catch {
            $localAddresses = @()
        }
    }

    $localAddressText = if ($localAddresses.Count -gt 0) {
        (@($localAddresses | Sort-Object -Unique) -join ", ")
    } else {
        "недоступна"
    }

    $lookupEnabled = $true
    $lookupUrls = @("https://api.ipify.org")
    $lookupTimeoutSeconds = 5
    if ($hostInformationSettings -is [System.Collections.IDictionary]) {
        if ($hostInformationSettings.Contains("PublicIPLookupEnabled")) {
            $lookupEnabled = [System.Convert]::ToBoolean($hostInformationSettings.PublicIPLookupEnabled)
        }
        if ($hostInformationSettings.Contains("PublicIPLookupUrls")) {
            $configuredUrls = @($hostInformationSettings.PublicIPLookupUrls | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_)
            })
            if ($configuredUrls.Count -gt 0) {
                $lookupUrls = $configuredUrls
            }
        }
        if ($hostInformationSettings.Contains("PublicIPLookupTimeoutSeconds")) {
            $lookupTimeoutSeconds = [math]::Max(
                1,
                [int]$hostInformationSettings.PublicIPLookupTimeoutSeconds
            )
        }
    }

    $publicAddressText = if ($lookupEnabled) { "недоступна" } else { "вимкнено" }
    if ($lookupEnabled) {
        foreach ($lookupUrl in $lookupUrls) {
            $response = $null
            $reader = $null
            try {
                $request = [System.Net.WebRequest]::Create([string]$lookupUrl)
                $request.Method = "GET"
                $request.Timeout = $lookupTimeoutSeconds * 1000
                $request.ReadWriteTimeout = $lookupTimeoutSeconds * 1000
                $response = $request.GetResponse()
                $reader = New-Object System.IO.StreamReader(
                    $response.GetResponseStream(),
                    [System.Text.Encoding]::UTF8
                )
                $candidateAddress = $reader.ReadToEnd().Trim()
                $parsedPublicAddress = $null
                if ([System.Net.IPAddress]::TryParse($candidateAddress, [ref]$parsedPublicAddress)) {
                    $publicAddressText = $candidateAddress
                    break
                }
            } catch {
                # Недоступність зовнішнього сервісу не впливає на health-check.
            } finally {
                if ($reader) { $reader.Dispose() }
                if ($response) { $response.Dispose() }
            }
        }
    }

    $script:CachedHostInformation = [pscustomobject]@{
        MachineName = $machineName
        LocalIP = $localAddressText
        PublicIP = $publicAddressText
    }
    return $script:CachedHostInformation
}

function ConvertTo-DiscordNotificationText {
    param([string]$Message)

    $emojiReplacements = [ordered]@{
        ":rotating_light:" = "🚨"
        ":derelict_house_building:" = "🏚️"
        ":desktop_computer:" = "🖥️"
        ":globe_with_meridians:" = "🌐"
        ":spiral_calendar_pad:" = "🗓️"
        ":alarm_clock:" = "⏰"
        ":hourglass_flowing_sand:" = "⏳"
        ":pushpin:" = "📌"
        ":cloud:" = "☁️"
        ":warning:" = "⚠️"
        ":file_folder:" = "📁"
        ":page_facing_up:" = "📄"
        ":clock3:" = "🕒"
        ":outbox_tray:" = "📤"
        ":inbox_tray:" = "📥"
        ":arrows_counterclockwise:" = "🔄"
        ":twisted_rightwards_arrows:" = "🔀"
        ":bar_chart:" = "📊"
        ":satellite_antenna:" = "📡"
        ":floppy_disk:" = "💾"
        ":memo:" = "📝"
        ":white_check_mark:" = "✅"
        ":package:" = "📦"
        ":minidisc:" = "💽"
        ":satellite:" = "🛰️"
        ":wrench:" = "🔧"
        ":x:" = "❌"
    }

    $discordMessage = $Message
    foreach ($replacement in $emojiReplacements.GetEnumerator()) {
        $discordMessage = $discordMessage.Replace($replacement.Key, $replacement.Value)
    }

    return [regex]::Replace(
        $discordMessage,
        '(?m)(?<!\*)\*([^*\r\n]+)\*(?!\*)',
        '**$1**'
    )
}

function Split-DiscordNotificationText {
    param(
        [string]$Message,
        [int]$MaximumLength = 1900
    )

    $chunks = New-Object 'System.Collections.Generic.List[string]'
    $currentChunk = New-Object System.Text.StringBuilder

    foreach ($line in ($Message -split "\r?\n")) {
        $remainingLine = [string]$line
        do {
            $availableLength = $MaximumLength - $currentChunk.Length
            if ($currentChunk.Length -gt 0) {
                $availableLength -= [Environment]::NewLine.Length
            }

            if ($availableLength -le 0) {
                $chunks.Add($currentChunk.ToString())
                $null = $currentChunk.Clear()
                continue
            }

            $partLength = [math]::Min($availableLength, $remainingLine.Length)
            $linePart = $remainingLine.Substring(0, $partLength)
            if ($currentChunk.Length -gt 0) {
                [void]$currentChunk.AppendLine()
            }
            [void]$currentChunk.Append($linePart)
            $remainingLine = $remainingLine.Substring($partLength)

            if ($remainingLine.Length -gt 0) {
                $chunks.Add($currentChunk.ToString())
                $null = $currentChunk.Clear()
            }
        } while ($remainingLine.Length -gt 0)
    }

    if ($currentChunk.Length -gt 0 -or $chunks.Count -eq 0) {
        $chunks.Add($currentChunk.ToString())
    }
    return $chunks.ToArray()
}
