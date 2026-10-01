# Turning raw command-line tokens into something that can be handed to a command.
#
# PowerShell cannot forward named parameters by splatting an array: `& $script
# @tokens` passes every element positionally, so "-Gpu" arrives as a string and
# is rejected. Hashtable splatting binds by name, so the tokens are bound here
# against the command's own parameter metadata.

$script:Common = [System.Management.Automation.PSCmdlet]::CommonParameters +
                 [System.Management.Automation.PSCmdlet]::OptionalCommonParameters

function Get-CommandOptions([string]$Path) {
    $params = (Get-Command -Name $Path).Parameters
    return @($params.Keys | Where-Object { $_ -notin $script:Common } | Sort-Object)
}

function Resolve-OptionName($Params, [string]$Name) {
    $exact = @($Params.Keys | Where-Object { $_ -ieq $Name })
    if ($exact.Count -eq 1) { return $exact[0] }
    $prefix = @($Params.Keys | Where-Object { $_ -ilike "$Name*" })
    if ($prefix.Count -eq 1) { return $prefix[0] }
    if ($prefix.Count -gt 1) {
        throw "Option '-$Name' is ambiguous: $(($prefix | Sort-Object) -join ', ')"
    }
    return $null
}

function Resolve-OptionKey([string]$Path, $Params, [string]$Name) {
    $key = Resolve-OptionName $Params $Name
    if ($key) { return $key }
    $known = Get-CommandOptions $Path
    throw ("Unknown option '-$Name'." + [Environment]::NewLine +
           "  known: $(($known | ForEach-Object { "-$_" }) -join ', ')")
}

function ConvertTo-SwitchValue([string]$Key, [string]$Text) {
    $parsed = $false
    if ([bool]::TryParse(($Text -replace '^\$', ''), [ref]$parsed)) { return $parsed }
    throw "Option '-$Key' is a switch, so it takes `$true or `$false -- got '$Text'."
}

# Returns @{ Named = <hashtable>; Positional = <object[]> }, ready to splat as
#   & $path @positional @named
function ConvertTo-CommandArguments([string]$Path, [object[]]$Tokens) {
    $params     = (Get-Command -Name $Path).Parameters
    $named      = @{}
    $positional = [System.Collections.ArrayList]::new()

    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $token = [string]$Tokens[$i]

        if ($token -notmatch '^-(?<name>[A-Za-z][A-Za-z0-9]*)(?::(?<value>.*))?$') {
            [void]$positional.Add($token)
            continue
        }

        $key      = Resolve-OptionKey $Path $params $Matches['name']
        $isSwitch = $params[$key].ParameterType -eq [switch]
        $inline   = if ($Matches.ContainsKey('value')) { $Matches['value'] } else { $null }

        # PowerShell splits `-Name:value` into `-Name:` and `value` before a
        # param-less dispatcher sees them, so a token ending in ':' carries its
        # value in the next token.
        if ($inline -eq '') {
            if ($i + 1 -ge $Tokens.Count) { throw "Option '-$key' needs a value after the colon." }
            $i++
            $inline = [string]$Tokens[$i]
        }

        if ($null -ne $inline) {
            $named[$key] = if ($isSwitch) { ConvertTo-SwitchValue $key $inline } else { $inline }
        } elseif ($isSwitch) {
            $named[$key] = $true
        } else {
            if ($i + 1 -ge $Tokens.Count) { throw "Option '-$key' needs a value." }
            $i++
            $named[$key] = [string]$Tokens[$i]
        }
    }

    return @{ Named = $named; Positional = $positional.ToArray() }
}

Export-ModuleMember -Function Get-CommandOptions, ConvertTo-CommandArguments
