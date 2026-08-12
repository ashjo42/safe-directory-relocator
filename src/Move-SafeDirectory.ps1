[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'SafeDirectoryRelocator.psm1') -Force
Invoke-SdrMove -ConfigPath $ConfigPath -ValidateOnly:$ValidateOnly
