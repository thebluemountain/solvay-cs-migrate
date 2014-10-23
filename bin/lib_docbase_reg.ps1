function Write-DocbaseRegKey( $obj)
{
    if ($null -eq $obj)
    {
        throw "Argument obj cannot be null"
    }

    $dmp = _DumpObjAt $obj 
    Write-Verbose "Reg object=$dmp"

    if (test-path $obj.Path)
    {
        throw "The registry key $($obj.Path) already exists"
    }

    $out = New-Item -Path $obj.Path -type directory -force
    Write-Output "Reg key $out successfully created"
    foreach ($name in $obj.Keys)
    {
        $value = $obj.($name)
        $out = New-ItemProperty -Path $obj.Path -Name $name -PropertyType String -Value $value 
        Write-Output "Reg entry $name = $value successfully created"
    }    
}

function New-DocbaseService($obj)
{
    if ($null -eq $obj)
    {
       throw "Argument obj cannot be null"
    }

    $dmp = _DumpObjAt $obj
    Write-Verbose "Svc object dump=$dmp"
   
    if (Test-DocbaseService $obj.name)
    {
        throw "The docbase service $($obj.name) already exists"
    }   
    $out = New-Service -Name $obj.name -DisplayName $obj.display -StartupType Automatic -BinaryPathName $obj.commandLine -Credential $obj.credentials
    Write-Verbose $out
    Write-Output "Docbase service $($obj.name) successfully created."
}

function Test-DocbaseService($name)
{
    if ($null -eq $name)
    {
        throw "Argument obj cannot be null"
    }
    $out = Get-Service -Name $name -ErrorAction SilentlyContinue -ErrorVariable svcErr
    if ($svcErr)
    {
        return $false
    }
    return $true
   
}

