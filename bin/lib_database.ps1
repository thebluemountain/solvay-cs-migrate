
<# ODBC/SQL related methods #>
<#
 the function that returns an opened connection to the database
 @cnxString: The connection string to the DB
 #>
function New-Connection ($cnxString)
{
    $cnx = new-object System.Data.Odbc.OdbcConnection
    $cnx.ConnectionString = $cnxString
    $cnx.Open()
    if ($cnx.State -ne [System.Data.ConnectionState]::Open)
    {
        throw 'can''t open database ' + $cnx.Database
    }
    return $cnx
}

<#
 the method that retrieves results matching the supplied SQL (select) query
 @returns: the first returned (data)table
 #>
function Select-Table ($cnx, $sql)
{
    $da = new-object System.Data.Odbc.OdbcDataAdapter $sql,$cnx
    try
    {
        $table = new-object System.Data.DataTable
        $da.Fill($table) | out-null
        # be carefull: it's considered as a collection ...
        # therefore returned as an array is not empty
        return ,$table
    }
    finally
    {
        $da.Dispose()
    }
}

<# 
    Executes an SQL statement against the Connection and returns the number of rows affected.
    For UPDATE, INSERT, and DELETE statements, the return value is the number of rows affected 
    by the command. For all other types of statements, the return value is -1.
#>
function Execute-SQL ($connection, $sql)
{       
   [System.Data.Odbc.OdbcConnection] $cnx = New-Connection $cnxString
    try
    {
        Write-Verbose "Executing SQL Statement: $sql"
        $command = $cnx.CreateCommand()
        $command.CommandText  = $sql
        $count = $command.ExecuteNonQuery()
        Write-Verbose "$count row(s) affected"
        return $count
    }
    finally
    {
        $cnx.Close()
    }
}
