[CmdletBinding()]
param (  
    [Parameter(Mandatory=$True)]
    [string]$configPath
    )
     
#check for configuration path validity
$configPath = Resolve-Path $configPath -ErrorAction Stop
Write-Output "Configuration path: $configPath"

# Include config functions
. "$PSScriptRoot\lib_config.ps1"

# initialize the environment
$cfg = Initialize $configPath

# remove registry entries
Remove-Item -Path "HKLM:\SOFTWARE\Documentum\DOCBASES\$($cfg.resolve('docbase.name'))" -ErrorAction Continue

# Remove Docbase folder
$dctmCfgPath = $cfg.resolve('env.documentum') + '\dba\config\' + $cfg.resolve('docbase.name')
Remove-Item -Path $dctmCfgPath -Recurse -Force -ErrorAction Continue

# Remove Docbase service
sc.exe DELETE DmServerQUALITY

# Remove docbase ports definitions

$svcPath = $cfg.resolve('file.services')
$svcBak = $svcPath + '.bak'
$svctmp = $svcPath +'.tmp'
$pattern = '^' + $cfg.resolve('docbase.service')
get-content $svcPath | select-string -pattern $pattern -NotMatch | Out-File $svctmp -Encoding ascii -Force
if (Test-Path $svcBak)
{
    Remove-Item $svcBak -Force
}
Rename-Item -Path $svcPath -NewName $svcBak -Force
Rename-Item -Path $svctmp -NewName $svcPath -Force
