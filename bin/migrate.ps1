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
    
    $startDate = Get-Date  -Verbose     
    Write-Output "Migration script started on $startDate"
 
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

    
    # 2- preparing the installation
    # 2.1- configuring registry
    Write-DocbaseRegKey $cfg.ToDocbaseRegistry()

    # 2.2- creating initialization files    
    # Create the ${cfg.env.documentum}\dba\config\${cfg.docbase.name} directory
    # Copy file ${cfg.file.server_ini} into ${cfg.env.documentum}\dba\config\${cfg.docbase.name}
    # Copy file ${cfg.file.dbpasswd_txt} into ${cfg.env.documentum}\dba\config\${cfg.docbase.name}
    # Create file dbpasswd.tmp.txt in ${cfg.env.documentum}\dba\config\${cfg.docbase.name} with single line containing ${cfg.docbase.pwd}
    # Update the server.ini to point to own password file
    # Set database_password_file entry in [SERVER_STARTUP] section to ${cfg.env.documentum}\dba\config\${cfg.docbase.name}\dbpasswd.tmp.txt

    $dctmCfgPath = $cfg.resolve('env.documentum') + '\dba\config\' + $cfg.resolve('docbase.name')
    New-Item -Path $dctmCfgPath -ItemType "directory" -Force   
    Copy-Item -Path $cfg.resolve('file.server_ini') -Destination "$dctmCfgPath\server.ini"   
    Copy-Item -Path $cfg.resolve('file.dbpasswd_txt') -Destination "$dctmCfgPath\dbpasswd.txt"       
    New-Item -Path $dctmCfgPath -name dbpasswd.tmp.txt -itemtype "file" -value $cfg.resolve('docbase.pwd')   
    [iniFile]::WriteValue("$dctmCfgPath\server.ini", "SERVER_STARTUP", "database_password_file", "$dctmCfgPath\dbpasswd.tmp.txt")  

    # 2.3- updating service files
    # compute the max of all ports registered in the ${cfg.file.services} by reading all lines that do not start with # 
    # and that matches ${name}.+([0-9])+/tcp.*
    # adds at the end of the file 2 lines
    # ${cfg.docbase.service}    ${max}+1/tcp   # ${cfg.docbase.daemon.display}
    # ${cfg.docbase.service}_s  ${max}+2/tcp   # ${cfg.docbase.daemon.display} (secure)

    $etcServicesFile = $cfg.resolve('file.services')
    [uint16] $maxTcpPort = Get-MaxTcpPort  -Path $etcServicesFile
    if ($maxTcpPort -eq [uint16]::MaxValue-1)
    {
        throw "Max tcp port number already used in services file"
    }
    add-Content -Path $etcServicesFile -Value "$($cfg.resolve('docbase.service'))    $($maxTcpPort + 1)/tcp   # $($cfg.resolve('docbase.daemon.display'))"
    add-Content -Path $etcServicesFile -Value "$($cfg.resolve('docbase.service'))_s  $($maxTcpPort + 2)/tcp   # $($cfg.resolve('docbase.daemon.display')) (secure)"

    # 2.4- creating service
    # create a service 
    # sc create ${cfg.docbase.daemon.name} binPath= "${cfg.docbase.daemon.cmd}" obj="${cfg.user.domain}\${cfg.user.name}" DisplayName= "${cfg.docbase.daemon.display}" password= "${cfg.user.pwd}"
    New-DocbaseService $cfg.ToDocbaseService()


    # 2.5- updating the list of installed docbase
    # in the file ${cfg.env.documentum}\dba, there MUST be an .INI file named 'dm_documentum_config.ini'
    # we ensure a section [DOCBASE_${cfg.docbase.name}] exists and contains following entries:
    # NAME=${cfg.docbase.name}
    # VERSION=${cfg.docbase.previous.version}
    # DATABASE_CONN=${cfg.docbase.dsn}
    # DATABASE_NAME=${cfg.docbase.database}
    # If section does not exist or any entry do not match, the file is updated.

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



 