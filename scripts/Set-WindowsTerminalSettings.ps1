<#
.SYNOPSIS
Configures the managed Windows Terminal keybindings without replacing the user's settings.

.DESCRIPTION
Locates the settings.json files for installed Windows Terminal channels and ensures that Ctrl+V is
unbound from Windows Terminal while Ctrl+Shift+V remains bound to Terminal's immediate paste
action. This lets Ctrl+V reach PSReadLine, whose Paste handler inserts an entire multiline clipboard
block into the editable command buffer and waits for Enter.

Windows Terminal settings files use JSON with comments and trailing commas (JSONC). This script
tokenizes the existing source and applies narrow text edits instead of deserializing and
reserializing the complete document. Existing comments, property order, formatting, and
machine-specific profiles remain intact. Newly inserted bindings include comments explaining why
they are managed.

Windows Terminal JSON fragments are intentionally insufficient for this change:

- Fragments support new profiles, updates to supported existing profiles, and color schemes.
- Current Terminal implementations also load fragment actions into the command palette.
- Fragment keybindings are deliberately ignored so installed applications cannot silently claim
  user keyboard shortcuts.
- Profile defaults, themes, and general root settings are not loaded from fragments.

Consequently, the Ctrl+V bindings must be written to the root settings.json file. See:

https://learn.microsoft.com/windows/terminal/json-fragment-extensions
https://github.com/microsoft/terminal/issues/17240
https://github.com/microsoft/terminal/blob/main/src/cascadia/TerminalSettingsModel/CascadiaSettingsSerialization.cpp
https://github.com/nanoDBA/WindowsTerminal-SafePaste

The multiline-paste warning settings are not changed. Those settings only control confirmation
prompts and do not make Terminal's immediate paste action insert multiline input atomically.

.PARAMETER SettingsPath
Specifies one or more settings.json files explicitly. When omitted, the script discovers existing
packaged channels, including Stable, Preview, and Canary, plus unpackaged Windows Terminal
settings. By default, it updates the most recently modified settings file. If no settings file
exists yet, it uses the installation directory modified most recently.

.PARAMETER AllTerminalSettings
Updates every discovered Windows Terminal settings file. When no settings file exists yet, creates
one for every installed channel that can be discovered.

.PARAMETER Replace
Allows existing explicit Ctrl+V or Ctrl+Shift+V bindings to be unbound and replaced. Missing
bindings are added without this switch. Every changed existing settings file is backed up before it
is replaced.

.PARAMETER Check
Reports whether each discovered settings file has the required bindings without making changes.
The script exits with code 1 when invoked directly and any settings file is missing or conflicting.

.PARAMETER PassThru
Returns structured state objects and suppresses the direct-invocation exit behavior. This is used
by Install-Dotfiles.ps1 to include Windows Terminal state in its own check and conflict handling.

.PARAMETER WhatIf
Displays a unified diff of the current and proposed settings before PowerShell reports the planned
write. Git is used only to render the diff from temporary files under the system temporary
directory; no file is created beside settings.json and no backup is created.

.EXAMPLE
pwsh -NoProfile -File .\scripts\Set-WindowsTerminalSettings.ps1 -Check

Checks the discovered Windows Terminal settings files.

.EXAMPLE
pwsh -NoProfile -File .\scripts\Set-WindowsTerminalSettings.ps1 -Replace -WhatIf

Previews changes required to replace conflicting keybindings.

.EXAMPLE
pwsh -NoProfile -File .\scripts\Set-WindowsTerminalSettings.ps1 -Replace

Updates the discovered settings files and backs up each existing file that changes.

.EXAMPLE
pwsh -NoProfile -File .\scripts\Set-WindowsTerminalSettings.ps1 -AllTerminalSettings -Replace

Updates every discovered Windows Terminal channel.

.OUTPUTS
With PassThru, objects describing the path, state, reason, and resulting backup are returned.
Otherwise, status is written to the host.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$SettingsPath,

    [switch]$AllTerminalSettings,

    [switch]$Replace,

    [switch]$Check,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$managedBindings = @(
    [pscustomobject]@{
        Chord = "ctrl+v"
        Command = "unbound"
        Comment = "Let PSReadLine handle Ctrl+V so multiline input remains editable."
    },
    [pscustomobject]@{
        Chord = "ctrl+shift+v"
        Command = "paste"
        Comment = "Keep Ctrl+Shift+V as Windows Terminal's direct paste shortcut."
    }
)

