[CmdletBinding()]
param(
    [string] $RepositoryRoot = (
        Resolve-Path ([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
    ).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validator = Join-Path $PSScriptRoot 'validate-action-contracts.ps1'
$lockPath = [System.IO.Path]::Combine(
    $PSScriptRoot,
    '..',
    'actions-lock.json'
)
$workflowPath = [System.IO.Path]::Combine(
    $RepositoryRoot,
    '.github',
    'workflows',
    'build.yml'
)
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$temporaryRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) "mingw-action-contract-tests-$([guid]::NewGuid())"
$fixtureWorkflowDirectory = [System.IO.Path]::Combine(
    $temporaryRoot,
    '.github',
    'workflows'
)
$fixturePath = Join-Path $fixtureWorkflowDirectory 'build.yml'
$extraFixturePath = Join-Path $fixtureWorkflowDirectory 'extra.yml'
$fixtureLockPath = Join-Path $temporaryRoot 'actions-lock.json'
$baseWorkflow = Get-Content -LiteralPath $workflowPath -Raw
$baseLock = Get-Content -LiteralPath $lockPath -Raw
$passed = 0

function Invoke-Validator {
    param([string] $TestLock)

    $output = & $pwsh `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -File $validator `
        -RepositoryRoot $temporaryRoot `
        -LockPath $TestLock `
        -Quiet 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    return [pscustomobject] @{
        ExitCode = $exitCode
        Output = $output
    }
}

function Write-Fixture {
    param([string] $Content)

    Get-ChildItem -LiteralPath $fixtureWorkflowDirectory -File |
        Where-Object { $_.Extension -in @('.yml', '.yaml') } |
        Remove-Item -Force
    Set-Content -LiteralPath $fixturePath -Value $Content -Encoding utf8 -NoNewline
}

function Assert-Pass {
    param(
        [string] $Name,
        [string] $Workflow,
        [string] $Lock = $lockPath
    )

    Write-Fixture $Workflow
    $result = Invoke-Validator $Lock

    if ($result.ExitCode -ne 0) {
        throw "Expected '$Name' to pass, exit=$($result.ExitCode):`n$($result.Output)"
    }

    $script:passed++
    Write-Output "PASS $Name"
}

function Assert-Failure {
    param(
        [string] $Name,
        [string] $Workflow,
        [string] $ExpectedMessage,
        [string] $Lock = $lockPath
    )

    Write-Fixture $Workflow
    $result = Invoke-Validator $Lock

    if ($result.ExitCode -eq 0) {
        throw "Expected '$Name' to fail"
    }

    if ($result.Output -cnotmatch [regex]::Escape($ExpectedMessage)) {
        throw (
            "Expected '$Name' output to contain '$ExpectedMessage':`n" +
            $result.Output
        )
    }

    $script:passed++
    Write-Output "PASS $Name"
}

function Replace-First {
    param(
        [string] $Text,
        [string] $OldValue,
        [string] $NewValue
    )

    $pattern = [regex]::new([regex]::Escape($OldValue))
    if (-not $pattern.IsMatch($Text)) {
        throw "Fixture source does not contain '$OldValue'"
    }

    return $pattern.Replace($Text, $NewValue, 1)
}

function Add-FirstActionInput {
    param(
        [string] $Text,
        [string] $Uses,
        [string] $InputName
    )

    $pattern = [regex]::new(
        "(?m)^([ \t]*)(?:-[ \t]+)?uses:[ \t]+$([regex]::Escape($Uses))[ \t]*(\r?\n)" +
        '([ \t]*)with:[ \t]*(\r?\n)'
    )

    if (-not $pattern.IsMatch($Text)) {
        throw "Fixture source has no with block for '$Uses'"
    }

    return $pattern.Replace(
        $Text,
        {
            param($match)

            return (
                $match.Value +
                $match.Groups[3].Value +
                "  $InputName`: true" +
                $match.Groups[4].Value
            )
        },
        1
    )
}

function Add-FirstActionOutputReference {
    param(
        [string] $Text,
        [string] $Uses,
        [string] $Expression
    )

    $pattern = [regex]::new(
        "(?m)^([ \t]*)(-[ \t]+)?uses:[ \t]+$([regex]::Escape($Uses))[ \t]*(\r?\n)"
    )

    if (-not $pattern.IsMatch($Text)) {
        throw "Fixture source has no use of '$Uses'"
    }

    return $pattern.Replace(
        $Text,
        {
            param($match)

            $indent = $match.Groups[1].Value
            $propertyIndent = if ($match.Groups[2].Success) {
                "$indent  "
            }
            else {
                $indent
            }
            $newline = $match.Groups[3].Value
            return (
                $match.Value +
                "${propertyIndent}id: locked-action$newline" +
                "${propertyIndent}if: $Expression$newline"
            )
        },
        1
    )
}

New-Item -ItemType Directory -Path $fixtureWorkflowDirectory | Out-Null

try {
    $checkout = 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262'
    $download = 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
    $upload = 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'
    $newline = if ($baseWorkflow.Contains("`r`n")) { "`r`n" } else { "`n" }

    Assert-Pass 'locked workflow contract' $baseWorkflow

    Assert-Pass `
        'case-insensitive action output context' `
        (Replace-First `
            $baseWorkflow `
            'steps.cache-gnu.outputs.cache-hit' `
            'STEPS.CACHE-GNU.OUTPUTS.CACHE-HIT')

    $inertOutputText = Replace-First `
        $baseWorkflow `
        'sudo apt-get update && sudo apt-get install autoconf automake' `
        (
            'sudo apt-get update && sudo apt-get install autoconf automake' +
            $newline +
            '          echo steps.cache-gnu.outputs.cache-hit'
        )
    Assert-Pass 'inert script output-like text' $inertOutputText

    Assert-Failure `
        'mutable action reference' `
        (Replace-First $baseWorkflow $checkout 'actions/checkout@v4') `
        "uses 'v4' instead of locked pin"

    Assert-Failure `
        'wrong immutable action reference' `
        (Replace-First $baseWorkflow $checkout 'actions/checkout@0000000000000000000000000000000000000000') `
        "uses '0000000000000000000000000000000000000000' instead of locked pin"

    Assert-Failure `
        'download v8 skip-decompress input' `
        (Add-FirstActionInput $baseWorkflow $download 'skip-decompress') `
        "uses newer-only actions/download-artifact input 'skip-decompress'"

    Assert-Failure `
        'download v8 digest-mismatch input' `
        (Add-FirstActionInput $baseWorkflow $download 'digest-mismatch') `
        "uses newer-only actions/download-artifact input 'digest-mismatch'"

    Assert-Failure `
        'future checkout input' `
        (Add-FirstActionInput $baseWorkflow $checkout 'future-checkout-mode') `
        "uses unsupported actions/checkout input 'future-checkout-mode'"

    Assert-Failure `
        'future upload input' `
        (Add-FirstActionInput $baseWorkflow $upload 'future-upload-mode') `
        "uses unsupported actions/upload-artifact input 'future-upload-mode'"

    Assert-Failure `
        'unsupported download output' `
        (Add-FirstActionOutputReference `
            $baseWorkflow `
            $download `
            '${{ steps.locked-action.outputs.artifact-digest }}') `
        "uses unsupported actions/download-artifact output 'artifact-digest'"

    Assert-Failure `
        'unsupported bracketed download output' `
        (Add-FirstActionOutputReference `
            $baseWorkflow `
            $download `
            '${{ steps[''locked-action''][''outputs''][''digest-mismatch''] }}') `
        "uses unsupported actions/download-artifact output 'digest-mismatch'"

    Assert-Failure `
        'unsupported checkout output' `
        (Add-FirstActionOutputReference `
            $baseWorkflow `
            $checkout `
            '${{ steps.locked-action.outputs.future-checkout-output }}') `
        "uses unsupported actions/checkout output 'future-checkout-output'"

    Assert-Failure `
        'unsupported upload output' `
        (Add-FirstActionOutputReference `
            $baseWorkflow `
            $upload `
            '${{ steps.locked-action.outputs.future-upload-output }}') `
        "uses unsupported actions/upload-artifact output 'future-upload-output'"

    Assert-Failure `
        'serialized action step output bypass' `
        (Add-FirstActionOutputReference `
            $baseWorkflow `
            $download `
            '${{ toJSON(steps.locked-action) }}') `
        "serializes action step 'locked-action' and bypasses output locking"

    Assert-Failure `
        'serialized complete steps context' `
        (Add-FirstActionOutputReference `
            $baseWorkflow `
            $download `
            '${{ toJSON(steps) }}') `
        'serializes the complete steps context'

    Assert-Failure `
        'unlocked delegated action' `
        (Replace-First `
            $baseWorkflow `
            $checkout `
            'example/delegated-action@11d5960a326750d5838078e36cf38b85af677262') `
        "uses unlocked action 'example/delegated-action'"

    $delegatedJob = Replace-First `
        $baseWorkflow `
        "jobs:$newline" `
        (
            "jobs:$newline" +
            "  delegated-policy-bypass:$newline" +
            '    uses: example/repository/.github/workflows/build.yml@1111111111111111111111111111111111111111' +
            $newline
        )
    Assert-Failure `
        'delegated reusable workflow' `
        $delegatedJob `
        "uses a delegated/reusable workflow"

    Write-Fixture $baseWorkflow
    @"
name: Hidden workflow bypass
on: push
jobs:
  bypass:
    runs-on: ubuntu-latest
    steps:
      - uses: example/hidden-action@1111111111111111111111111111111111111111
"@ | Set-Content -LiteralPath $extraFixturePath -Encoding utf8
    $discoveryResult = Invoke-Validator $lockPath
    if (
        $discoveryResult.ExitCode -eq 0 -or
        $discoveryResult.Output -cnotmatch [regex]::Escape(
            "uses unlocked action 'example/hidden-action'"
        )
    ) {
        throw (
            "Expected complete workflow discovery to reject extra.yml:`n" +
            $discoveryResult.Output
        )
    }
    $passed++
    Write-Output 'PASS complete workflow discovery'

    $pinLock = $baseLock |
        ConvertFrom-Json -AsHashtable
    $checkoutLock = @(
        $pinLock['actions'] |
            Where-Object { $_['repository'] -ceq 'actions/checkout' }
    )[0]
    $checkoutLock['pin'] = '0000000000000000000000000000000000000000'
    $pinLock |
        ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $fixtureLockPath -Encoding utf8
    Assert-Failure `
        'campaign pin lock tampering' `
        $baseWorkflow `
        "does not match campaign pin '11d5960a326750d5838078e36cf38b85af677262'" `
        $fixtureLockPath

    $usageLock = $baseLock |
        ConvertFrom-Json -AsHashtable
    $checkoutUsageLock = @(
        $usageLock['actions'] |
            Where-Object { $_['repository'] -ceq 'actions/checkout' }
    )[0]
    $checkoutUsageLock['workflowUsage']['inputs'] = @('ref', 'repository')
    $usageLock |
        ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $fixtureLockPath -Encoding utf8
    Assert-Failure `
        'consumed contract lock drift' `
        $baseWorkflow `
        'actions/checkout consumed inputs changed' `
        $fixtureLockPath

    $coordinatedLock = $baseLock |
        ConvertFrom-Json -AsHashtable
    $downloadLock = @(
        $coordinatedLock['actions'] |
            Where-Object { $_['repository'] -ceq 'actions/download-artifact' }
    )[0]
    $downloadLock['contract']['inputs'] = @(
        $downloadLock['contract']['inputs']
    ) + 'skip-decompress'
    $downloadLock['workflowUsage']['inputs'] = @('name', 'skip-decompress')
    $downloadLock['knownNewerOnlyInputs'] = @('digest-mismatch')
    $coordinatedLock |
        ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $fixtureLockPath -Encoding utf8
    Assert-Failure `
        'coordinated workflow and contract lock tampering' `
        (Add-FirstActionInput $baseWorkflow $download 'skip-decompress') `
        'actions/download-artifact lock record does not match its reviewed immutable contract' `
        $fixtureLockPath

    $equivalenceLock = $baseLock |
        ConvertFrom-Json -AsHashtable
    $equivalenceLock['policy']['replacedMajorImplementationsByteEquivalent'] = $true
    $equivalenceLock |
        ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $fixtureLockPath -Encoding utf8
    Assert-Failure `
        'false behavior equivalence policy' `
        $baseWorkflow `
        'the lock must record that replaced major implementations are not byte-equivalent' `
        $fixtureLockPath

    $unsignedLock = $baseLock |
        ConvertFrom-Json -AsHashtable
    $setupLock = @(
        $unsignedLock['actions'] |
            Where-Object { $_['repository'] -ceq 'msys2/setup-msys2' }
    )[0]
    $setupLock['provenance']['verification'] = 'verified'
    $unsignedLock |
        ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $fixtureLockPath -Encoding utf8
    Assert-Failure `
        'missing setup-msys2 unsigned exception' `
        $baseWorkflow `
        'msys2/setup-msys2 must be recorded as the sole unsigned exception' `
        $fixtureLockPath

    Write-Output "All $passed action contract tests passed."
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
