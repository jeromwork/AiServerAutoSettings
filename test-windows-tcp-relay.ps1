# Test-only loopback relay for the WSL fixture. Not shipped as a runtime dependency.
param([Parameter(Mandatory=$true)][ValidateRange(1024,65535)][int]$Port)
$ErrorActionPreference='Stop'
$client=New-Object Net.Sockets.TcpClient
try {
    $payload=[Console]::ReadLine()
    if(-not $payload -or $payload.Length -gt 262144){throw 'Invalid fixture frame'}
    $client.Connect('127.0.0.1',$Port)
    $stream=$client.GetStream();$stream.ReadTimeout=35000
    $bytes=[Text.Encoding]::UTF8.GetBytes($payload+"`n")
    $stream.Write($bytes,0,$bytes.Length)
    $reader=New-Object IO.StreamReader $stream,([Text.Encoding]::UTF8)
    [Console]::WriteLine($reader.ReadLine())
}finally{$client.Close()}