function Resolve-WindowsTerminalSettingsPath {
    $explicitSettingsPaths = @(
        $SettingsPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($explicitSettingsPaths.Count -gt 0) {
        return @(
            $explicitSettingsPaths |
                ForEach-Object { [System.IO.Path]::GetFullPath($_) } |
                Select-Object -Unique
        )
    }

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw "LOCALAPPDATA is not defined, so Windows Terminal settings cannot be located."
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    $packagesDirectory = Join-Path $env:LOCALAPPDATA "Packages"
    if (Test-Path -LiteralPath $packagesDirectory -PathType Container) {
        foreach ($packageDirectory in @(
            Get-ChildItem `
                -LiteralPath $packagesDirectory `
                -Directory `
                -Filter "Microsoft.WindowsTerminal*8wekyb3d8bbwe" `
                -ErrorAction SilentlyContinue
        )) {
            $candidates.Add([pscustomobject]@{
                Path = Join-Path $packageDirectory.FullName "LocalState\settings.json"
                InstallationPath = $packageDirectory.FullName
            })
        }
    }

    $candidates.Add(
        [pscustomobject]@{
            Path = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\settings.json"
            InstallationPath = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal"
        }
    )

    $existingSettings = @(
        $candidates |
            Where-Object { Test-Path -LiteralPath $_.Path -PathType Leaf }
    )
    if ($existingSettings.Count -gt 0) {
        if ($AllTerminalSettings) {
            return @($existingSettings | ForEach-Object { $_.Path })
        }

        return @(
            $existingSettings |
                Sort-Object {
                    (Get-Item -LiteralPath $_.Path -Force).LastWriteTimeUtc
                } -Descending |
                Select-Object -First 1 |
                ForEach-Object { $_.Path }
        )
    }

    $installedChannels = @(
        $candidates |
            Where-Object { Test-Path -LiteralPath $_.InstallationPath -PathType Container }
    )
    if ($installedChannels.Count -gt 0) {
        if ($AllTerminalSettings) {
            return @($installedChannels | ForEach-Object { $_.Path })
        }

        return @(
            $installedChannels |
                Sort-Object {
                    (Get-Item -LiteralPath $_.InstallationPath -Force).LastWriteTimeUtc
                } -Descending |
                Select-Object -First 1 |
                ForEach-Object { $_.Path }
        )
    }

    throw (
        "Unable to locate an installed Windows Terminal channel. Install or launch Windows " +
        "Terminal first, or provide -SettingsPath explicitly."
    )
}

function New-JsoncToken {
    param(
        [Parameter(Mandatory)]
        [string]$Kind,

        [Parameter(Mandatory)]
        [int]$Start,

        [Parameter(Mandatory)]
        [int]$End,

        [AllowNull()]
        [object]$Value
    )

    [pscustomobject]@{
        Kind = $Kind
        Start = $Start
        End = $End
        Value = $Value
    }
}

function Get-JsoncTokens {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $tokens = [System.Collections.Generic.List[object]]::new()
    $index = 0

    while ($index -lt $Text.Length) {
        $character = $Text[$index]

        if ([char]::IsWhiteSpace($character)) {
            $index++
            continue
        }

        if ($character -eq "/" -and $index + 1 -lt $Text.Length) {
            $nextCharacter = $Text[$index + 1]
            if ($nextCharacter -eq "/") {
                $index += 2
                while ($index -lt $Text.Length -and $Text[$index] -ne "`r" -and $Text[$index] -ne "`n") {
                    $index++
                }

                continue
            }

            if ($nextCharacter -eq "*") {
                $commentStart = $index
                $index += 2
                while (
                    $index + 1 -lt $Text.Length -and
                    -not ($Text[$index] -eq "*" -and $Text[$index + 1] -eq "/")
                ) {
                    $index++
                }

                if ($index + 1 -ge $Text.Length) {
                    throw "Unterminated block comment at character $commentStart."
                }

                $index += 2
                continue
            }
        }

        if ($character -eq '"') {
            $stringStart = $index
            $index++
            $escaped = $false
            while ($index -lt $Text.Length) {
                $stringCharacter = $Text[$index]
                if ($escaped) {
                    $escaped = $false
                }
                elseif ($stringCharacter -eq "\") {
                    $escaped = $true
                }
                elseif ($stringCharacter -eq '"') {
                    $index++
                    break
                }
                elseif ([int]$stringCharacter -lt 0x20) {
                    throw "Invalid control character in a JSON string at character $index."
                }

                $index++
            }

            if ($index -gt $Text.Length -or $Text[$index - 1] -ne '"') {
                throw "Unterminated JSON string at character $stringStart."
            }

            $rawString = $Text.Substring($stringStart, $index - $stringStart)
            $decodedString = ConvertFrom-Json -InputObject $rawString
            $tokens.Add((New-JsoncToken -Kind "String" -Start $stringStart -End $index -Value $decodedString))
            continue
        }

        if ("{}[]:,".Contains($character)) {
            $tokens.Add((New-JsoncToken -Kind "Punctuation" -Start $index -End ($index + 1) -Value ([string]$character)))
            $index++
            continue
        }

        $literalStart = $index
        while (
            $index -lt $Text.Length -and
            -not [char]::IsWhiteSpace($Text[$index]) -and
            -not "{}[]:,".Contains($Text[$index])
        ) {
            if (
                $Text[$index] -eq "/" -and
                $index + 1 -lt $Text.Length -and
                ($Text[$index + 1] -eq "/" -or $Text[$index + 1] -eq "*")
            ) {
                break
            }

            $index++
        }

        if ($index -eq $literalStart) {
            throw "Unexpected character '$character' at character $index."
        }

        $literal = $Text.Substring($literalStart, $index - $literalStart)
        $tokens.Add((New-JsoncToken -Kind "Literal" -Start $literalStart -End $index -Value $literal))
    }

    $tokens
}

function Get-JsoncValueEndTokenIndex {
    param(
        [Parameter(Mandatory)]
        [object[]]$Tokens,

        [Parameter(Mandatory)]
        [int]$StartIndex
    )

    $startToken = $Tokens[$StartIndex]
    if ($startToken.Value -ne "{" -and $startToken.Value -ne "[") {
        return $StartIndex
    }

    $stack = [System.Collections.Generic.Stack[string]]::new()
    for ($index = $StartIndex; $index -lt $Tokens.Count; $index++) {
        $value = $Tokens[$index].Value
        if ($value -eq "{") {
            $stack.Push("}")
        }
        elseif ($value -eq "[") {
            $stack.Push("]")
        }
        elseif ($value -eq "}" -or $value -eq "]") {
            if ($stack.Count -eq 0 -or $stack.Pop() -ne $value) {
                throw "Mismatched JSON delimiter at character $($Tokens[$index].Start)."
            }

            if ($stack.Count -eq 0) {
                return $index
            }
        }
    }

    throw "Unterminated JSON value at character $($startToken.Start)."
}

function Get-JsoncObjectProperties {
    param(
        [Parameter(Mandatory)]
        [object[]]$Tokens,

        [Parameter(Mandatory)]
        [int]$ObjectStartIndex
    )

    if ($Tokens[$ObjectStartIndex].Value -ne "{") {
        throw "Expected a JSON object at character $($Tokens[$ObjectStartIndex].Start)."
    }

    $objectEndIndex = Get-JsoncValueEndTokenIndex -Tokens $Tokens -StartIndex $ObjectStartIndex
    $properties = [System.Collections.Generic.List[object]]::new()
    $index = $ObjectStartIndex + 1

    while ($index -lt $objectEndIndex) {
        if ($Tokens[$index].Value -eq "}") {
            break
        }

        if ($Tokens[$index].Kind -ne "String") {
            throw "Expected a JSON property name at character $($Tokens[$index].Start)."
        }

        $nameTokenIndex = $index
        $index++
        if ($index -ge $objectEndIndex -or $Tokens[$index].Value -ne ":") {
            throw "Expected ':' after JSON property '$($Tokens[$nameTokenIndex].Value)'."
        }

        $index++
        if ($index -ge $objectEndIndex) {
            throw "Missing value for JSON property '$($Tokens[$nameTokenIndex].Value)'."
        }

        $valueStartIndex = $index
        $valueEndIndex = Get-JsoncValueEndTokenIndex -Tokens $Tokens -StartIndex $valueStartIndex
        $index = $valueEndIndex + 1
        $commaTokenIndex = $null

        if ($index -lt $objectEndIndex -and $Tokens[$index].Value -eq ",") {
            $commaTokenIndex = $index
            $index++
        }
        elseif ($index -lt $objectEndIndex -and $Tokens[$index].Value -ne "}") {
            throw "Expected ',' after JSON property '$($Tokens[$nameTokenIndex].Value)'."
        }

        $properties.Add([pscustomobject]@{
            Name = [string]$Tokens[$nameTokenIndex].Value
            NameTokenIndex = $nameTokenIndex
            ValueStartIndex = $valueStartIndex
            ValueEndIndex = $valueEndIndex
            CommaTokenIndex = $commaTokenIndex
        })
    }

    [pscustomobject]@{
        StartTokenIndex = $ObjectStartIndex
        EndTokenIndex = $objectEndIndex
        Properties = @($properties)
    }
}

function Get-JsoncArrayElements {
    param(
        [Parameter(Mandatory)]
        [object[]]$Tokens,

        [Parameter(Mandatory)]
        [int]$ArrayStartIndex
    )

    if ($Tokens[$ArrayStartIndex].Value -ne "[") {
        throw "Expected a JSON array at character $($Tokens[$ArrayStartIndex].Start)."
    }

    $arrayEndIndex = Get-JsoncValueEndTokenIndex -Tokens $Tokens -StartIndex $ArrayStartIndex
    $elements = [System.Collections.Generic.List[object]]::new()
    $index = $ArrayStartIndex + 1

    while ($index -lt $arrayEndIndex) {
        if ($Tokens[$index].Value -eq "]") {
            break
        }

        $valueStartIndex = $index
        $valueEndIndex = Get-JsoncValueEndTokenIndex -Tokens $Tokens -StartIndex $valueStartIndex
        $index = $valueEndIndex + 1
        $commaTokenIndex = $null

        if ($index -lt $arrayEndIndex -and $Tokens[$index].Value -eq ",") {
            $commaTokenIndex = $index
            $index++
        }
        elseif ($index -lt $arrayEndIndex -and $Tokens[$index].Value -ne "]") {
            throw "Expected ',' after JSON array element at character $($Tokens[$valueEndIndex].End)."
        }

        $elements.Add([pscustomobject]@{
            ValueStartIndex = $valueStartIndex
            ValueEndIndex = $valueEndIndex
            CommaTokenIndex = $commaTokenIndex
        })
    }

    [pscustomobject]@{
        StartTokenIndex = $ArrayStartIndex
        EndTokenIndex = $arrayEndIndex
        Elements = @($elements)
    }
}

function Get-LastJsoncProperty {
    param(
        [Parameter(Mandatory)]
        [object[]]$Properties,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $matchingProperties = @($Properties | Where-Object { $_.Name -eq $Name })
    if ($matchingProperties.Count -eq 0) {
        return $null
    }

    $matchingProperties[-1]
}

function Normalize-KeyChord {
    param(
        [Parameter(Mandatory)]
        [string]$Chord
    )

    $parts = @($Chord.Trim().ToLowerInvariant().Split("+") | Where-Object { $_.Length -gt 0 })
    if ($parts.Count -eq 0) {
        return ""
    }

    $key = $parts[-1]
    $modifiers = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($part in $parts[0..([Math]::Max(0, $parts.Count - 2))]) {
        if ($parts.Count -gt 1) {
            $null = $modifiers.Add($part)
        }
    }

    $normalizedModifiers = @(
        foreach ($modifier in @("ctrl", "alt", "shift", "win")) {
            if ($modifiers.Contains($modifier)) {
                $modifier
            }
        }
    )

    @($normalizedModifiers + $key) -join "+"
}

function Get-JsoncStringArray {
    param(
        [Parameter(Mandatory)]
        [object[]]$Tokens,

        [Parameter(Mandatory)]
        [int]$ValueStartIndex
    )

    $valueToken = $Tokens[$ValueStartIndex]
    if ($valueToken.Kind -eq "String") {
        return [pscustomobject]@{
            Kind = "String"
            Items = @(
                [pscustomobject]@{
                    Value = [string]$valueToken.Value
                    TokenIndex = $ValueStartIndex
                    CommaTokenIndex = $null
                }
            )
            CommaTokenIndexes = @()
            TrailingCommaTokenIndex = $null
            EndTokenIndex = $ValueStartIndex
        }
    }

    if ($valueToken.Value -ne "[") {
        throw "Expected a key chord string or array at character $($valueToken.Start)."
    }

    $array = Get-JsoncArrayElements -Tokens $Tokens -ArrayStartIndex $ValueStartIndex
    $items = [System.Collections.Generic.List[object]]::new()
    $commaTokenIndexes = [System.Collections.Generic.List[int]]::new()
    foreach ($element in $array.Elements) {
        $elementToken = $Tokens[$element.ValueStartIndex]
        if ($elementToken.Kind -ne "String" -or $element.ValueStartIndex -ne $element.ValueEndIndex) {
            throw "Expected a key chord string at character $($elementToken.Start)."
        }

        $items.Add([pscustomobject]@{
            Value = [string]$elementToken.Value
            TokenIndex = $element.ValueStartIndex
            CommaTokenIndex = $element.CommaTokenIndex
        })
        if ($null -ne $element.CommaTokenIndex) {
            $commaTokenIndexes.Add([int]$element.CommaTokenIndex)
        }
    }

    [pscustomobject]@{
        Kind = "Array"
        Items = @($items)
        CommaTokenIndexes = @($commaTokenIndexes)
        TrailingCommaTokenIndex = if (
            $array.Elements.Count -gt 0 -and
            $null -ne $array.Elements[-1].CommaTokenIndex
        ) {
            [int]$array.Elements[-1].CommaTokenIndex
        }
        else {
            $null
        }
        EndTokenIndex = $array.EndTokenIndex
    }
}

function Get-ActionCommand {
    param(
        [Parameter(Mandatory)]
        [object[]]$Tokens,

        [Parameter(Mandatory)]
        [object[]]$Properties
    )

    $commandProperty = Get-LastJsoncProperty -Properties $Properties -Name "command"
    if ($null -eq $commandProperty) {
        return $null
    }

    $commandToken = $Tokens[$commandProperty.ValueStartIndex]
    if ($commandToken.Kind -eq "String") {
        return [string]$commandToken.Value
    }

    if ($commandToken.Value -ne "{") {
        return $null
    }

    $commandObject = Get-JsoncObjectProperties -Tokens $Tokens -ObjectStartIndex $commandProperty.ValueStartIndex
    $actionProperty = Get-LastJsoncProperty -Properties $commandObject.Properties -Name "action"
    if ($null -eq $actionProperty) {
        return $null
    }

    $actionToken = $Tokens[$actionProperty.ValueStartIndex]
    if ($actionToken.Kind -eq "String") {
        return [string]$actionToken.Value
    }

    $null
}

function Get-ActionCommandValueTokenIndex {
    param(
        [Parameter(Mandatory)]
        [object[]]$Tokens,

        [Parameter(Mandatory)]
        [object[]]$Properties
    )

    $commandProperty = Get-LastJsoncProperty -Properties $Properties -Name "command"
    if ($null -eq $commandProperty) {
        return $null
    }

    $commandToken = $Tokens[$commandProperty.ValueStartIndex]
    if ($commandToken.Kind -eq "String") {
        return $commandProperty.ValueStartIndex
    }

    if ($commandToken.Value -ne "{") {
        return $null
    }

    $commandObject = Get-JsoncObjectProperties -Tokens $Tokens -ObjectStartIndex $commandProperty.ValueStartIndex
    $actionProperty = Get-LastJsoncProperty -Properties $commandObject.Properties -Name "action"
    if ($null -eq $actionProperty -or $Tokens[$actionProperty.ValueStartIndex].Kind -ne "String") {
        return $null
    }

    $actionProperty.ValueStartIndex
}

function Get-ActionCommandsById {
    param(
        [Parameter(Mandatory)]
        [object[]]$Tokens,

        [Parameter(Mandatory)]
        [object]$ActionsArray
    )

    $commandsById = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($element in $ActionsArray.Elements) {
        if ($Tokens[$element.ValueStartIndex].Value -ne "{") {
            continue
        }

        $actionObject = Get-JsoncObjectProperties -Tokens $Tokens -ObjectStartIndex $element.ValueStartIndex
        $idProperty = Get-LastJsoncProperty -Properties $actionObject.Properties -Name "id"
        if ($null -eq $idProperty) {
            continue
        }

        $idToken = $Tokens[$idProperty.ValueStartIndex]
        if ($idToken.Kind -ne "String") {
            continue
        }

        $command = Get-ActionCommand -Tokens $Tokens -Properties $actionObject.Properties
        if (-not [string]::IsNullOrWhiteSpace($command)) {
            $commandsById[[string]$idToken.Value] = $command
        }
    }

    return ,$commandsById
}

function Get-KeybindingCommand {
    param(
        [Parameter(Mandatory)]
        [object[]]$Tokens,

        [Parameter(Mandatory)]
        [object[]]$Properties,

        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, string]]$ActionCommandsById
    )

    $legacyCommand = Get-ActionCommand -Tokens $Tokens -Properties $Properties
    if (-not [string]::IsNullOrWhiteSpace($legacyCommand)) {
        return $legacyCommand
    }

    $idProperty = Get-LastJsoncProperty -Properties $Properties -Name "id"
    if ($null -eq $idProperty) {
        return $null
    }

    $idToken = $Tokens[$idProperty.ValueStartIndex]
    if ($idToken.Kind -eq "Literal" -and $idToken.Value -eq "null") {
        return "unbound"
    }

    if ($idToken.Kind -ne "String") {
        return $null
    }

    $id = [string]$idToken.Value
    if ($id -eq "Terminal.PasteFromClipboard" -or $id -eq "Terminal.Paste") {
        return "paste"
    }

    $command = $null
    if ($ActionCommandsById.TryGetValue($id, [ref]$command)) {
        return $command
    }

    $null
}

