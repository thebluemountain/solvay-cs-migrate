[CmdletBinding()]
param (
    [Parameter(Mandatory=$True)]
    [string]$ConfigPath,
    [switch]
    [bool]$PostUpgrade = $false
    )

if ($null -eq $PSScriptRoot)
{
    $PSScriptRoot = (Split-Path $MyInvocation.MyCommand.Path -Parent)
}

try
{
    # Start transcription of the PS session to a log file.
    $logDate = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogFileLocation = "$ConfigPath\migration_log-$logDate.txt"
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
    if (-not $PostUpgrade)
    {
        Log-Info "*** Pre-Content Server upgrade migration operations started on $startDate ***"
    }
    else
    {
        Log-Info "*** Post-Content Server upgrade migration operations started on $startDate ***"
    }
     
    # --------------------------- Validate environment ------------------------------------------
    
    #check for configuration path validity
    $ConfigPath = Resolve-Path $ConfigPath -ErrorAction SilentlyContinue -ErrorVariable pathErr
    if ($pathErr)
    {
        throw $pathErr
    }
    Log-Info("Configuration path: $ConfigPath")

    # initialize the environment
    $cfg = Initialize $ConfigPath

    # Resolve and log config object content
    Log-Verbose $cfg.dump()
    Log-Verbose $cfg.show()
    
    # current current user's pwd
    $pwd = readPwd $cfg.resolve('user.domain') $cfg.resolve('user.name')
    if ($null -eq $pwd)
    {
     return
    }
    $cfg.user.pwd = $pwd

    if (-not $PostUpgrade)
    {   
        # make sure the environment seems OK
        $cfg = check $cfg
    }

    # Prepare migration temp tables
    # Open ODBC connection
    $cnx = New-Connection $cfg.ToDbConnectionString()
    try
    {
        if (-not $PostUpgrade)
        {            
            # --------------------- Performs pre-Content Server ugrade operations -----------------

            # Retrieve the values for the email address and SMTP server used
            set-Smtp_parameters -cnx $cnx -cfg $cfg

            # performs sanity checks against data held in database
            $migCheck = Test-MigrationTables -cnx $cnx -cfg $cfg
            if ($migCheck) 
            {
                throw "Migration temporary tables already present"
            }
            Check-Locations -cnx $cnx -cfg $cfg

            # managing the install owner name change

            # is there a change ?
            $installOwnerChanged = Test-InstallOwnerChanged -cnx $cnx -cfg $cfg

            if ($installOwnerChanged -ne [InstallOwnerChanges]::None)
            {
                # if we need to rename ...
                if ($installOwnerChanged -band [InstallOwnerChanges]::Name)
                {
                    # ensuring current user does not exists
                    Test-UserExists -cnx $cnx -cfg $cfg
                }
                # managing the change of install owner
                Change-InstallOwner -cnx $cnx -cfg $cfg -scope $installOwnerChanged
            }
            else
            {
                Log-Info("Install owner has not changed")
            }
            # Disable all jobs 
            Disable-Jobs -cnx $cnx -cfg $cfg

            # Change target server on jobs
            Update-JobsTargetServer -cnx $cnx -cfg $cfg

            # Disable projections
            Disable-Projections -cnx $cnx -name $cfg.resolve('docbase.config')

            # Create the temporay table for custom indexes
            Create-mig_indexesTable -cnx $cnx

            # Save custom indexes definition in temp table and drop indexes
            Save-CustomIndexes -cnx $cnx -cfg $cfg

            # creating initialization files
            Create-IniFiles($cfg)

            # configuring registry
            Write-DocbaseRegKey $cfg.ToDocbaseRegistry()

            # updating service files
            Update-ServiceFile($cfg)

            # creating service
            New-DocbaseService $cfg.ToDocbaseService()

            # updating the list of installed docbase
            Update-DocbaseList($cfg)

            # managing docbroker changes
            Update-Docbrokers($cfg)

            # managing file store changes
            Update-Locations -cnx $cnx -cfg $cfg

            # fixing some dm_location
            Update-DmLocations -cnx $cnx -cfg $cfg

            # Fix mount points
            Update-MountPoint -cnx $cnx -cfg $cfg

            # Update Server config
            Update-ServerConfig -cnx $cnx -cfg $cfg

            # Update app_server_uri in server config
            Update-AppServerURI -cnx $cnx -cfg $cfg

            # ------------------- Start Content Server service ------------------------------------
            Start-ContentServerService -Name $cfg.resolve('docbase.daemon.name')

            # ------------------- Perform CS upgrade to version 7.1 -------------------------------
            
            # Execute dmbasic script prior to installing DARs
            Start-DmbasicScriptCollection($cfg.resolve('dmbasic.run_before_dar_install'))

            # Install DARs
            # TODO

            # Execute dmbasic script after installing DARs
            Start-DmbasicScriptCollection($cfg.resolve('dmbasic.run_after_dar_install'))
        }
        else
        {
            # ------------------- Performs post-Content Server ugrade operations ------------------
                     
            # Recreate indexes from definition stored in temp table   
            Restore-CustomIndexes -cnx $cnx

            # Re-activate jobs
            Restore-ActiveJobs -cnx $cnx

            # Remove temporary mig tables
            Remove-MigrationTables -cnx $cnx
        }
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
    Write-Error $_.Exception
    Write-Error $_.ScriptStackTrace
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