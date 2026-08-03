# Shared system and Task Scheduler helpers.

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function ConvertTo-BRAVOProcessArgument {
    param([string]$Value)

    return '"' + $Value.Replace('"', '\"') + '"'
}

function ConvertTo-BRAVOTaskPath {
    param([string]$TaskPath)

    if ([string]::IsNullOrWhiteSpace($TaskPath)) {
        throw "schedulerSettings.TaskPath не налаштовано"
    }

    $trimmed = $TaskPath.Trim().Trim("\")
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return "\"
    }
    if ($trimmed -match '[/:*?"<>|]' -or $trimmed -match '(^|\\)\.\.?($|\\)') {
        throw "Некоректний TaskPath: $TaskPath"
    }
    return "\$trimmed\"
}
