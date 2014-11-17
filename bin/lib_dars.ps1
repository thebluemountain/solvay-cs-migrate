<#
 # the method that creates a dar object
 # $conf: the map containing all configuration variables
 # $name: the name of the collection holding the dars to install
 #>
function BuildDars ($conf, $name)
{
 $obj = createObj
 $obj.conf = $conf
 $obj.name = $name
 Add-Member -InputObject $obj -MemberType ScriptMethod -Name Dars -Value {
 .{
   $dars = [System.Collections.ArrayList]@()
   # dar names are located in: conf.resolve('docbase.dars.sets.' + $this.name)
   # as a comma-separated collection of dar name
   $all = $this.conf.resolve('docbase.upgrade.dars.sets.' + $this.name)
   foreach ($name in $all.Split(','))
   {
    $dar = $this.conf.resolve('docbase.upgrade.dars.' + $name)
    $dar.name = $name
    if ($null -eq $dar)
    {
     throw 'dar config ''' + $this.name + ''' contains reference to unknown dar: ''' + $name + ''''
    }
    $dars.Add($dar) | Out-Null
   }
   return $dars
  }
 }
 Add-Member -InputObject $obj -MemberType ScriptMethod -Name Install -Value {
  .{
    # intermediate: the dars to get file names of
    $dars = $this.Dars()
    if (0 -eq $dars.length)
    {
     # don't go any further
     Log-Info 'there is no DAR to install for step ''' + $this.name + ''''
     return
    }

    $files = ''
    foreach ($dar in $dars)
    {
     if (0 -lt $files.Length)
     {
      $files += ','
     }
     $file = $this.conf.resolve('docbase.upgrade.dars.' + $dar.name + '.file')
     $files += $file
    }

    # prepares the dfc.properties stuff
    $dfc = createObj
    $from = $this.conf.resolve('docbase.tools.dfc')
    LoadFlatPropertiesFile $dfc $from

    # update the properties then
    $dfc.('dfc.session.pool.enable') = 'false'
    # was also changing dfc.cache.dir to the path of a new tmp directory
    $to = $this.conf.resolve('docbase.tools.composer.headless') + 
     '\plugins\com.emc.ide.external.dfc_1.0.0\documentum.config\dfc.properties'
    SaveFlatPropertiesFile $dfc $to
    Log-Verbose ('updated ' + $to + ' from ' + $from)
    # TODO: is the docbroker change required ?
    # but in that case, how about global registry ?

    # builds the command-line composed of: program & arguments
    # 1st the program
    $program = $this.conf.resolve('env.JAVA_HOME') + '\bin\java.exe'

    $dilog = $this.conf.resolve('docbase.daemon.dir') + '\dars_status.log'

    $params = [System.Collections.ArrayList]@()
    $params.Add('-Dant_extended_lib_dir=' + $this.conf.resolve('docbase.tools.composer.dir')) | Out-Null
    $params.Add('-Ddars=' + $files) | Out-Null
    $params.Add('-Dlogpath=' + $this.conf.resolve('docbase.daemon.dir') + '\dars.log') | Out-Null
    $params.Add('-Ddi_log="' + $dilog + '"') | Out-Null
    $params.Add('-Ddocbase=' + $this.conf.resolve('docbase.name') + '.' + $this.conf.resolve('docbase.config')) | Out-Null
    $params.Add('-Duser=' + $this.conf.resolve('env.USERNAME')) | Out-Null
    $params.Add('-Ddomain=' + $this.conf.resolve('env.USERDOMAIN')) | Out-Null
    $params.Add('-cp') | Out-Null
    $params.Add($this.conf.resolve('docbase.tools.composer.headless') + '\startup.jar') | Out-Null
    $params.Add('org.eclipse.core.launcher.Main') | Out-Null
    $params.Add('-data') | Out-Null
    $params.Add($this.conf.resolve('docbase.tools.composer.workspace')) | Out-Null
    $params.Add('-application') | Out-Null
    $params.Add('org.eclipse.ant.core.antRunner') | Out-Null
    $params.Add('-buildfile') | Out-Null
    $params.Add($this.conf.resolve('docbase.tools.composer.dir') + '\deploy.xml') | Out-Null
    $params.Add('deployAll') | Out-Null
    Log-Verbose ('about to run dar installation for ' + $this.name)
    Log-Verbose $program
    Log-Verbose $params
    log-info ('about to install ' + $dars.length + ' DARS of step ' + $this.name + '. this may take a while')
    $res = & $program $params 2>&1

    # OK, should now have the dilog file: tests if there are any error
    $errs = get-content -literalpath $dilog | select-string -pattern '^DI_ERROR: Installation of ''(.+)'' DAR failed\. See ''(.+)'' for details\.'
    if ($null -ne $errs)
    {
     foreach ($err in $errs)
     {
      Log-Error $err.line 
     }
     throw ('error occured attempting to load dars in step ''' + $this.name + ''': see file ' + $dilog)
    }
    $msg = 'installed ' + $dars.length + ' DARS of step ' + $this.name
    log-info $msg
  }
 }

 return $obj
}

<#
 # sample program accessing the config to run dar installation
cls
if ($null -eq $PSScriptRoot)
{
    $PSScriptRoot = (Split-Path $MyInvocation.MyCommand.Path -Parent)
}
# ok, includes our conf
. "$PSScriptRoot\lib_config.ps1"

$conf = Initialize 'f:\migrate\Configs\SAMPLE'
#$conf.Dump()
$conf.docbase.dars.sets.main='smartcontainer,webtop'

$darsbuilder = BuildDars $conf 'main'
$darsbuilder.Install()
write 'done'
#>