function Get-BindingEntries {
    param(
        [Parameter(Mandatory)]
        [object[]]$Tokens,

        [Parameter(Mandatory)]
        [string]$ArrayName,

        [Parameter(Mandatory)]
        [object]$Array,

        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, string]]$ActionCommandsById
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($element in $Array.Elements) {
        if ($Tokens[$element.ValueStartIndex].Value -ne "{") {
            continue
        }

        $actionObject = Get-JsoncObjectProperties -Tokens $Tokens -ObjectStartIndex $element.ValueStartIndex
        $keysProperty = Get-LastJsoncProperty -Properties $actionObject.Properties -Name "keys"
        if ($null -eq $keysProperty) {
            continue
        }

        $keys = Get-JsoncStringArray -Tokens $Tokens -ValueStartIndex $keysProperty.ValueStartIndex
        $entries.Add([pscustomobject]@{
            ArrayName = $ArrayName
            Element = $element
            Properties = $actionObject.Properties
            KeysProperty = $keysProperty
            Keys = $keys
            Command = if ($ArrayName -eq "actions") {
                Get-ActionCommand -Tokens $Tokens -Properties $actionObject.Properties
            }
            else {
                Get-KeybindingCommand `
                    -Tokens $Tokens `
                    -Properties $actionObject.Properties `
                    -ActionCommandsById $ActionCommandsById
            }
        })
    }

    @($entries)
}

function New-TextEdit {
    param(
        [Parameter(Mandatory)]
        [int]$Start,

        [Parameter(Mandatory)]
        [int]$Length,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Replacement
    )

    [pscustomobject]@{
        Start = $Start
        Length = $Length
        Replacement = $Replacement
    }
}

function Add-KeyRemovalEdits {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Edits,

        [Parameter(Mandatory)]
        [object[]]$Tokens,

        [Parameter(Mandatory)]
        [object]$Binding,

        [Parameter(Mandatory)]
        [string[]]$Chords
    )

    $normalizedChords = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($chord in $Chords) {
        $null = $normalizedChords.Add((Normalize-KeyChord $chord))
    }

    $itemsToRemove = @(
        $Binding.Keys.Items |
            Where-Object { $normalizedChords.Contains((Normalize-KeyChord $_.Value)) }
    )
    if ($itemsToRemove.Count -eq 0) {
        return
    }

    if ($Binding.Keys.Kind -eq "String") {
        $valueStartToken = $Tokens[$Binding.KeysProperty.ValueStartIndex]
        $Edits.Add((New-TextEdit -Start $valueStartToken.Start -Length ($valueStartToken.End - $valueStartToken.Start) -Replacement "[]"))
        return
    }

    $tokenIndexesToRemove = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($item in $itemsToRemove) {
        $null = $tokenIndexesToRemove.Add([int]$item.TokenIndex)
        $token = $Tokens[$item.TokenIndex]
        $Edits.Add((New-TextEdit -Start $token.Start -Length ($token.End - $token.Start) -Replacement ""))
    }

    $remainingItems = @(
        $Binding.Keys.Items |
            Where-Object { -not $tokenIndexesToRemove.Contains([int]$_.TokenIndex) }
    )
    if ($remainingItems.Count -eq 0) {
        throw "Internal error: a Windows Terminal keybinding cannot have every key chord removed."
    }

    $commaIndexesToKeep = [System.Collections.Generic.HashSet[int]]::new()
    if ($remainingItems.Count -gt 1) {
        foreach ($item in $remainingItems[0..($remainingItems.Count - 2)]) {
            if ($null -eq $item.CommaTokenIndex) {
                throw "Unable to preserve the remaining key chord array structure."
            }

            $null = $commaIndexesToKeep.Add([int]$item.CommaTokenIndex)
        }
    }
    if ($remainingItems.Count -gt 0 -and $null -ne $Binding.Keys.TrailingCommaTokenIndex) {
        $null = $commaIndexesToKeep.Add([int]$Binding.Keys.TrailingCommaTokenIndex)
    }

    foreach ($commaIndex in $Binding.Keys.CommaTokenIndexes) {
        if (-not $commaIndexesToKeep.Contains([int]$commaIndex)) {
            $commaToken = $Tokens[$commaIndex]
            $Edits.Add((New-TextEdit -Start $commaToken.Start -Length ($commaToken.End - $commaToken.Start) -Replacement ""))
        }
    }
}

function Add-BindingCommandReplacementEdit {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Edits,

        [Parameter(Mandatory)]
        [object[]]$Tokens,

        [Parameter(Mandatory)]
        [object]$Binding,

        [Parameter(Mandatory)]
        [string]$Command
    )

    if ($Binding.ArrayName -eq "keybindings") {
        $idProperty = Get-LastJsoncProperty -Properties $Binding.Properties -Name "id"
        if ($null -ne $idProperty) {
            $idToken = $Tokens[$idProperty.ValueStartIndex]
            $replacement = if ($Command -eq "unbound") {
                "null"
            }
            elseif ($Command -eq "paste") {
                '"Terminal.PasteFromClipboard"'
            }
            else {
                throw "Unsupported managed Windows Terminal command: $Command"
            }

            $Edits.Add((
                New-TextEdit `
                    -Start $idToken.Start `
                    -Length ($idToken.End - $idToken.Start) `
                    -Replacement $replacement
            ))
            return
        }
    }

    $commandTokenIndex = Get-ActionCommandValueTokenIndex `
        -Tokens $Tokens `
        -Properties $Binding.Properties
    if ($null -eq $commandTokenIndex) {
        throw "Unable to replace a conflicting Windows Terminal binding command."
    }

    $commandToken = $Tokens[$commandTokenIndex]
    $Edits.Add((
        New-TextEdit `
            -Start $commandToken.Start `
            -Length ($commandToken.End - $commandToken.Start) `
            -Replacement "`"$Command`""
    ))
}

