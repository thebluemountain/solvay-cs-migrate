
<# ODBC/SQL related methods #>
<#
 the function that returns an opened connection to the database
 @dsn: identifies an ODBC data source's name
 @user: holds the name of the user to connect as
 @pwd: holds the password to use
 #>
function getConnect ($dsn, $user, $pwd)
{
 $cnx = new-object System.Data.Odbc.OdbcConnection
 $cnx.ConnectionString = 'dsn=' + $dsn + ';uid=' + $user + ';pwd=' + $pwd
 $cnx.Open()
 if ($cnx.State -ne [System.Data.ConnectionState]::Open)
 {
  throw 'can''t open database ' + $dsn
 }
 return $cnx
}

<#
 the method that retrieves results matching the supplied SQL (select) query
 @returns: the first returned (data)table
 #>
function selectTable ($cnx, $sql)
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