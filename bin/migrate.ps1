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
    . "$PSScriptRoot\lib_docbase_reg.ps1"
     
    # Include database functions
    . "$PSScriptRoot\lib_database.ps1"

    # ------------------- 1- Validate environment --------------------

    $startDate = Get-Date  -Verbose     
    Write-Output "Migration script started on $startDate"
 
    #check for configuration path validity
    $configPath = Resolve-Path $configPath -ErrorAction SilentlyContinue -ErrorVariable pathErr    
    if ($pathErr)
    {
        throw $pathErr
    }   
    Write-Output "Configuration path: $configPath"

    # 1.1: initialize the environment
    $cfg = Initialize $configPath    

    # 1.2: current current user's pwd
    $pwd = readPwd $cfg.env.USERDOMAIN $cfg.env.USERNAME
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
    $dctmCfgPath = $cfg.resolve('env.documentum') + '\dba\config\' + $cfg.resolve('docbase.name')
    New-Item -Path $dctmCfgPath -ItemType "directory" -Force   
    Copy-Item -Path $cfg.resolve('file.server_ini') -Destination "$dctmCfgPath\server.ini"   
    Copy-Item -Path $cfg.resolve('file.dbpasswd_txt') -Destination "$dctmCfgPath\dbpasswd.txt"       
    New-Item -Path $dctmCfgPath -name dbpasswd.tmp.txt -itemtype "file" -value $cfg.resolve('docbase.pwd')   
    [iniFile]::WriteValue("$dctmCfgPath\server.ini", "SERVER_STARTUP", "database_password_file", "$dctmCfgPath\dbpasswd.tmp.txt")  

    # 2.3- updating service files
    $etcServicesFile = $cfg.resolve('file.services')
    [uint16] $maxTcpPort = Get-MaxTcpPort  -Path $etcServicesFile
    if ($maxTcpPort -eq [uint16]::MaxValue-1)
    {
        throw "Max tcp port number already used in services file"
    }
    add-Content -Path $etcServicesFile -Value "$($cfg.resolve('docbase.service'))    $($maxTcpPort + 1)/tcp   # $($cfg.resolve('docbase.daemon.display'))"
    add-Content -Path $etcServicesFile -Value "$($cfg.resolve('docbase.service'))_s  $($maxTcpPort + 2)/tcp   # $($cfg.resolve('docbase.daemon.display')) (secure)"

    # 2.4- creating service
    New-DocbaseService $cfg.ToDocbaseService()


    # 2.5- updating the list of installed docbase
    $dm_dctm_cfg = $cfg.resolve('env.documentum') + '\dba\dm_documentum_config.ini'
    if (-not( Test-Path -Path  $dm_dctm_cfg))
    {
        throw "$dm_dctm_cfg does not exists"
    }
    $section = "DOCBASE_$($cfg.resolve('docbase.name'))"
    [iniFile]::WriteValue($dm_dctm_cfg,  $section, "NAME", $cfg.resolve('docbase.name'))
    [iniFile]::WriteValue($dm_dctm_cfg,  $section, "VERSION", $cfg.resolve('docbase.previous.version'))
    [iniFile]::WriteValue($dm_dctm_cfg,  $section, "DATABASE_CONN", $cfg.resolve('docbase.dsn'))
    [iniFile]::WriteValue($dm_dctm_cfg,  $section, "DATABASE_NAME", $cfg.resolve('docbase.database'))
    
    
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
            Write-Output "Install owner has not changed"
        }
   
        # updating the server.ini file  
        [iniFile]::WriteValue("$dctmCfgPath\server.ini", "SERVER_STARTUP", "install_owner", $cfg.env.USERNAME)  
        [iniFile]::WriteValue("$dctmCfgPath\server.ini", "SERVER_STARTUP", "user_auth_target", $cfg.resolve('docbase.auth'))  

        # managing docbroker changes
        Update-Docbrokers($cfg)

        # managing file store changes
        Check-Locations -cnx $cnx -cfg $cfg       
        Update-Locations -cnx $cnx -cfg $cfg

        # disabling all jobs
        Disable-Jobs -cnx $cnx -cfg cfg

        # Fix mount points
        Fix-MountPoint -cnx $cnx -cfg $cfg
       
        # fixing some dm_location
        Fix-DmLocations -cnx $cnx -cfg $cfg

        # 3.7- updating app_server_uri in server config
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



 