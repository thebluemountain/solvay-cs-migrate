function _GetServlet ($xml)
{
 $servlet = $xml.SelectSingleNode('/web-app/servlet[servlet-name=''DoMethod'']')
 if ($null -eq $servlet)
 {
  throw 'cannot find servlet named ''DoMethod'''
 }
 return $servlet 
}

function _FindDocbase ($servlet, $name)
{
 $init = $servlet.SelectSingleNode('init-param[param-name=''docbase-' + $name + ''']')
 if ($null -ne $init)
 {
  # make sure it is ok
  $parval = $init.SelectSingleNode('param-value/text()')
  if ($null -eq $parval)
  {
   throw "found init-param element for docbase $name with no name"
  }
  $value = $parval.Value.Trim()
  if ($value -ne $name)
  {
   throw 'init-param element with name ''docbase-' + $name + ''' carries unexpected value: ''' + $value + ''''
  }
 }
 return $init
}

function _GetLastParam ($servlet)
{
 return $servlet.SelectSingleNode('init-param[last()]')
}

function _GetLoadOnStartup ($servlet)
{
 return $servlet.SelectSingleNode('load-on-startup')
}

function _checkLikeDocbase ([string] $str)
{
 return (($str.StartsWith('docbase-')) -and ('docbase-install-owner' -ne $str))
}

<#
 # the method that returns the JMS configuration matching a file path
 #>
function New-JmsConf ($path)
{
 $xml = new-object xml
 $xml.XmlResolver = $null
 $xml.Load($path)
 $obj = @{}
 $obj.path = $path
 $obj.xml = $xml
 $obj._changed = $false
 Add-Member -InputObject $obj -MemberType ScriptMethod -Name Register -Value {
   param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$name
   )
  .{
   $servlet = _GetServlet ($this.xml)
   $init = _FindDocbase -servlet $servlet -name $name
   if ($null -ne $init)
   {
    Write-Verbose "docbase $name already registered"
   }
   else
   {
    $init = $this.xml.CreateElement('init-param')
    $pname = $this.xml.CreateElement('param-name')
    $pname.InnerText = 'docbase-' + $name
    $init.AppendChild($pname) | Out-Null
    $pvalue = $this.xml.CreateElement('param-value')
    $pvalue.InnerText = $name
    $init.AppendChild($pvalue) | Out-Null
    $last = _GetLastParam $servlet
    if ($last)
    {
     $servlet.InsertAfter($init, $last) | Out-Null
     $this._changed = $true
    }
    else
    {
     $load = _GetLoadOnStartup $servlet
     if ($null -eq $load)
     {
      throw ('invalid XML file (' + $this.path + '): missing load-on-startup element in servlet for DoMethod')
     }
     $servlet.InsertBefore($init, $load) | Out-Null
     $this._changed = $true
    }
    write-verbose "registered docbase $name"
   }
  } @args
 }

 Add-Member -InputObject $obj -MemberType ScriptMethod -Name Unregister -Value {
   param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$name
   )
  .{
   $servlet = _GetServlet ($this.xml)
   $init = _FindDocbase -servlet $servlet -name $name
   if ($null -eq $init)
   {
    Write-Verbose "docbase $name not registered"
   }
   else
   {
    $servlet.RemoveChild($init) | Out-Null
    $this._changed = $true
    Write-Verbose "unregistered docbase $name"
   }
  } @args
 }

 Add-Member -InputObject $obj -MemberType ScriptProperty -Name Docbases -Value {
  .{
   $servlet = _GetServlet ($this.xml)
   $r = $servlet.SelectNodes('init-param')
   foreach ($elt in $r)
   {
    $name = $elt['param-name'].'#text'
    if (($name -ne 'docbase-install-owner-name') -and ($name.StartsWith('docbase-')))
    {
     $db = $elt['param-value'].'#text'
     if (('docbase-' + $db) -ne $name)
     {
      throw 'unexpected param-init element: expected it to match a docbase entry: ' + $elt
     }
     # adds to the output then ...
     $db
    }
   }
  }
 }
 Add-Member -InputObject $obj -MemberType ScriptMethod -Name Save -Value {
  .{
   if ($this.changed)
   {
    $this.xml.Save($this.path)
    $this._changed = $false
   }
  }
 }
 Add-Member -InputObject $obj -MemberType ScriptProperty -Name Changed -Value {
  .{
   return $this._changed
  }
 }
 return $obj
}

