BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1') }

Describe 'Portable script importer' {
    BeforeEach {
        $script:SavedToolkitRoot = $script:ToolkitRoot
        $script:ToolkitRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:ToolkitRoot -Force | Out-Null
    }
    AfterEach {
        $script:ToolkitRoot = $script:SavedToolkitRoot
    }

    It 'imports a local script with sibling metadata and prevents unintended overwrite' {
        $src = Join-Path $TestDrive 'PingCheck.ps1'
        Set-Content -LiteralPath $src -Value 'Write-Output "OK"'
        Set-Content -LiteralPath ($src + '.json') -Value '{"schemaVersion":1,"name":"Ping Check","description":"Fixture test","requiresAdmin":false}'

        $imported = @(Import-ToolkitLocalScript -Path $src -Folder 'IT-Support')
        $imported.Count | Should -Be 1
        $imported[0].id | Should -Be 'custom/it-support/pingcheck.ps1'
        $imported[0].name | Should -Be 'Ping Check'
        Test-Path -LiteralPath (Join-Path $script:ToolkitRoot 'Scripts\IT-Support\PingCheck.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:ToolkitRoot 'Scripts\IT-Support\PingCheck.ps1.json') | Should -BeTrue

        { Import-ToolkitLocalScript -Path $src -Folder 'IT-Support' } | Should -Throw '*already exists*'
        $replaced = @(Import-ToolkitLocalScript -Path $src -Folder 'IT-Support' -Name 'Updated Name' -Overwrite)
        $replaced[0].name | Should -Be 'Updated Name'
    }

    It 'imports valid ZIP script packs and rejects path traversal or unsupported entries' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zipPath = Join-Path $TestDrive 'pack.zip'
        $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $e1 = $zip.CreateEntry('Tinkerer/Check.ps1')
            $w1 = New-Object IO.StreamWriter($e1.Open())
            $w1.Write('Write-Output "zip"')
            $w1.Dispose()
            $e2 = $zip.CreateEntry('Tinkerer/Check.ps1.json')
            $w2 = New-Object IO.StreamWriter($e2.Open())
            $w2.Write('{"schemaVersion":1,"name":"Zip Tool","requiresAdmin":false}')
            $w2.Dispose()
        }
        finally { $zip.Dispose() }

        $imported = @(Import-ToolkitLocalScript -Path $zipPath)
        $imported.Count | Should -Be 1
        $imported[0].name | Should -Be 'Zip Tool'

        $badZip = Join-Path $TestDrive 'bad.zip'
        $z2 = [IO.Compression.ZipFile]::Open($badZip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $bad = $z2.CreateEntry('../escape.ps1')
            $bw = New-Object IO.StreamWriter($bad.Open())
            $bw.Write('bad')
            $bw.Dispose()
        }
        finally { $z2.Dispose() }
        { Import-ToolkitLocalScript -Path $badZip } | Should -Throw '*Unsafe path*'
    }

    It 'enforces https URLs and verifies SHA-256 on URL script import' {
        { Invoke-ToolkitHttpsDownload -Url 'http://example.com/test.ps1' } | Should -Throw '*https://*'

        $payload = [Text.Encoding]::UTF8.GetBytes("Write-Output 'hello'`r`n")
        $hash = Get-ToolkitByteSha256 -Bytes $payload
        Mock Invoke-ToolkitHttpsDownload { param($Url) $null = $Url; return ,$payload }

        { Import-ToolkitUrlScript -Url 'https://example.com/Tools/Hello.ps1' -ExpectedSha256 ('0' * 64) } | Should -Throw '*SHA-256*'
        $saved = @(Import-ToolkitUrlScript -Url 'https://example.com/Tools/Hello.ps1' -Folder 'Net' -ExpectedSha256 $hash -Name 'Remote Hello')
        $saved.Count | Should -Be 1
        $saved[0].name | Should -Be 'Remote Hello'
        Test-Path -LiteralPath (Join-Path $script:ToolkitRoot 'Scripts\Net\Hello.ps1') | Should -BeTrue
    }

    It 'parses published manifests and enforces SHA-256 when importing entries' {
        $scriptBytes = [Text.Encoding]::UTF8.GetBytes("Write-Output 'manifest-script'`r`n")
        $scriptHash = Get-ToolkitByteSha256 -Bytes $scriptBytes
        $manifestJson = @{
            schemaVersion = 1
            publisher = 'ToolX'
            scripts = @(
                @{
                    name = 'Published Check'
                    description = 'Verifies host.'
                    folder = 'IT-Support'
                    fileName = 'Published-Check.ps1'
                    url = 'https://example.com/scripts/Published-Check.ps1'
                    sha256 = $scriptHash
                    requiresAdmin = $false
                }
            )
        } | ConvertTo-Json -Depth 4
        $manifestBytes = [Text.Encoding]::UTF8.GetBytes($manifestJson)

        Mock Invoke-ToolkitHttpsDownload {
            param($Url)
            if ($Url -like '*manifest.json') { return ,$manifestBytes }
            return ,$scriptBytes
        }

        $manifest = Get-ToolkitPublishedManifest -Url 'https://example.com/manifest.json'
        $manifest.Publisher | Should -Be 'ToolX'
        $manifest.Scripts.Count | Should -Be 1

        $imported = @(Import-ToolkitManifestScript -Entries $manifest.Scripts)
        $imported.Count | Should -Be 1
        $imported[0].id | Should -Be 'custom/it-support/published-check.ps1'
        Test-Path -LiteralPath (Join-Path $script:ToolkitRoot 'Scripts\IT-Support\Published-Check.ps1') | Should -BeTrue
    }
}
