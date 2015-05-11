[CmdletBinding()]
param (
    [Parameter(Mandatory=$True)]
    [string]$ConfigPath
    , [Parameter(Mandatory=$True)]
    [string]$action
    )

if ($null -eq $PSScriptRoot)
{
    $PSScriptRoot = (Split-Path $MyInvocation.MyCommand.Path -Parent)
}

<#
 the function that install a new server instance (for HA)
 it assumes the server is already migrated in 7.1 version
#>
function installHAServer ($cnx, $cfg)
{
    # make sure the datamodel matches 7.1 and content stores are available
    # for current user
    Test-Running71 -cnx $cnx -conf $cfg

    # Change target server on jobs
    Update-JobsTargetServer -cnx $cnx -cfg $cfg

    # Update app_server_uri in server config
    Update-AppServerURI -cnx $cnx -cfg $cfg

    # Register Docbase to JMS
    Register-DocbaseToJms -cfg $cfg 

    # configuring registry
    Write-DocbaseRegKey $cfg.ToDocbaseRegistry()

    # updating service files
    Update-ServiceFile $cfg

    # creating service
    New-DocbaseService $cfg.ToDocbaseService()

    # updating the list of installed docbase
    Update-DocbaseList $cfg

    # creating initialization files
    Create-IniFiles($cfg)

    # managing docbroker changes in the server.ini
    Update-Docbrokers $cfg

    # ensure the 'share' mount-point's directory exist
    Sync-SharedMountPoint $cfg

    # ------------------- Start Content Server service ------------------------------------
    Start-ContentServerService -Name $cfg.resolve('docbase.daemon.name')
}

<#
 the function that just ensure a server can be installed
#>
function checkServer ($cnx, $cfg)
{
    # --------------------- Performs pre-Content Server ugrade operations -----------------
    # performs sanity checks against data held in database
    $migCheck = Test-MigrationTables -cnx $cnx -cfg $cfg
    if ($migCheck) 
    {
        throw 'Migration temporary tables already present'
    }
    # checks at the locations and the contents held
    Check-Locations -cnx $cnx -cfg $cfg
}

<#
 the function that installs a new server instance
#>
function installServer ($cnx, $cfg)
{
    # --------------------- Performs pre-Content Server ugrade operations -----------------
    # performs sanity checks against data held in database
    $migCheck = Test-MigrationTables -cnx $cnx -cfg $cfg
    if ($migCheck) 
    {
        throw 'Migration temporary tables already present'
    }
    # checks at the locations and the contents held
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
        Log-Info('Install owner has not changed')
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

    # do we want to reset the crypto stuff ?
    if ('reset' -eq $cfg.resolve('docbase.aek'))
    {
        Reset-AEK -cnx $cnx
    }
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

    # Update ACS config
    Update-AcsConfig -cnx $cnx -cfg $cfg

    # Register Docbase to JMS
    Register-DocbaseToJms -cfg $cfg 
}

function upgradeServer ($cfg)
{ 
    log-info ('starting the upgrade of server ' + $cfg.resolve('docbase.name') + '.' + $cfg.resolve('docbase.config'))
    # make sure the service is started for the server
    Start-ContentServerServiceIf -Name $cfg.resolve('docbase.daemon.name')

    # ------------------- Perform CS upgrade to version 7.1 -------------------------------
    # Execute dmbasic script prior to installing DARs
    Start-DmbasicStep -cfg $cfg -step 'before'

    # Install DARs listed in 'main' set
    $darsbuilder = BuildDars $cfg 'main'
    $darsbuilder.Install()

    # Execute dmbasic script after installing DARs
    Start-DmbasicStep -cfg $cfg -step 'after'

    # Change version number to target version in dm_documentum_config.txt
    $dm_dctm_cfg = $cfg.resolve('env.documentum') + '\dba\dm_documentum_config.txt'
    $section = 'DOCBASE_' + $cfg.resolve('docbase.name')
    [iniFile]::WriteValue($dm_dctm_cfg,  $section, "VERSION", $cfg.resolve('docbase.target.version'))
}

function restoreServer ($cnx)
{
    # Recreate indexes from definition stored in temp table
    Restore-CustomIndexes -cnx $cnx | out-null

    # Re-activate jobs
    Restore-ActiveJobs -cnx $cnx | out-null

    # Remove temporary mig tables
    Remove-MigrationTables -cnx $cnx | out-null
}

