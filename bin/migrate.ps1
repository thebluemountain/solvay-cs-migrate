[CmdletBinding()]
param (  
    [Parameter(Mandatory=$True)]
    [string]$configPath
    )

try
{
    # Start transcription of the PS session to a log file.
    $logDate = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogFileLocation = "$PSScriptRoot\migration_log-$logDate.txt"
    try
    {         
        Start-Transcript -path $LogFileLocation -append  
    }
    catch 
    {
        Write-Warning "Unable to transcribe the current session to file ""$LogFileLocation"" : $($_.Exception.Message)"
    }

    $startDate = Get-Date  -Verbose     
    Write-Output "Migration script started on $startDate"

    # Include config functions
    . "$PSScriptRoot\lib_config.ps1"

    # Include docbase registration functions
    . "$PSScriptRoot\lib_docbase_reg.ps1"
     
    # Include database functions
    . "$PSScriptRoot\lib_database.ps1"
 
    #check for configuration path validity
    $configPath = Resolve-Path $configPath -ErrorAction SilentlyContinue -ErrorVariable pathErr    
    if ($pathErr)
    {
        throw $pathErr
    }   
    Write-Output "Configuration path: $configPath"

    # 2: initialize the environment
    $cfg = Initialize $configPath
    $cfg.docbase.rdbms = 'SQLServer'
    if (! $cfg.env.Contains('DOCUMENTUM'))
    {
     $cfg.env.DOCUMENTUM = '${env.HOMEDRIVE}${env.HOMEPATH}\Documents\Documentum'
    }
    if (! $cfg.env.Contains('DM_HOME'))
    {
     $cfg.env.DM_HOME = '${env.DOCUMENTUM}\prog\7.1'
    }

    # 3: current current user's pwd
    $pwd = readPwd $cfg.env.USERDOMAIN $cfg.env.USERNAME
    if ($null -eq $pwd)
    {
     return
    }
    # (pseudo-encrypted) password is stored in the object then ...
    $cfg.pwd = $pwd

    # 3: make sure the environment seems OK
    $cfg = check $cfg

    # Make sure there is no registry entry HKEY_LOCAL_MACHINE\SOFTWARE\Documentum\DOCBASES\${cfg.docbase.name}
   
   
    # Set registry   
    $reg = asDocbaseRegistry $cfg
    Write-DocbaseRegKey $reg

    # Create docbase service
    $svc = asDocbaseService $cfg
    New-DocbaseService $svc

 } 
 catch 
{ 
    
    [System.Exception] $ex = $_.Exception      
    
    Write-Error $ex
    Write-Error $_.ScriptStackTrace
   # $logger.Fatal('Fatal error:  The migration script will stop - $($ex.ToString())')
} 
finally
{
    try
    {
        Stop-Transcript
    }
    catch {}
}



 