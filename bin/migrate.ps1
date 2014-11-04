[CmdletBinding()]
param (  
    [Parameter(Mandatory=$True)]
    [string]$configPath
    )

if ($null -eq $PSScriptRoot)
{
    $PSScriptRoot = (Split-Path $MyInvocation.MyCommand.Path -Parent)
}

try
{
    # Start transcription of the PS session to a log file.
    $logDate = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogFileLocation = "$configPath\migration_log-$logDate.txt"
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

    # ------------------- 1- Validate environment --------------------

    $startDate = Get-Date  -Verbose     
    Log-Info ("Migration script started on $startDate")
 
    #check for configuration path validity
    $configPath = Resolve-Path $configPath -ErrorAction SilentlyContinue -ErrorVariable pathErr
    if ($pathErr)
    {
        throw $pathErr
    }   
    Log-Info("Configuration path: $configPath")

    # initialize the environment
    $cfg = Initialize $configPath

    # current current user's pwd
    $pwd = readPwd $cfg.resolve('user.domain') $cfg.resolve('user.name')
    if ($null -eq $pwd)
    {
     return
    }
    $cfg.user.pwd = $pwd

    # make sure the environment seems OK
    $cfg = check $cfg  

    # Prepare migration temp tables 
    $cnx = New-Connection $cfg.ToDbConnectionString()
    try
    {
        if (Test-MigrationTables($cnx)) {
            throw "Migration temporary tables already present"
        }
    }
    finally
    {
       if ($null -ne $cnx)
        {
            $cnx.Close()
        }
    }
    
    # ---------------------- Apply modification to environnment prior to update ----------------------
    # Open ODBC connection
    $cnx = New-Connection $cfg.ToDbConnectionString()
    try
    {   
        # managing the install owner name change
  
        # is there a change ?     
        $installOwnerChanged = Test-InstallOwnerChanged -cnx $cnx -cfg $cfg

        if ($installOwnerChanged -ne [InstallOwnerChanges]::None)      
        {
            # ensuring current user does not exists
            Test-UserExists -cnx $cnx -cfg $cfg
            # managing the change of install owner
            Change-InstallOwner -cnx $cnx -cfg $cfg -scope $installOwnerChanged                
        }
        else
        {
            Log-Info("Install owner has not changed")
        }
        # Disable all jobs and 
        Disable-Jobs -cnx $cnx -cfg $cfg
        
        # Change target server on jobs
        Update-JobsTargetServer -cnx $cnx -cfg $cfg

        # TODO - record & delete custom indexes
        
        # configuring registry
        Write-DocbaseRegKey $cfg.ToDocbaseRegistry()

        # creating initialization files    
        Create-IniFiles($cfg)

        # updating service files
        Update-ServiceFile($cfg)

        # creating service
        New-DocbaseService $cfg.ToDocbaseService()

        # updating the list of installed docbase
        Update-DocbaseList($cfg)
        
        # updating the server.ini file
        [iniFile]::WriteValue("$dctmCfgPath\server.ini", "SERVER_STARTUP", "install_owner", $cfg.resolve('user.name'))  
        [iniFile]::WriteValue("$dctmCfgPath\server.ini", "SERVER_STARTUP", "user_auth_target", $cfg.resolve('docbase.auth'))  

        # managing docbroker changes
        Update-Docbrokers($cfg)

        # managing file store changes
        Check-Locations -cnx $cnx -cfg $cfg       
        Update-Locations -cnx $cnx -cfg $cfg

        # fixing some dm_location
        Update-DmLocations -cnx $cnx -cfg $cfg       

        # Fix mount points
        Update-MountPoint -cnx $cnx -cfg $cfg
       
        # Update Server config
        Update-ServerConfig -cnx $cnx -cfg $cfg
        

        # TODO - updating app_server_uri in server config        


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