function uninstallServer ($cfg)
{
    $docbasename = $cfg.resolve('docbase.name')
    $svcname = $cfg.resolve('docbase.daemon.name')
    # stopping the content server ...
    Stop-ContentServerServiceIf -Name $svcname
    # remove content server service instance
    Remove-ContentServerServiceIf -Name $svcname

    # remove entries from services file ?
    $services = $cfg.resolve('file.services')
    if (test-path $services)
    {
        # '^myservice2(_s)?.*$'
        $exp = '^' + $cfg.resolve('docbase.service') + '(_s)?[ \t]+.*$'
        if (0 -lt ((type $services) -match $exp).length)
        {
            (type $services) -notmatch $exp | out-file -FilePath $services -Encoding 'ASCII'
            log-info "removed services entries for server $docbase.name"
        }
    }

    # remove registry entry
    $reg = 'HKLM:\Software\Documentum\DOCBASES\' + $docbasename
    if (test-path $reg)
    {
        remove-item $reg -recurse  | Out-Null
        log-info "removed registry entry $reg"
    }

    # remove directory containing the config
    $init = $cfg.resolve('docbase.daemon.dir')
    if (test-path $init)
    {
        remove-item $init -recurse  | Out-Null
        log-info "removed directory $init"
    }    

    # remove docbase section from dm_documentum_config.txt
    $dm_dctm_cfg = $cfg.resolve('env.documentum') + '\dba\dm_documentum_config.txt'   
    $section = "DOCBASE_$docbasename"
    [IniFile]::DeleteSection($dm_dctm_cfg, $section)
    Log-Info("Removed section $section from $dm_dctm_cfg")

    # unregister docbase from JMS
    $path =  $cfg.resolve('docbase.jms.web_inf') + '\web.xml'
    $jmsconf = New-JmsConf($cfg.resolve('docbase.jms.web_inf') + '\web.xml')
    $jmsconf.Unregister($docbasename)
    $jmsconf.Save()
    log-info "Docbase successfully unregistered from JMS"

    # Unregister docbase from docbrokers
    $docbrokers = $cfg.docbase.docbrokers
    foreach($i in $docbrokers.Keys)
    {       
        $hostname = $cfg.resolve('docbase.docbrokers.' + $i + '.host')
        $port = $cfg.resolve('docbase.docbrokers.' + $i + '.port')
        try 
        {
            $broker = $cfg.resolve('env.DM_HOME') + '\bin\dmqdocbroker.bat'
            Start-Process -FilePath "$broker" -ArgumentList "-t $hostname -p $port -c deregister $docbasename" -NoNewWindow -Wait -ErrorAction stop
            Log-Verbose "Unregistered docbase $docbasename from Docbroker $i host= $hostname port= $port"
        }
        catch 
        {
            Log-Warning "Failed to unregister docbase $docbasename from Docbroker $i host= $hostname port= $port - $($_.Exception.Message)"
        }        
    }

    log-info "done uninstalling server $docbasename"
}

function usage ()
{
    write-host 'migrate1.ps ${config.path} ${action}'
    write-host 'where:'
    write-host ' ${config.path}: is the path containing the server.ini, the ldapxxx.cnt, '
    write-host '   the dbpasswd.txt and the migrate.properties file of use'
    write-host ' ${action} holds the action to perform. It either matches:'
    write-host '   check: makes sure the migration tables, locations and related '
    write-host '   contents are ok'
    write-host '   install: installs the content server and upgrades its version'
    write-host '   installha: installs another content server instance of an already ' 
    write-host '     upgraded docbase'
    write-host '   upgrade: upgrades the matching docbase through the existing'
    write-host '     content server'
    write-host '   restore: restore jobs states and indexes once docbase is upgraded'
    write-host '   uninstall: uninstall an existing content server instance'
    write-host '   dump: dumps the current configuration and the resolved equivalent'
    write-host '   dumpr: dumps the current configuration once resolved'
    write-host '   help: displays this screen'
}
try
{
    if ('help' -eq $action)
    {
     usage
     return
    }

    # Start transcription of the PS session to a log file.
    $logDate = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogFileLocation = "$ConfigPath\$logDate-$action-migration_log.txt"
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
      
    # Include jms functions
    . "$PSScriptRoot\lib_jms.ps1"

    # Include docbase registration functions
    . "$PSScriptRoot\lib_docbase_mig.ps1"

    # Include database functions
    . "$PSScriptRoot\lib_database.ps1"

    # Include dars functions
    . "$PSScriptRoot\lib_dars.ps1"
  
    $startTime = Get-Date  -Verbose
    Log-Info "*** Content Server upgrade migration operations started on $startTime ***"

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

    # Prepare migration temp tables
    # Open ODBC connection
    $cnx = New-Connection $cfg.ToDbConnectionString()
    try
    {
        # Retrieve extra dynamic values
        Read-Dynamic-Conf -cnx $cnx -conf $cfg
        # make sure the environment seems OK
        $cfg = check $cfg $action
        if ('install' -eq $action)
        {
            # current current user's pwd
            $pwd = readPwd $cfg.resolve('user.domain') $cfg.resolve('user.name')
            if ($null -eq $pwd)
            {
                return
            }
            $cfg.user.pwd = $pwd

            installServer -cnx $cnx -cfg $cfg
            upgradeServer -cfg $cfg
            restoreServer -cnx $cnx
        }
        elseif ('check' -eq $action)
        {
            checkServer -cnx $cnx -cfg $cfg
        }
        elseif ('upgrade' -eq $action)
        {
            # current current user's pwd
            $pwd = readPwd $cfg.resolve('user.domain') $cfg.resolve('user.name')
            if ($null -eq $pwd)
            {
                return
            }
            upgradeServer -cfg $cfg
        }
        elseif ('restore' -eq $action)
        {
            restoreServer -cnx $cnx
        }
        elseif ('installha' -eq $action)
        {
            # current current user's pwd
            $pwd = readPwd $cfg.resolve('user.domain') $cfg.resolve('user.name')
            if ($null -eq $pwd)
            {
                return
            }
            $cfg.user.pwd = $pwd
            installHAServer -cnx $cnx -cfg $cfg
        }
        elseif ('uninstall' -eq $action)
        {
            uninstallServer -cfg $cfg
        }
        elseif ('dump' -eq $action)
        {
            write 'configuration (raw):'
            write $cfg.dump()
        }
        elseif ('dumpr' -eq $action)
        {
            write 'configuration (resolved):'
            write $cfg.show()
        }
        else
        {
            usage
            throw "unexpected action to perform: '$action'"
        }
        $endTime = Get-Date  -Verbose
        log-info ("Done with migrate program on $endTime")
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