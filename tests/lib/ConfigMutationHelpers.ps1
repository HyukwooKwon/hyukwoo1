Set-StrictMode -Version Latest

function Get-ConfigAnchorPatternForPairTest {
    return '\bPairTest\s*=\s*@\{'
}

function Get-ConfigAnchorPatternForPairPolicy {
    param([Parameter(Mandatory)][string]$PairId)

    return ('\b{0}\s*=\s*@\{{' -f [regex]::Escape($PairId))
}

function Set-QuotedAssignmentAfterAnchor {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$AnchorPattern,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    $anchorMatch = [regex]::Match($Text, $AnchorPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $anchorMatch.Success) {
        throw ("Anchor not found. anchor={0}" -f $AnchorPattern)
    }

    return Set-QuotedAssignment -Text $Text -Name $Name -Value $Value -StartIndex $anchorMatch.Index
}

function Set-QuotedAssignment {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Value,
        [int]$StartIndex = 0
    )

    $nameIndex = $Text.IndexOf($Name, $StartIndex, [System.StringComparison]::Ordinal)
    if ($nameIndex -lt 0) {
        throw ("Quoted assignment not found. name={0}" -f $Name)
    }

    $equalsIndex = $Text.IndexOf('=', $nameIndex)
    $firstQuoteIndex = $Text.IndexOf("'", $equalsIndex)
    $secondQuoteIndex = $Text.IndexOf("'", ($firstQuoteIndex + 1))
    if ($equalsIndex -lt 0 -or $firstQuoteIndex -lt 0 -or $secondQuoteIndex -lt 0) {
        throw ("Quoted assignment is malformed. name={0}" -f $Name)
    }

    $escapedValue = $Value.Replace("'", "''")
    return ($Text.Substring(0, $firstQuoteIndex + 1) + $escapedValue + $Text.Substring($secondQuoteIndex))
}

function Set-BooleanAssignmentAfterAnchor {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$AnchorPattern,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Value
    )

    $anchorMatch = [regex]::Match($Text, $AnchorPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $anchorMatch.Success) {
        throw ("Anchor not found. anchor={0}" -f $AnchorPattern)
    }

    return Set-BooleanAssignment -Text $Text -Name $Name -Value $Value -StartIndex $anchorMatch.Index
}

function Set-BooleanAssignment {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Value,
        [int]$StartIndex = 0
    )

    $nameIndex = $Text.IndexOf($Name, $StartIndex, [System.StringComparison]::Ordinal)
    if ($nameIndex -lt 0) {
        throw ("Boolean assignment not found. name={0}" -f $Name)
    }

    $equalsIndex = $Text.IndexOf('=', $nameIndex)
    if ($equalsIndex -lt 0) {
        throw ("Boolean assignment is malformed. name={0}" -f $Name)
    }

    $valueTail = $Text.Substring($equalsIndex + 1)
    $valueMatch = [regex]::Match($valueTail, '^\s*\$(true|false)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $valueMatch.Success) {
        throw ("Boolean assignment is malformed. name={0}" -f $Name)
    }

    $boolLiteral = if ($Value) { '$true' } else { '$false' }
    $valueStart = $equalsIndex + 1 + $valueMatch.Index + ($valueMatch.Value.Length - $valueMatch.Groups[1].Value.Length - 1)
    $valueLength = $valueMatch.Groups[1].Value.Length + 1
    return ($Text.Substring(0, $valueStart) + $boolLiteral + $Text.Substring($valueStart + $valueLength))
}

function Set-QuotedPairTestAssignment {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    return Set-QuotedAssignmentAfterAnchor `
        -Text $Text `
        -AnchorPattern (Get-ConfigAnchorPatternForPairTest) `
        -Name $Name `
        -Value $Value
}

function Set-BooleanPairTestAssignment {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Value
    )

    return Set-BooleanAssignmentAfterAnchor `
        -Text $Text `
        -AnchorPattern (Get-ConfigAnchorPatternForPairTest) `
        -Name $Name `
        -Value $Value
}

function Set-QuotedPairPolicyAssignment {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    return Set-QuotedAssignmentAfterAnchor `
        -Text $Text `
        -AnchorPattern (Get-ConfigAnchorPatternForPairPolicy -PairId $PairId) `
        -Name $Name `
        -Value $Value
}

function Set-BooleanPairPolicyAssignment {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Value
    )

    return Set-BooleanAssignmentAfterAnchor `
        -Text $Text `
        -AnchorPattern (Get-ConfigAnchorPatternForPairPolicy -PairId $PairId) `
        -Name $Name `
        -Value $Value
}
