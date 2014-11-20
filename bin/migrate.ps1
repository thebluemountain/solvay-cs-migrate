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

    # TODO - change version number to 7.1.0.151 in dm_documentum_config.txt

#[DOCBASE_RCSEHS]
#....
#VERSION=7.1.0.151
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
        $exp = '^' + $cfg.resolve('docbase.service') + '(_s)?.*$'
        if (0 -lt ((type $services) -match $exp).length)
        {
            (type $services) -notmatch $exp | out-file -FilePath $services -Encoding 'ASCII'
            log-info "removed services entries for server $docbase.name"
        }
    }

    # remove reference to the docbase in the documentum.txt
    $txtfile = $cfg.resolve('env.documentum') + '\dba\dm_documentum_config.txt'
    log-info "you should remove docbase section $docbasename' in txtfile"

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

    # Unregister docbase from docbrokers
    $docbrokers = $cfg.docbase.docbrokers
    foreach($i in $docbrokers.Keys)
    {       
        $hostname = $cfg.resolve('docbase.docbrokers.' + $i + '.host')
        $port = $cfg.resolve('docbase.docbrokers.' + $i + '.port')
        try 
        {             
            Start-Process -FilePath '"F:\Documentum\product\7.1\bin\dmqdocbroker.bat"' -ArgumentList "-t $hostname -p $port -c deregister $docbasename" -NoNewWindow -Wait -ErrorAction stop
            Log-Verbose "Unregistered docbase $docbasename from Docbroker $i host= $hostname port= $port"
        }
        catch 
        {
            Log-Warning "Failed to unregister docbase $docbasename from Docbroker $i host= $hostname port= $port - $($_.Exception.Message)"
        }
        
    }

    log-info "done uninstalling server $docbasename"
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
      
    # Include jms functions
    . "$PSScriptRoot\lib_jms.ps1"

    # Include docbase registration functions
    . "$PSScriptRoot\lib_docbase_mig.ps1"

    # Include database functions
    . "$PSScriptRoot\lib_database.ps1"

    # Include dars functions
    . "$PSScriptRoot\lib_dars.ps1"
  
    $startDate = Get-Date  -Verbose
    Log-Info "*** Content Server upgrade migration operations started on $startDate ***"

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
        elseif ('upgrade' -eq $action)
        {
            upgradeServer -cfg $cfg
        }
        elseif ('uninstall' -eq $action)
        {
            uninstallServer -cfg $cfg
        }
        elseif ('dump' -eq $action)
        {
            write 'configuration (raw):'
            write $cfg.dump()
            write 'configuration (resolved):'
            write $cfg.show()
        }
        else
        {
            throw "unexpected action to perform: '$action'"
        }
        log-info ('done with migrate program')
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