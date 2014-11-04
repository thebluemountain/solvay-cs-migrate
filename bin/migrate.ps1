[CmdletBinding()]
param (  
    [Parameter(Mandatory=$True)]
    [string]$configPath
    )

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
    Log-Info("Migration script started on $startDate")
 
    #check for configuration path validity
    $configPath = Resolve-Path $configPath -ErrorAction SilentlyContinue -ErrorVariable pathErr    
    if ($pathErr)
    {
        throw $pathErr
    }   
    Log-Info("Configuration path: $configPath")

    # 1.1: initialize the environment
    $cfg = Initialize $configPath    

    # 1.2: current current user's pwd
    $pwd = readPwd $cfg.resolve('user.domain') $cfg.resolve('user.name')
    if ($null -eq $pwd)
    {
     return
    }
    $cfg.pwd = $pwd

    # 1.3: make sure the environment seems OK
    $cfg = check $cfg  

    # Prepare migration temp tables 
    $cnx = New-Connection $cfg.ToDbConnectionString()
    try
    {
        if (Test-MigrationTables($cnx)) {
            throw "Migration temporary tables already present"
        }

       # New-MigrationTables -cnx $cnx  
    }
    finally
    {
       if ($null -ne $cnx)
        {
            $cnx.Close()
        }
    }
    
    # ------------------ 2- preparing the installation ------------------------

    # 2.1- configuring registry
    Write-DocbaseRegKey $cfg.ToDocbaseRegistry()

    # 2.2- creating initialization files    
    Create-IniFiles($cfg)

    # 2.3- updating service files
    Update-ServiceFile($cfg)

    # 2.4- creating service
    New-DocbaseService $cfg.ToDocbaseService()

    # 2.5- updating the list of installed docbase
    Update-DocbaseList($cfg)
        
    # ----------------------  3- modifying installation to allow for starting in new environment -----------------
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

        # Disable all jobs and 
        Disable-Jobs -cnx $cnx -cfg $cfg
        
        # Change target server on jobs
        Update-JobsTargetServer -cnx $cnx -cfg $cfg

        # Fix mount points
        Update-MountPoint -cnx $cnx -cfg $cfg
       
        # Update Server config
        Update-ServerConfig -cnx $cnx -cfg $cfg
        

        # TODO - updating app_server_uri in server config        


        # TODO - Managing custom indexes
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



 