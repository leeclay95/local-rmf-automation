<#
.SYNOPSIS
    Run an Evaluate-STIG <ValidationCode> snippet the way Evaluate-STIG does, and
    report whether its return value is acceptable.
.DESCRIPTION
    Mirrors the wrapper in Master_Functions.psm1 -> Get-CorporateComment:
    $ErrorActionPreference = "Stop", the Evaluate-STIG variables in scope, the
    snippet compiled with [scriptblock]::Create() and invoked with &, then the
    same type test Evaluate-STIG applies to the result.

    Catches the quiet failures: stray pipeline output (return type becomes
    Object[]), no return at all ($null, which discards the whole answer), a
    non-boolean truthy value, and a hashtable missing Valid or Results.

    Stub values are deliberately plain. Override them to match the host you are
    writing the answer for.
.EXAMPLE
    pwsh -NoProfile -File test-validationcode.ps1 -CodeFile ./snippet.ps1
.EXAMPLE
    pwsh -NoProfile -File test-validationcode.ps1 -CodeFile ./snippet.ps1 `
        -ExpectedStatus Open -ResultData (Get-Content ./finding-details.txt)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][String]$CodeFile,
    [String]$ExpectedStatus = "Open",
    [String[]]$ResultData = @(),
    [String]$ResultHash = "0000000000000000000000000000000000000000",
    [String]$Hostname = [System.Net.Dns]::GetHostName(),
    [String]$Username = "",
    [String]$UserSID = "",
    [String]$Instance = "",
    [String]$Database = "",
    [String]$Site = "",
    [String[]]$ShowRun = @(),
    [String]$ESPath = ".",
    # Flatten $ResultData / $ShowRun into one space-joined string, the way
    # -UseSubProc mode does. Code that indexes the array breaks under this.
    [Switch]$SimulateSubProc
)

$ErrorActionPreference = "Stop"

if ($SimulateSubProc) {
    $ResultData = @("$($ResultData -replace '"', "'")")
    $ShowRun = @("$ShowRun")
}

$sb = [scriptblock]::Create((Get-Content -Raw -LiteralPath $CodeFile))
$Result = & $sb

if ($null -eq $Result) {
    Write-Host "FAIL  returned `$null" -ForegroundColor Red
    Write-Host "      GetType() throws, the outer catch nulls AnswerResults, and the"
    Write-Host "      answer file is not applied at all - not even the false branch."
    exit 1
}

$TypeName = $Result.GetType().Name

if ($TypeName -eq "Boolean") {
    Write-Host "OK    [Boolean] $Result" -ForegroundColor Green
    Write-Host "      Branch taken: $(if ($Result) { 'ValidTrue' } else { 'ValidFalse' })"
    exit 0
}

if ($TypeName -eq "Hashtable" -and $Result.ContainsKey("Valid") -and $Result.ContainsKey("Results")) {
    if ($Result.Valid -isnot [Boolean]) {
        Write-Host "WARN  Valid is [$($Result.Valid.GetType().Name)], not [Boolean]" -ForegroundColor Yellow
    }
    Write-Host "OK    [Hashtable] Valid=$($Result.Valid)" -ForegroundColor Green
    Write-Host "      Results: $($Result.Results)"
    Write-Host "      Branch taken: $(if ($Result.Valid -eq $true) { 'ValidTrue' } else { 'ValidFalse' })"
    if ($Result.Results -match "^ERROR:") {
        Write-Host "      NOTE: 'ERROR:' prefix - the wrapper's catch ran, or you set it yourself." -ForegroundColor Yellow
    }
    exit 0
}

Write-Host "FAIL  returned [$TypeName]" -ForegroundColor Red
Write-Host "      Evaluate-STIG logs 'Invalid ValidationCode object returned', leaves"
Write-Host "      `$Validated unset, and applies the ValidFalse branch."
if ($TypeName -eq "Object[]") {
    Write-Host "      Object[] almost always means stray pipeline output. Suppress every"
    Write-Host "      non-return statement with `$null = ... or | Out-Null." -ForegroundColor Yellow
    Write-Host "      Values emitted, in order:"
}
elseif ($TypeName -eq "Hashtable") {
    Write-Host "      Hashtable is missing 'Valid' and/or 'Results'. Keys present:" -ForegroundColor Yellow
    Write-Host "      $($Result.Keys -join ', ')"
}
$Result | Format-List | Out-String | Write-Host
exit 1
