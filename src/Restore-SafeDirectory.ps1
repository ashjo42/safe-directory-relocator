[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'SafeDirectoryRelocator.psm1') -Force
Invoke-SdrRestore -ConfigPath $ConfigPath
