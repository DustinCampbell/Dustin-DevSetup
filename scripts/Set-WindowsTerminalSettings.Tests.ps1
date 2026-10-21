Describe "Set-WindowsTerminalSettings.ps1" {
    BeforeAll {
        $scriptUnderTest = Join-Path $PSScriptRoot "Set-WindowsTerminalSettings.ps1"

        function Write-Utf8TestFile {
            param(
                [Parameter(Mandatory)]
                [string]$Path,

                [Parameter(Mandatory)]
                [string]$Content,

                [switch]$Bom
            )

            $parentDirectory = Split-Path -Parent $Path
            New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
            [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($Bom.IsPresent))
        }

        function Invoke-SettingsUpdater {
            param(
                [Parameter(Mandatory)]
                [string[]]$Path,

                [switch]$Replace,

                [switch]$Check,

                [switch]$WhatIf
            )

            $arguments = @{
                SettingsPath = $Path
                PassThru = $true
            }
            if ($Replace) {
                $arguments.Replace = $true
            }
            if ($Check) {
                $arguments.Check = $true
            }
            if ($WhatIf) {
                $arguments.WhatIf = $true
            }

            @(& $scriptUnderTest @arguments)
        }

        function Get-SettingsBackups {
            param(
                [Parameter(Mandatory)]
                [string]$Path
            )

            @(
                Get-ChildItem `
                    -LiteralPath (Split-Path -Parent $Path) `
                    -Filter "$([System.IO.Path]::GetFileName($Path)).backup.*" `
                    -File `
                    -ErrorAction SilentlyContinue
            )
        }
    }

    BeforeEach {
        $testRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $settingsPath = Join-Path $testRoot "settings.json"
    }

    It "creates a missing settings file with documented bindings" {
        $result = Invoke-SettingsUpdater -Path $settingsPath

        $result.Count | Should -Be 1
        $result[0].State | Should -Be "Missing"
        $result[0].Changed | Should -BeTrue
        Test-Path -LiteralPath $settingsPath -PathType Leaf | Should -BeTrue

        $content = [System.IO.File]::ReadAllText($settingsPath)
        $content | Should -Match '"command": "unbound"'
        $content | Should -Match '"keys": "ctrl\+v"'
        $content | Should -Match '"command": "paste"'
        $content | Should -Match '"keys": "ctrl\+shift\+v"'
        $content | Should -Match "Dustin-DevSetup:"
    }

    It "preserves comments and unrelated machine-specific settings" {
        $preservedBlock = @'
    "profiles":
    {
        /* Keep this machine-specific profile exactly as written. */
        "list":
        [
            {
                "name": "Machine profile",
                "commandline": "C:\\Tools\\MachineShell.exe",
            },
        ],
    },
'@
        $content = @"
{
    // Keep this root comment.
    "warning.multiLinePaste": "always",
$preservedBlock
}
"@
        Write-Utf8TestFile -Path $settingsPath -Content $content

        Invoke-SettingsUpdater -Path $settingsPath | Out-Null

        $updated = [System.IO.File]::ReadAllText($settingsPath)
        $updated | Should -Match ([regex]::Escape("// Keep this root comment."))
        $updated.Contains($preservedBlock) | Should -BeTrue
        $updated | Should -Match ([regex]::Escape('"warning.multiLinePaste": "always"'))
    }

    It "preserves comments and trailing commas while removing one chord from a key array" {
        $content = @'
{
    "actions":
    [
        {
            "command": "copy",
            "keys":
            [
                // Remove only this chord.
                "ctrl+v",
                /* Keep this chord and comment. */
                "alt+v",
            ],
        },
    ],
}
'@
        Write-Utf8TestFile -Path $settingsPath -Content $content

        Invoke-SettingsUpdater -Path $settingsPath -Replace | Out-Null

        $updated = [System.IO.File]::ReadAllText($settingsPath)
        $updated | Should -Match ([regex]::Escape("// Remove only this chord."))
        $updated | Should -Match ([regex]::Escape("/* Keep this chord and comment. */"))
        $updated | Should -Match '"alt\+v"'
        $updated | Should -Match '"actions"'
        (Invoke-SettingsUpdater -Path $settingsPath -Check)[0].State | Should -Be "Current"
    }

    It "removes conflicting chords from the <Position> of a multi-key array" -TestCases @(
        @{
            Position = "start"
            Keys = @("ctrl+v", "alt+a", "alt+b")
        },
        @{
            Position = "middle"
            Keys = @("alt+a", "ctrl+v", "alt+b")
        },
        @{
            Position = "end"
            Keys = @("alt+a", "alt+b", "ctrl+v")
        },
        @{
            Position = "entire array"
            Keys = @("ctrl+v", "ctrl+shift+v")
        }
    ) {
        param($Position, $Keys)

        $serializedKeys = @($Keys | ForEach-Object { "`"$_`"" }) -join ", "
        $content = @"
{
    "actions":
    [
        {
            "command": "copy",
            "keys": [ $serializedKeys ]
        }
    ]
}
"@
        Write-Utf8TestFile -Path $settingsPath -Content $content

        Invoke-SettingsUpdater -Path $settingsPath -Replace | Out-Null

        (Invoke-SettingsUpdater -Path $settingsPath -Check)[0].State | Should -Be "Current"
    }

    It "inserts commas before comments that precede closing delimiters" {
        $content = @'
{
    "profiles": {}
    // Keep this root trailing comment.
}
'@
        Write-Utf8TestFile -Path $settingsPath -Content $content

        Invoke-SettingsUpdater -Path $settingsPath | Out-Null
        $updated = [System.IO.File]::ReadAllText($settingsPath)

        $updated | Should -Match ([regex]::Escape("// Keep this root trailing comment."))
        (Invoke-SettingsUpdater -Path $settingsPath -Check)[0].State | Should -Be "Current"
    }

    It "appends an action after a comment following the previous array element" {
        $content = @'
{
    "actions":
    [
        {
            "command": "unbound",
            "keys": "ctrl+v"
        }
        // Keep this action trailing comment.
    ]
}
'@
        Write-Utf8TestFile -Path $settingsPath -Content $content

        Invoke-SettingsUpdater -Path $settingsPath | Out-Null
        $updated = [System.IO.File]::ReadAllText($settingsPath)

        $updated | Should -Match ([regex]::Escape("// Keep this action trailing comment."))
        (Invoke-SettingsUpdater -Path $settingsPath -Check)[0].State | Should -Be "Current"
    }

    It "recognizes current modern ID-based keybindings without rewriting them" {
        $content = @'
{
    "actions": [],
    "keybindings":
    [
        {
            "id": null,
            "keys": "ctrl+v"
        },
        {
            "id": "Terminal.PasteFromClipboard",
            "keys": "ctrl+shift+v"
        }
    ]
}
'@
        Write-Utf8TestFile -Path $settingsPath -Content $content

        $result = Invoke-SettingsUpdater -Path $settingsPath -Check

        $result[0].State | Should -Be "Current"
        [System.IO.File]::ReadAllText($settingsPath) | Should -BeExactly $content
    }

    It "resolves custom action IDs used by modern keybindings" {
        $content = @'
{
    "actions":
    [
        {
            "command": "unbound",
            "keys": "ctrl+v"
        },
        {
            "command": "paste",
            "id": "User.SafePaste"
        }
    ],
    "keybindings":
    [
        {
            "id": "User.SafePaste",
            "keys": "ctrl+shift+v"
        }
    ]
}
'@
        Write-Utf8TestFile -Path $settingsPath -Content $content

        (Invoke-SettingsUpdater -Path $settingsPath -Check)[0].State | Should -Be "Current"
    }

    It "recognizes chord casing and modifier ordering" {
        $content = @'
{
    "actions":
    [
        {
            "command": "unbound",
            "keys": "CTRL+V"
        },
        {
            "command": "paste",
            "keys": "SHIFT+CTRL+V"
        }
    ]
}
'@
        Write-Utf8TestFile -Path $settingsPath -Content $content

        (Invoke-SettingsUpdater -Path $settingsPath -Check)[0].State | Should -Be "Current"
    }

    It "does not replace a conflicting binding without Replace" {
        $content = @'
{
    "actions":
    [
        {
            "command": "paste",
            "keys": "ctrl+v"
        }
    ]
}
'@
        Write-Utf8TestFile -Path $settingsPath -Content $content

        { Invoke-SettingsUpdater -Path $settingsPath } | Should -Throw "*Re-run with -Replace*"
        [System.IO.File]::ReadAllText($settingsPath) | Should -BeExactly $content
        (Get-SettingsBackups -Path $settingsPath).Count | Should -Be 0
    }

    It "backs up the original file before replacing conflicting bindings" {
        $content = @'
{
    "actions":
    [
        {
            "command": "paste",
            "keys": "ctrl+v"
        }
    ]
}
'@
        Write-Utf8TestFile -Path $settingsPath -Content $content

        $result = Invoke-SettingsUpdater -Path $settingsPath -Replace
        $backups = Get-SettingsBackups -Path $settingsPath

        $result[0].State | Should -Be "Conflict"
        $result[0].Changed | Should -BeTrue
        $backups.Count | Should -Be 1
        [System.IO.File]::ReadAllText($backups[0].FullName) | Should -BeExactly $content
        (Invoke-SettingsUpdater -Path $settingsPath -Check)[0].State | Should -Be "Current"
    }

    It "does not write or create a backup under WhatIf" {
        $content = "{}"
        Write-Utf8TestFile -Path $settingsPath -Content $content

        $result = Invoke-SettingsUpdater -Path $settingsPath -WhatIf

        $result[0].State | Should -Be "Missing"
        $result[0].Changed | Should -BeFalse
        [System.IO.File]::ReadAllText($settingsPath) | Should -BeExactly $content
        (Get-SettingsBackups -Path $settingsPath).Count | Should -Be 0
    }

    It "does not modify a file in Check mode" {
        $content = "{}"
        Write-Utf8TestFile -Path $settingsPath -Content $content

        $result = Invoke-SettingsUpdater -Path $settingsPath -Check

        $result[0].State | Should -Be "Missing"
        [System.IO.File]::ReadAllText($settingsPath) | Should -BeExactly $content
        (Get-SettingsBackups -Path $settingsPath).Count | Should -Be 0
    }

    It "is idempotent after the first update" {
        Write-Utf8TestFile -Path $settingsPath -Content "{}"

        Invoke-SettingsUpdater -Path $settingsPath | Out-Null
        $firstUpdate = [System.IO.File]::ReadAllText($settingsPath)
        $backupCount = (Get-SettingsBackups -Path $settingsPath).Count

        $secondResult = Invoke-SettingsUpdater -Path $settingsPath
        $secondUpdate = [System.IO.File]::ReadAllText($settingsPath)

        $secondResult[0].State | Should -Be "Current"
        $secondResult[0].Changed | Should -BeFalse
        $secondUpdate | Should -BeExactly $firstUpdate
        (Get-SettingsBackups -Path $settingsPath).Count | Should -Be $backupCount
    }

    It "preserves a UTF-8 byte-order mark" {
        Write-Utf8TestFile -Path $settingsPath -Content "{}" -Bom

        Invoke-SettingsUpdater -Path $settingsPath | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($settingsPath)

        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
    }

    It "preserves CRLF line endings" {
        $content = @(
            "{"
            '    "profiles":'
            "    {"
            '        "list": []'
            "    }"
            "}"
            ""
        ) -join "`r`n"
        Write-Utf8TestFile -Path $settingsPath -Content $content

        Invoke-SettingsUpdater -Path $settingsPath | Out-Null
        $updated = [System.IO.File]::ReadAllText($settingsPath)

        $updated | Should -Not -Match "(?<!`r)`n"
    }

    It "preserves LF line endings and the absence of a final newline" {
        $content = "{`n    `"profiles`": {}`n}"
        Write-Utf8TestFile -Path $settingsPath -Content $content

        Invoke-SettingsUpdater -Path $settingsPath | Out-Null
        $updated = [System.IO.File]::ReadAllText($settingsPath)

        $updated | Should -Not -Match "`r"
        $updated.EndsWith("`n") | Should -BeFalse
    }

    It "rejects unsupported UTF-16 settings files" {
        New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
        [System.IO.File]::WriteAllText($settingsPath, "{}", [System.Text.Encoding]::Unicode)

        { Invoke-SettingsUpdater -Path $settingsPath -Check } | Should -Throw "*must use UTF-8*"
    }

    It "rejects malformed JSONC: <Name>" -TestCases @(
        @{
            Name = "unterminated string"
            Content = '{ "actions": [ { "command": "paste } ] }'
        },
        @{
            Name = "unterminated block comment"
            Content = '{ /* unfinished'
        },
        @{
            Name = "mismatched delimiter"
            Content = '{ "actions": [ }'
        }
    ) {
        param($Name, $Content)

        Write-Utf8TestFile -Path $settingsPath -Content $Content

        { Invoke-SettingsUpdater -Path $settingsPath -Check } | Should -Throw
    }

    It "rejects duplicate root actions properties" {
        $content = @'
{
    "actions": [],
    "actions": []
}
'@
        Write-Utf8TestFile -Path $settingsPath -Content $content

        { Invoke-SettingsUpdater -Path $settingsPath -Check } | Should -Throw "*Multiple root actions*"
    }

    It "updates only the most recently modified discovered settings file by default" {
        $originalLocalAppData = $env:LOCALAPPDATA
        try {
            $localAppData = Join-Path $testRoot "LocalAppData"
            $stablePath = Join-Path $localAppData "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
            $previewPath = Join-Path $localAppData "Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
            $canaryPath = Join-Path $localAppData "Packages\Microsoft.WindowsTerminalCanary_8wekyb3d8bbwe\LocalState\settings.json"
            Write-Utf8TestFile -Path $stablePath -Content "{}"
            Write-Utf8TestFile -Path $previewPath -Content "{}"
            Write-Utf8TestFile -Path $canaryPath -Content "{}"
            [System.IO.File]::SetLastWriteTimeUtc($stablePath, [datetime]::UtcNow.AddMinutes(-3))
            [System.IO.File]::SetLastWriteTimeUtc($canaryPath, [datetime]::UtcNow.AddMinutes(-2))
            [System.IO.File]::SetLastWriteTimeUtc($previewPath, [datetime]::UtcNow.AddMinutes(-1))
            $env:LOCALAPPDATA = $localAppData

            $result = @(& $scriptUnderTest -PassThru)

            $result.Count | Should -Be 1
            $result[0].Path | Should -Be $previewPath
            [System.IO.File]::ReadAllText($stablePath) | Should -BeExactly "{}"
            [System.IO.File]::ReadAllText($canaryPath) | Should -BeExactly "{}"
            [System.IO.File]::ReadAllText($previewPath) | Should -Match '"ctrl\+v"'
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It "updates every discovered settings file with AllTerminalSettings" {
        $originalLocalAppData = $env:LOCALAPPDATA
        try {
            $localAppData = Join-Path $testRoot "LocalAppData"
            $paths = @(
                Join-Path $localAppData "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
                Join-Path $localAppData "Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
                Join-Path $localAppData "Packages\Microsoft.WindowsTerminalCanary_8wekyb3d8bbwe\LocalState\settings.json"
            )
            foreach ($path in $paths) {
                Write-Utf8TestFile -Path $path -Content "{}"
            }
            $env:LOCALAPPDATA = $localAppData

            $result = @(& $scriptUnderTest -AllTerminalSettings -PassThru)

            $result.Count | Should -Be 3
            foreach ($path in $paths) {
                [System.IO.File]::ReadAllText($path) | Should -Match '"ctrl\+v"'
            }
        }
        finally {
            $env:LOCALAPPDATA = $originalLocalAppData
        }
    }

    It "updates every explicitly supplied settings path" {
        $secondSettingsPath = Join-Path $testRoot "second\settings.json"
        Write-Utf8TestFile -Path $settingsPath -Content "{}"
        Write-Utf8TestFile -Path $secondSettingsPath -Content "{}"

        $result = Invoke-SettingsUpdater -Path @($settingsPath, $secondSettingsPath)

        $result.Count | Should -Be 2
        [System.IO.File]::ReadAllText($settingsPath) | Should -Match '"ctrl\+v"'
        [System.IO.File]::ReadAllText($secondSettingsPath) | Should -Match '"ctrl\+v"'
    }
}