function Add-BindingCommentEdit {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Edits,

        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [object[]]$Tokens,

        [Parameter(Mandatory)]
        [object]$Binding,

        [Parameter(Mandatory)]
        [string]$Comment,

        [Parameter(Mandatory)]
        [string]$NewLine
    )

    $elementStartToken = $Tokens[$Binding.Element.ValueStartIndex]
    $indent = Get-LineIndent -Text $Text -Position $elementStartToken.Start
    $Edits.Add((
        New-TextEdit `
            -Start $elementStartToken.Start `
            -Length 0 `
            -Replacement "// $Comment$NewLine$indent"
    ))
}

function Get-LineIndent {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [int]$Position
    )

    $lineStart = if ($Position -eq 0) {
        0
    }
    else {
        $Text.LastIndexOf("`n", [Math]::Max(0, $Position - 1)) + 1
    }

    $prefix = $Text.Substring($lineStart, $Position - $lineStart)
    $match = [regex]::Match($prefix, "^[ `t]*")
    $match.Value
}

function Get-TrailingWhitespaceStart {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [int]$Position
    )

    $index = $Position
    while ($index -gt 0 -and [char]::IsWhiteSpace($Text[$index - 1])) {
        $index--
    }

    $index
}

function Format-ManagedAction {
    param(
        [Parameter(Mandatory)]
        [object]$Binding,

        [Parameter(Mandatory)]
        [string]$ElementIndent,

        [Parameter(Mandatory)]
        [string]$IndentUnit,

        [Parameter(Mandatory)]
        [string]$NewLine
    )

    $innerIndent = $ElementIndent + $IndentUnit
    @(
        "// $($Binding.Comment)"
        "$ElementIndent{"
        "$innerIndent`"command`": `"$($Binding.Command)`","
        "$innerIndent`"keys`": `"$($Binding.Chord)`""
        "$ElementIndent}"
    ) -join $NewLine
}

