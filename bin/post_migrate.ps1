[CmdletBinding()]
param (  
    [Parameter(Mandatory=$True)]
    [string]$configPath
    )

try
{
    # Start transcription of the PS session to a log file.
    $logDate = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogFileLocation = "$configPath\post_migration_log-$logDate.txt"
    try
    {         
        Start-Transcript -path $LogFileLocation -append  
    }
    catch 
    {
        Write-Warning "Unable to transcribe the current session to file ""$LogFileLocation"" : $($_.Exception.Message)"
    }

    # Include config functions
    . "$PSScriptRoot\lib_config.ps1"

    # Include docbase registration functions
    . "$PSScriptRoot\lib_docbase_mig.ps1"
     
    # Include database functions
    . "$PSScriptRoot\lib_database.ps1"  
   
    $startDate = Get-Date  -Verbose     
    Log-Info "Post migration script started on $startDate"
 
    #check for configuration path validity
    $configPath = Resolve-Path $configPath -ErrorAction SilentlyContinue -ErrorVariable pathErr    
    if ($pathErr)
    {
        throw $pathErr
    }   
    Log-Info "Configuration path: $configPath"
    $cfg = Initialize $configPath    
  
    $cnx = New-Connection $cfg.ToDbConnectionString()
    try
    {         
        # Recreate indexes from definition stored in temp table   
        Restore-CustomIndexes -cnx $cnx

        # Re-activate jobs
        Restore-ActiveJobs -cnx $cnx

        # Remove temporary mig tables
        Remove-MigrationTables -cnx $cnx      
    }
    finally
    {
       if ($null -ne $cnx)
        {
           $cnx.Close()
        }
   }
} 
catch 
{     
    # A fatal error has occured: the script will stop.  
    Log-Error $_.Exception
    Log-Error $_.ScriptStackTrace  
} 
finally
{
    # Stop session transcript (should be fail safe).
    try
    {
        Stop-Transcript
    }
    catch {}
}