function Add-ManagedActionsEdits {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Edits,

        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [object[]]$Tokens,

        [Parameter(Mandatory)]
        [object]$RootObject,

        [AllowNull()]
        [object]$ActionsProperty,

        [AllowNull()]
        [object]$ActionsArray,

        [Parameter(Mandatory)]
        [object[]]$BindingsToAdd,

        [Parameter(Mandatory)]
        [string]$NewLine
    )

    if ($BindingsToAdd.Count -eq 0) {
        return
    }

    $indentUnit = "    "
    if ($RootObject.Properties.Count -gt 0) {
        $firstPropertyToken = $Tokens[$RootObject.Properties[0].NameTokenIndex]
        $candidateIndent = Get-LineIndent -Text $Text -Position $firstPropertyToken.Start
        if ($candidateIndent.Length -gt 0) {
            $indentUnit = $candidateIndent
        }
    }

    if ($null -eq $ActionsProperty) {
        $propertyIndent = $indentUnit
        $elementIndent = $propertyIndent + $indentUnit
        $formattedActions = @(
            foreach ($binding in $BindingsToAdd) {
                $elementIndent + (Format-ManagedAction -Binding $binding -ElementIndent $elementIndent -IndentUnit $indentUnit -NewLine $NewLine)
            }
        ) -join ",$NewLine"

        $propertyText = @(
            "$propertyIndent`"actions`":"
            "$propertyIndent["
            $formattedActions
            "$propertyIndent]"
        ) -join $NewLine

        $rootEndToken = $Tokens[$RootObject.EndTokenIndex]
        $whitespaceStart = Get-TrailingWhitespaceStart -Text $Text -Position $rootEndToken.Start
        $separator = ""
        if ($RootObject.Properties.Count -gt 0) {
            $lastProperty = $RootObject.Properties[-1]
            if ($null -eq $lastProperty.CommaTokenIndex) {
                $lastValueToken = $Tokens[$lastProperty.ValueEndIndex]
                if ($lastValueToken.End -eq $whitespaceStart) {
                    $separator = ","
                }
                else {
                    $Edits.Add((New-TextEdit -Start $lastValueToken.End -Length 0 -Replacement ","))
                }
            }
        }

        $replacement = "$separator$NewLine$propertyText$NewLine"
        $Edits.Add((New-TextEdit -Start $whitespaceStart -Length ($rootEndToken.Start - $whitespaceStart) -Replacement $replacement))
        return
    }

    $propertyIndent = Get-LineIndent -Text $Text -Position $Tokens[$ActionsProperty.NameTokenIndex].Start
    if ($propertyIndent.Length -eq 0) {
        $propertyIndent = $indentUnit
    }

    $elementIndent = if ($ActionsArray.Elements.Count -gt 0) {
        Get-LineIndent -Text $Text -Position $Tokens[$ActionsArray.Elements[0].ValueStartIndex].Start
    }
    else {
        $propertyIndent + $indentUnit
    }
    if ($elementIndent.Length -le $propertyIndent.Length) {
        $elementIndent = $propertyIndent + $indentUnit
    }

    $formattedActions = @(
        foreach ($binding in $BindingsToAdd) {
            $elementIndent + (Format-ManagedAction -Binding $binding -ElementIndent $elementIndent -IndentUnit $indentUnit -NewLine $NewLine)
        }
    ) -join ",$NewLine"

    $arrayEndToken = $Tokens[$ActionsArray.EndTokenIndex]
    $whitespaceStart = Get-TrailingWhitespaceStart -Text $Text -Position $arrayEndToken.Start
    $separator = ""
    if ($ActionsArray.Elements.Count -gt 0) {
        $lastElement = $ActionsArray.Elements[-1]
        if ($null -eq $lastElement.CommaTokenIndex) {
            $lastValueToken = $Tokens[$lastElement.ValueEndIndex]
            if ($lastValueToken.End -eq $whitespaceStart) {
                $separator = ","
            }
            else {
                $Edits.Add((New-TextEdit -Start $lastValueToken.End -Length 0 -Replacement ","))
            }
        }
    }

    $replacement = "$separator$NewLine$formattedActions$NewLine$propertyIndent"
    $Edits.Add((New-TextEdit -Start $whitespaceStart -Length ($arrayEndToken.Start - $whitespaceStart) -Replacement $replacement))
}

function Invoke-TextEdits {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Edits
    )

    $orderedEdits = @($Edits | Sort-Object Start, Length)
    for ($index = 1; $index -lt $orderedEdits.Count; $index++) {
        $previousEnd = $orderedEdits[$index - 1].Start + $orderedEdits[$index - 1].Length
        if ($orderedEdits[$index].Start -lt $previousEnd) {
            throw "Internal error: overlapping Windows Terminal settings edits were generated."
        }
    }

    $result = $Text
    foreach ($edit in @($orderedEdits | Sort-Object Start -Descending)) {
        $result = $result.Remove($edit.Start, $edit.Length).Insert($edit.Start, $edit.Replacement)
    }

    $result
}

function Write-DiffLine {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Line,

        [Parameter(Mandatory)]
        [bool]$UseColor
    )

    if (-not $UseColor) {
        Write-Host $Line
        return
    }

    $escape = [char]27
    $reset = "$escape[0m"
    $color = if ($Line.StartsWith("+++") -or $Line.StartsWith("---") -or $Line.StartsWith("@@")) {
        "$escape[36m"
    }
    elseif ($Line.StartsWith("+")) {
        "$escape[32m"
    }
    elseif ($Line.StartsWith("-")) {
        "$escape[31m"
    }
    else {
        ""
    }

    if ($color.Length -eq 0) {
        Write-Host $Line
    }
    else {
        Write-Host "$color$Line$reset"
    }
}

function Show-UnifiedDiff {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [AllowNull()]
        [string]$BeforeText,

        [Parameter(Mandatory)]
        [string]$AfterText
    )

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        throw "Git is required to render the Windows Terminal settings diff for -WhatIf."
    }

    $temporaryDirectory = Join-Path (
        [System.IO.Path]::GetTempPath()
    ) "devsetup-terminal-diff-$([guid]::NewGuid().ToString('N'))"
    $beforePath = Join-Path $temporaryDirectory "before\settings.json"
    $afterPath = Join-Path $temporaryDirectory "after\settings.json"
    $encoding = [System.Text.UTF8Encoding]::new($false)

    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $beforePath) -Force -WhatIf:$false | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $afterPath) -Force -WhatIf:$false | Out-Null
        [System.IO.File]::WriteAllText($beforePath, $(if ($null -eq $BeforeText) { "" } else { $BeforeText }), $encoding)
        [System.IO.File]::WriteAllText($afterPath, $AfterText, $encoding)

        $diffLines = @(
            & $git.Source `
                --no-pager `
                -c core.safecrlf=false `
                diff `
                --no-index `
                --no-ext-diff `
                --no-textconv `
                --text `
                --unified=3 `
                --color=never `
                -- `
                $beforePath `
                $afterPath 2>&1
        )
        $diffExitCode = $LASTEXITCODE
        if ($diffExitCode -ne 0 -and $diffExitCode -ne 1) {
            throw "Git could not render the settings diff:`n$($diffLines -join "`n")"
        }

        $displayPath = $Path.Replace("\", "/")
        $supportsVirtualTerminalProperty = $Host.UI.PSObject.Properties["SupportsVirtualTerminal"]
        $useColor = (
            $null -ne $supportsVirtualTerminalProperty -and
            [bool]$supportsVirtualTerminalProperty.Value -and
            -not [Console]::IsOutputRedirected
        )
        foreach ($lineObject in $diffLines) {
            $line = [string]$lineObject
            if ($line.StartsWith("diff --git ")) {
                $line = "diff --git a/$displayPath b/$displayPath"
            }
            elseif ($line.StartsWith("--- ")) {
                $line = "--- a/$displayPath"
            }
            elseif ($line.StartsWith("+++ ")) {
                $line = "+++ b/$displayPath"
            }

            Write-DiffLine -Line $line -UseColor $useColor
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -WhatIf:$false
        }
    }
}

function Read-Utf8File {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if (
        ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or
        ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) -or
        ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) -or
        ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00)
    ) {
        throw "Windows Terminal settings must use UTF-8 encoding: $Path"
    }

    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)

    [pscustomobject]@{
        Text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
        HasBom = $hasBom
    }
}

function Write-Utf8FileAtomically {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [bool]$HasBom
    )

    $parentDirectory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
    }

    $temporaryPath = Join-Path $parentDirectory ".$([System.IO.Path]::GetFileName($Path)).$([guid]::NewGuid().ToString('N')).tmp"
    $encoding = [System.Text.UTF8Encoding]::new($HasBom)
    $backupPath = $null

    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Text, $encoding)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            do {
                $backupPath = "$Path.backup.$(Get-Date -Format 'yyyyMMddHHmmssfff')"
            }
            while (Test-Path -LiteralPath $backupPath)

            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
        }
        else {
            Move-Item -LiteralPath $temporaryPath -Destination $Path
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }

    $backupPath
}

function Get-WindowsTerminalSettingsUpdate {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $newLine = [Environment]::NewLine
        $propertyIndent = "    "
        $elementIndent = "        "
        $formattedActions = @(
            foreach ($binding in $managedBindings) {
                $elementIndent + (Format-ManagedAction -Binding $binding -ElementIndent $elementIndent -IndentUnit "    " -NewLine $newLine)
            }
        ) -join ",$newLine"
        $text = @(
            "{"
            "$propertyIndent`"`$schema`": `"https://aka.ms/terminal-profiles-schema`","
            ""
            "$propertyIndent`"actions`":"
            "$propertyIndent["
            $formattedActions
            "$propertyIndent]"
            "}"
            ""
        ) -join $newLine

        return [pscustomobject]@{
            Path = $Path
            State = "Missing"
            Reason = "The settings file does not exist."
            OriginalText = $null
            Text = $text
            HasBom = $false
            Existing = $false
        }
    }

    $file = Read-Utf8File -Path $Path
    $text = $file.Text
    $tokens = @(Get-JsoncTokens -Text $text)
    if ($tokens.Count -eq 0 -or $tokens[0].Value -ne "{") {
        throw "Windows Terminal settings must contain a root JSON object: $Path"
    }

    $rootObject = Get-JsoncObjectProperties -Tokens $tokens -ObjectStartIndex 0
    if ($rootObject.EndTokenIndex -ne $tokens.Count - 1) {
        throw "Unexpected content follows the root JSON object in $Path."
    }

    $actionsProperties = @($rootObject.Properties | Where-Object { $_.Name -eq "actions" })
    if ($actionsProperties.Count -gt 1) {
        throw "Multiple root actions properties are not supported because their precedence is ambiguous: $Path"
    }

    $keybindingsProperties = @($rootObject.Properties | Where-Object { $_.Name -eq "keybindings" })
    if ($keybindingsProperties.Count -gt 1) {
        throw "Multiple root keybindings properties are not supported because their precedence is ambiguous: $Path"
    }

    $actionsProperty = if ($actionsProperties.Count -eq 1) { $actionsProperties[0] } else { $null }
    $actionsArray = $null
    $actionCommandsById = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $bindingEntries = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $actionsProperty) {
        if ($tokens[$actionsProperty.ValueStartIndex].Value -ne "[") {
            throw "The root actions property must be an array: $Path"
        }

        $actionsArray = Get-JsoncArrayElements -Tokens $tokens -ArrayStartIndex $actionsProperty.ValueStartIndex
        $actionCommandsById = Get-ActionCommandsById -Tokens $tokens -ActionsArray $actionsArray
        foreach ($entry in @(
            Get-BindingEntries `
                -Tokens $tokens `
                -ArrayName "actions" `
                -Array $actionsArray `
                -ActionCommandsById $actionCommandsById
        )) {
            $bindingEntries.Add($entry)
        }
    }

    if ($keybindingsProperties.Count -eq 1) {
        $keybindingsProperty = $keybindingsProperties[0]
        if ($tokens[$keybindingsProperty.ValueStartIndex].Value -ne "[") {
            throw "The root keybindings property must be an array: $Path"
        }

        $keybindingsArray = Get-JsoncArrayElements -Tokens $tokens -ArrayStartIndex $keybindingsProperty.ValueStartIndex
        foreach ($entry in @(
            Get-BindingEntries `
                -Tokens $tokens `
                -ArrayName "keybindings" `
                -Array $keybindingsArray `
                -ActionCommandsById $actionCommandsById
        )) {
            $bindingEntries.Add($entry)
        }
    }

    $bindingsToKeep = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $bindingsToNeutralize = [System.Collections.Generic.List[object]]::new()
    $bindingsToAdd = [System.Collections.Generic.List[object]]::new()
    $hasConflict = $false

    foreach ($managedBinding in $managedBindings) {
        $normalizedChord = Normalize-KeyChord $managedBinding.Chord
        $matchingEntries = @(
            $bindingEntries |
                Where-Object {
                    @($_.Keys.Items | Where-Object {
                        (Normalize-KeyChord $_.Value) -eq $normalizedChord
                    }).Count -gt 0
                }
        )
        $desiredEntries = @(
            $matchingEntries |
                Where-Object {
                    $_.Command -ieq $managedBinding.Command
                }
        )

        if ($matchingEntries.Count -eq 0) {
            $bindingsToAdd.Add($managedBinding)
            continue
        }

        foreach ($entry in $desiredEntries) {
            $null = $bindingsToKeep.Add("$($entry.ArrayName):$($entry.Element.ValueStartIndex):$normalizedChord")
        }

        if ($desiredEntries.Count -eq $matchingEntries.Count) {
            continue
        }

        $hasConflict = $true
        if ($desiredEntries.Count -eq 0) {
            $bindingsToAdd.Add($managedBinding)
        }

        foreach ($entry in $matchingEntries) {
            $entryKey = "$($entry.ArrayName):$($entry.Element.ValueStartIndex):$normalizedChord"
            if (-not $bindingsToKeep.Contains($entryKey)) {
                $bindingsToNeutralize.Add([pscustomobject]@{
                    Entry = $entry
                    Chord = $managedBinding.Chord
                })
            }
        }
    }

    $state = if ($hasConflict) {
        "Conflict"
    }
    elseif ($bindingsToAdd.Count -gt 0) {
        "Missing"
    }
    else {
        "Current"
    }

    if ($state -eq "Current") {
        return [pscustomobject]@{
            Path = $Path
            State = $state
            Reason = "The managed keybindings are current."
            OriginalText = $text
            Text = $text
            HasBom = $file.HasBom
            Existing = $true
        }
    }

    if ($hasConflict -and -not $Replace -and -not $Check) {
        throw (
            "Existing Windows Terminal keybindings conflict with the managed Ctrl+V bindings in " +
            "$Path. Re-run with -Replace to back up the file and replace those bindings."
        )
    }

    $edits = [System.Collections.Generic.List[object]]::new()
    $newLine = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($hasConflict) {
        $neutralizationsByEntry = @(
            $bindingsToNeutralize |
                Group-Object { "$($_.Entry.ArrayName):$($_.Entry.Element.ValueStartIndex)" }
        )
        foreach ($group in $neutralizationsByEntry) {
            $entry = $group.Group[0].Entry
            $chords = @($group.Group | ForEach-Object { $_.Chord })
            $normalizedChords = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
            foreach ($chord in $chords) {
                $null = $normalizedChords.Add((Normalize-KeyChord $chord))
            }

            $remainingKeys = @(
                $entry.Keys.Items |
                    Where-Object {
                        -not $normalizedChords.Contains((Normalize-KeyChord $_.Value))
                    }
            )
            if ($remainingKeys.Count -eq 0) {
                $bindingToPreserve = $managedBindings |
                    Where-Object {
                        $normalizedChords.Contains((Normalize-KeyChord $_.Chord))
                    } |
                    Select-Object -First 1
                if ($null -eq $bindingToPreserve) {
                    throw "Unable to preserve a valid Windows Terminal keybinding."
                }

                Add-BindingCommandReplacementEdit `
                    -Edits $edits `
                    -Tokens $tokens `
                    -Binding $entry `
                    -Command $bindingToPreserve.Command
                Add-BindingCommentEdit `
                    -Edits $edits `
                    -Text $text `
                    -Tokens $tokens `
                    -Binding $entry `
                    -Comment $bindingToPreserve.Comment `
                    -NewLine $newLine

                $preservedChord = Normalize-KeyChord $bindingToPreserve.Chord
                $chords = @(
                    $chords |
                        Where-Object {
                            (Normalize-KeyChord $_) -ne $preservedChord
                        }
                )

                $bindingToRemove = $bindingsToAdd |
                    Where-Object {
                        (Normalize-KeyChord $_.Chord) -eq $preservedChord
                    } |
                    Select-Object -First 1
                if ($null -ne $bindingToRemove) {
                    $null = $bindingsToAdd.Remove($bindingToRemove)
                }
            }

            if ($chords.Count -gt 0) {
                Add-KeyRemovalEdits -Edits $edits -Tokens $tokens -Binding $entry -Chords $chords
            }
        }
    }

    Add-ManagedActionsEdits `
        -Edits $edits `
        -Text $text `
        -Tokens $tokens `
        -RootObject $rootObject `
        -ActionsProperty $actionsProperty `
        -ActionsArray $actionsArray `
        -BindingsToAdd @($bindingsToAdd) `
        -NewLine $newLine

    [pscustomobject]@{
        Path = $Path
        State = $state
        Reason = if ($hasConflict) {
            "One or more explicit keybindings conflict with the managed bindings."
        }
        else {
            "One or more managed keybindings are missing."
        }
        OriginalText = $text
        Text = Invoke-TextEdits -Text $text -Edits @($edits)
        HasBom = $file.HasBom
        Existing = $true
    }
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($path in @(Resolve-WindowsTerminalSettingsPath)) {
    $update = Get-WindowsTerminalSettingsUpdate -Path $path
    $backupPath = $null
    $changed = $update.State -ne "Current"

    if (-not $Check -and $changed -and $WhatIfPreference) {
        Show-UnifiedDiff `
            -Path $path `
            -BeforeText $update.OriginalText `
            -AfterText $update.Text
    }

    if (-not $Check -and $changed) {
        if ($PSCmdlet.ShouldProcess($path, "Configure Windows Terminal multiline paste keybindings")) {
            $backupPath = Write-Utf8FileAtomically `
                -Path $path `
                -Text $update.Text `
                -HasBom $update.HasBom
        }
    }

    $result = [pscustomobject]@{
        Path = $path
        State = $update.State
        Reason = $update.Reason
        Changed = $changed -and -not $Check -and -not $WhatIfPreference
        BackupPath = $backupPath
    }
    $results.Add($result)

    if (-not $PassThru) {
        if ($Check) {
            Write-Host ("{0,-8} {1}" -f $result.State.ToUpperInvariant(), $result.Path)
        }
        elseif (-not $changed) {
            Write-Host "Current: Windows Terminal settings ($($result.Path))"
        }
        elseif ($WhatIfPreference) {
            Write-Host "Planned: Windows Terminal settings ($($result.Path))"
        }
        else {
            Write-Host "Updated: Windows Terminal settings ($($result.Path))"
            if ($null -ne $backupPath) {
                Write-Host "Backup: $backupPath"
            }
        }
    }
}

if ($PassThru) {
    $results
}
elseif ($Check -and @($results | Where-Object { $_.State -ne "Current" }).Count -gt 0) {
    exit 1
}
