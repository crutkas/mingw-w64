[CmdletBinding()]
param(
    [string] $RepositoryRoot = (
        Resolve-Path ([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
    ).Path,
    [string] $LockPath = (
        [System.IO.Path]::Combine($PSScriptRoot, '..', 'actions-lock.json')
    ),
    [switch] $Quiet,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([string] $Message)

    $failures.Add($Message)
}

function Test-MapKey {
    param(
        [object] $Map,
        [string] $Key
    )

    return $Map -is [System.Collections.IDictionary] -and $Map.Contains($Key)
}

function Get-ExpressionScalars {
    param(
        [object] $Value,
        [string] $ParentKey = ''
    )

    if ($null -eq $Value) {
        return
    }

    if ($Value -is [string]) {
        [pscustomobject] @{
            Value = $Value
            IsImplicitExpression = $ParentKey -ceq 'if'
        }
        return
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            Get-ExpressionScalars $Value[$key] ([string] $key)
        }
        return
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            Get-ExpressionScalars $item $ParentKey
        }
    }
}

function Get-CanonicalDigest {
    param([object] $Value)

    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
}

function New-OrdinalSet {
    return ,([System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    ))
}

function Format-Set {
    param([System.Collections.Generic.HashSet[string]] $Set)

    return (@($Set) | Sort-Object) -join ', '
}

$yamlModule = Get-Module -ListAvailable -Name powershell-yaml |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($null -eq $yamlModule) {
    [Console]::Error.WriteLine(
        'ERROR: powershell-yaml is required for semantic workflow parsing; this validator never installs dependencies.'
    )
    exit 1
}

Import-Module $yamlModule.Path

$lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json -AsHashtable
$minimumParserVersion = [version] $lock['policy']['yamlParser']['minimumVersion']

if ($yamlModule.Version -lt $minimumParserVersion) {
    Add-Failure "powershell-yaml $($yamlModule.Version) is older than locked minimum $minimumParserVersion"
}

if ([int] $lock['schemaVersion'] -ne 1) {
    Add-Failure "unsupported action lock schema version '$($lock['schemaVersion'])'"
}

if ($lock['policy']['replacedMajorImplementationsByteEquivalent'] -ne $false) {
    Add-Failure 'the lock must record that replaced major implementations are not byte-equivalent'
}

$expectedPolicyDigest = '12be306f9b0736d47bdd04d673e1a57a84273365600b56143e3de047be5a66fc'
if ((Get-CanonicalDigest $lock['policy']) -cne $expectedPolicyDigest) {
    Add-Failure 'action lock policy does not match the reviewed campaign policy'
}

$actionLocks = [System.Collections.Generic.Dictionary[string, object]]::new(
    [System.StringComparer]::Ordinal
)
$observed = [System.Collections.Generic.Dictionary[string, object]]::new(
    [System.StringComparer]::Ordinal
)
$campaignPins = [System.Collections.Generic.Dictionary[string, string]]::new(
    [System.StringComparer]::Ordinal
)
$campaignPins.Add(
    'actions/checkout',
    '11d5960a326750d5838078e36cf38b85af677262'
)
$campaignPins.Add(
    'msys2/setup-msys2',
    '66cd2cce69caa17b53920067426061ca1de3a884'
)
$campaignPins.Add(
    'actions/upload-artifact',
    'ea165f8d65b6e75b540449e92b4886f43607fa02'
)
$campaignPins.Add(
    'actions/download-artifact',
    'd3f86a106a0bac45b974a628896c90dbdf5c8093'
)
$campaignPins.Add(
    'actions/cache',
    'caa296126883cff596d87d8935842f9db880ef25'
)
$expectedActionDigests = [System.Collections.Generic.Dictionary[string, string]]::new(
    [System.StringComparer]::Ordinal
)
$expectedActionDigests.Add(
    'actions/checkout',
    '0641d6f3b9c03e4a8edae3965d96d40c2a1bbd5c6ac8f2c049cafa8917c431cc'
)
$expectedActionDigests.Add(
    'msys2/setup-msys2',
    'bc709f6560589ad5f60cba0998236914860126491f6658aeadf51e5bc99bbcdc'
)
$expectedActionDigests.Add(
    'actions/upload-artifact',
    '0758233baee27e5fcf4d9635c6de1723925d91583a2622f00e3323211c797bf7'
)
$expectedActionDigests.Add(
    'actions/download-artifact',
    '7526998e4c9ee6f8975eff62499165aa27eabf0e521c0568c50e7d8d0092ed8b'
)
$expectedActionDigests.Add(
    'actions/cache',
    '9126f6092331ba18b677a632ee3e615180686a029d94cea9f645d22f5b1a370b'
)

foreach ($action in @($lock['actions'])) {
    $repository = [string] $action['repository']

    if ($actionLocks.ContainsKey($repository)) {
        Add-Failure "duplicate action lock entry '$repository'"
        continue
    }

    $actionLocks.Add($repository, $action)
    $observed.Add($repository, [pscustomobject] @{
        Count = 0
        Inputs = New-OrdinalSet
        OutputReferences = [System.Collections.Generic.Dictionary[string, int]]::new(
            [System.StringComparer]::Ordinal
        )
        OutputOccurrences = [System.Collections.Generic.List[string]]::new()
        Occurrences = [System.Collections.Generic.List[string]]::new()
    })

    if ([string] $action['pin'] -cnotmatch '^[0-9a-f]{40}$') {
        Add-Failure "$repository has a non-immutable pin '$($action['pin'])'"
    }

    if (-not $campaignPins.ContainsKey($repository)) {
        Add-Failure "$repository is not part of the action pin campaign"
    }
    elseif ([string] $action['pin'] -cne $campaignPins[$repository]) {
        Add-Failure (
            "$repository lock pin '$($action['pin'])' does not match campaign pin " +
            "'$($campaignPins[$repository])'"
        )
    }

    if (
        -not $expectedActionDigests.ContainsKey($repository) -or
        (Get-CanonicalDigest $action) -cne $expectedActionDigests[$repository]
    ) {
        Add-Failure "$repository lock record does not match its reviewed immutable contract"
    }

    if ([string] $action['provenance']['tree'] -cnotmatch '^[0-9a-f]{40}$') {
        Add-Failure "$repository has an invalid commit tree identity"
    }

    $verification = [string] $action['provenance']['verification']
    if ($repository -ceq 'msys2/setup-msys2') {
        if ($verification -cne 'unsigned-exception') {
            Add-Failure 'msys2/setup-msys2 must be recorded as the sole unsigned exception'
        }
    }
    elseif ($verification -cne 'verified') {
        Add-Failure "$repository must have verified commit provenance"
    }

    $manifest = $action['contract']['manifest']
    if (
        [string] $manifest['path'] -cne 'action.yml' -or
        [string] $manifest['blob'] -cnotmatch '^[0-9a-f]{40}$' -or
        [int64] $manifest['size'] -le 0
    ) {
        Add-Failure "$repository has an invalid action.yml identity"
    }

    if ([string] $action['contract']['runtime'] -cnotmatch '^node[0-9]+$') {
        Add-Failure "$repository has an unsupported locked runtime '$($action['contract']['runtime'])'"
    }

    $entrypoints = $action['contract']['entrypoints']
    if (-not (Test-MapKey $entrypoints 'main')) {
        Add-Failure "$repository has no locked main entrypoint"
    }

    foreach ($role in @('main', 'post')) {
        if (-not (Test-MapKey $entrypoints $role)) {
            continue
        }

        $entrypoint = $entrypoints[$role]
        if (
            [string]::IsNullOrWhiteSpace([string] $entrypoint['path']) -or
            [string] $entrypoint['blob'] -cnotmatch '^[0-9a-f]{40}$' -or
            [int64] $entrypoint['size'] -le 0
        ) {
            Add-Failure "$repository has an invalid $role entrypoint identity"
        }
    }

    $contractInputs = New-OrdinalSet
    foreach ($inputName in @($action['contract']['inputs'])) {
        if (-not $contractInputs.Add([string] $inputName)) {
            Add-Failure "$repository repeats contract input '$inputName'"
        }
    }

    $contractOutputs = New-OrdinalSet
    foreach ($outputName in @($action['contract']['outputs'])) {
        if (-not $contractOutputs.Add([string] $outputName)) {
            Add-Failure "$repository repeats contract output '$outputName'"
        }
    }

    foreach ($inputName in @($action['knownNewerOnlyInputs'])) {
        if ($contractInputs.Contains([string] $inputName)) {
            Add-Failure "$repository newer-only input '$inputName' is incorrectly allowed by the pinned contract"
        }
    }

    foreach ($inputName in @($action['workflowUsage']['inputs'])) {
        if (-not $contractInputs.Contains([string] $inputName)) {
            Add-Failure "$repository locks consumed input '$inputName' outside its pinned contract"
        }
    }

    foreach ($outputName in @($action['workflowUsage']['outputReferences'].Keys)) {
        if (
            -not $contractOutputs.Contains([string] $outputName) -or
            [int] $action['workflowUsage']['outputReferences'][$outputName] -le 0
        ) {
            Add-Failure "$repository has an invalid locked output reference '$outputName'"
        }
    }
}

foreach ($repository in $campaignPins.Keys) {
    if (-not $actionLocks.ContainsKey($repository)) {
        Add-Failure "campaign action '$repository' is missing from the lock"
    }
}

$workflowDirectory = [System.IO.Path]::Combine(
    $RepositoryRoot,
    '.github',
    'workflows'
)
$workflowPaths = @(
    Get-ChildItem -LiteralPath $workflowDirectory -File |
        Where-Object { $_.Extension -in @('.yml', '.yaml') } |
        Sort-Object FullName |
        ForEach-Object { $_.FullName }
)

if ($workflowPaths.Count -eq 0) {
    Add-Failure 'no workflow files were found'
}

$delimitedExpressionPattern = [regex]::new(
    '\$\{\{(.*?)\}\}',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
$outputDependencyPattern = [regex]::new(
    'steps\s*(?:\.\s*([A-Za-z_][A-Za-z0-9_-]*)|\[\s*[''"]([^''"]+)[''"]\s*\])' +
    '\s*(?:\.\s*outputs|\[\s*[''"]outputs[''"]\s*\])' +
    '\s*(?:\.\s*([A-Za-z_][A-Za-z0-9_-]*)|\[\s*[''"]([^''"]+)[''"]\s*\])',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
$serializedStepPattern = [regex]::new(
    '\btoJSON\s*\(\s*steps\s*' +
    '(?:(?:\.\s*([A-Za-z_][A-Za-z0-9_-]*))|\[\s*[''"]([^''"]+)[''"]\s*\])?\s*\)',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
$outputTokenPattern = [regex]::new(
    'steps\s*(?:\.\s*[A-Za-z_][A-Za-z0-9_-]*|\[[^\]]+\])' +
    '\s*(?:\.\s*outputs|\[\s*[''"]outputs[''"]\s*\])',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

foreach ($workflowPath in $workflowPaths) {
    $resolvedWorkflowPath = (Resolve-Path -LiteralPath $workflowPath).Path
    $relativePath = [System.IO.Path]::GetRelativePath(
        $RepositoryRoot,
        $resolvedWorkflowPath
    ) -replace '\\', '/'

    try {
        $workflow = ConvertFrom-Yaml -Yaml (
            Get-Content -LiteralPath $resolvedWorkflowPath -Raw
        ) -Ordered
    }
    catch {
        Add-Failure "$relativePath failed YAML parsing: $($_.Exception.Message)"
        continue
    }

    if (-not (Test-MapKey $workflow 'jobs')) {
        Add-Failure "$relativePath has no jobs mapping"
        continue
    }

    foreach ($jobName in $workflow['jobs'].Keys) {
        $job = $workflow['jobs'][$jobName]

        if (Test-MapKey $job 'uses') {
            Add-Failure "$relativePath job '$jobName' uses a delegated/reusable workflow"
        }

        $steps = @()
        if (Test-MapKey $job 'steps') {
            $steps = @($job['steps'])
        }
        $stepsById = [System.Collections.Generic.Dictionary[string, object]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        for ($stepIndex = 0; $stepIndex -lt $steps.Count; $stepIndex++) {
            $step = $steps[$stepIndex]
            $displayIndex = $stepIndex + 1

            if ($step -isnot [System.Collections.IDictionary]) {
                Add-Failure "$relativePath job '$jobName' step $displayIndex is not a mapping"
                continue
            }

            $stepRecord = [pscustomobject] @{
                Action = $null
                Index = $displayIndex
            }

            if (Test-MapKey $step 'id') {
                $stepId = [string] $step['id']
                if ([string]::IsNullOrWhiteSpace($stepId)) {
                    Add-Failure "$relativePath job '$jobName' step $displayIndex has an empty id"
                }
                elseif ($stepsById.ContainsKey($stepId)) {
                    Add-Failure "$relativePath job '$jobName' repeats step id '$stepId'"
                }
                else {
                    $stepsById.Add($stepId, $stepRecord)
                }
            }

            if (-not (Test-MapKey $step 'uses')) {
                continue
            }

            if ($step['uses'] -isnot [string]) {
                Add-Failure "$relativePath job '$jobName' step $displayIndex has a non-string uses value"
                continue
            }

            $uses = [string] $step['uses']
            if ($uses -cnotmatch '^([^@\s]+)@([^@\s]+)$') {
                Add-Failure "$relativePath job '$jobName' step $displayIndex has unsupported uses '$uses'"
                continue
            }

            $repository = $Matches[1]
            $reference = $Matches[2]

            if (-not $actionLocks.ContainsKey($repository)) {
                Add-Failure "$relativePath job '$jobName' step $displayIndex uses unlocked action '$repository'"
                continue
            }

            $action = $actionLocks[$repository]
            $observation = $observed[$repository]
            $observation.Count++
            $stepRecord.Action = $repository

            if ($reference -cne [string] $action['pin']) {
                Add-Failure "$relativePath job '$jobName' step $displayIndex uses '$reference' instead of locked pin '$($action['pin'])'"
            }

            $inputNames = @()
            if (Test-MapKey $step 'with') {
                if ($step['with'] -isnot [System.Collections.IDictionary]) {
                    Add-Failure "$relativePath job '$jobName' step $displayIndex has a non-mapping with value"
                }
                else {
                    $inputNames = @($step['with'].Keys | ForEach-Object { [string] $_ })
                }
            }

            $contractInputs = New-OrdinalSet
            foreach ($inputName in @($action['contract']['inputs'])) {
                [void] $contractInputs.Add([string] $inputName)
            }

            $newerOnlyInputs = New-OrdinalSet
            foreach ($inputName in @($action['knownNewerOnlyInputs'])) {
                [void] $newerOnlyInputs.Add([string] $inputName)
            }

            foreach ($inputName in $inputNames) {
                [void] $observation.Inputs.Add($inputName)

                if ($newerOnlyInputs.Contains($inputName)) {
                    Add-Failure "$relativePath job '$jobName' step $displayIndex uses newer-only $repository input '$inputName'"
                }
                elseif (-not $contractInputs.Contains($inputName)) {
                    Add-Failure "$relativePath job '$jobName' step $displayIndex uses unsupported $repository input '$inputName'"
                }
            }

            $observation.Occurrences.Add(
                "$relativePath::$jobName::step-$displayIndex inputs=[$(($inputNames | Sort-Object) -join ',')]"
            )
        }

        foreach ($expressionScalar in @(Get-ExpressionScalars $job)) {
            $expressions = [System.Collections.Generic.List[string]]::new()
            $delimitedMatches = $delimitedExpressionPattern.Matches(
                $expressionScalar.Value
            )
            foreach ($delimitedMatch in $delimitedMatches) {
                $expressions.Add($delimitedMatch.Groups[1].Value)
            }
            if (
                $expressionScalar.IsImplicitExpression -and
                $delimitedMatches.Count -eq 0
            ) {
                $expressions.Add($expressionScalar.Value)
            }

            foreach ($expression in $expressions) {
                foreach ($serializedStepMatch in $serializedStepPattern.Matches($expression)) {
                    $serializedStepId = if ($serializedStepMatch.Groups[1].Success) {
                        $serializedStepMatch.Groups[1].Value
                    }
                    elseif ($serializedStepMatch.Groups[2].Success) {
                        $serializedStepMatch.Groups[2].Value
                    }
                    else {
                        $null
                    }

                    if ($null -eq $serializedStepId) {
                        Add-Failure "$relativePath job '$jobName' serializes the complete steps context"
                    }
                    elseif (-not $stepsById.ContainsKey($serializedStepId)) {
                        Add-Failure "$relativePath job '$jobName' serializes unknown step '$serializedStepId'"
                    }
                    elseif ($null -ne $stepsById[$serializedStepId].Action) {
                        Add-Failure "$relativePath job '$jobName' serializes action step '$serializedStepId' and bypasses output locking"
                    }
                }

                $dependencyMatches = $outputDependencyPattern.Matches($expression)
                $outputTokenCount = $outputTokenPattern.Matches($expression).Count

                if ($outputTokenCount -gt $dependencyMatches.Count) {
                    Add-Failure "$relativePath job '$jobName' contains an unsupported dynamic step output expression '$expression'"
                }

                foreach ($dependencyMatch in $dependencyMatches) {
                    $stepId = if ($dependencyMatch.Groups[1].Success) {
                        $dependencyMatch.Groups[1].Value
                    }
                    else {
                        $dependencyMatch.Groups[2].Value
                    }
                    $outputName = if ($dependencyMatch.Groups[3].Success) {
                        $dependencyMatch.Groups[3].Value
                    }
                    else {
                        $dependencyMatch.Groups[4].Value
                    }

                    if (-not $stepsById.ContainsKey($stepId)) {
                        Add-Failure "$relativePath job '$jobName' references output '$outputName' from unknown step '$stepId'"
                        continue
                    }

                    $repository = $stepsById[$stepId].Action
                    if ($null -eq $repository) {
                        continue
                    }

                    $action = $actionLocks[$repository]
                    $contractOutputs = [System.Collections.Generic.Dictionary[string, string]]::new(
                        [System.StringComparer]::OrdinalIgnoreCase
                    )
                    foreach ($lockedOutput in @($action['contract']['outputs'])) {
                        $contractOutputs.Add(
                            [string] $lockedOutput,
                            [string] $lockedOutput
                        )
                    }

                    if (-not $contractOutputs.ContainsKey($outputName)) {
                        Add-Failure "$relativePath job '$jobName' uses unsupported $repository output '$outputName'"
                        continue
                    }

                    $canonicalOutputName = $contractOutputs[$outputName]
                    $outputReferences = $observed[$repository].OutputReferences
                    if (-not $outputReferences.ContainsKey($canonicalOutputName)) {
                        $outputReferences.Add($canonicalOutputName, 0)
                    }
                    $outputReferences[$canonicalOutputName]++
                    $observed[$repository].OutputOccurrences.Add(
                        "$relativePath::$jobName::$stepId.$canonicalOutputName"
                    )
                }
            }
        }
    }
}

foreach ($repository in $actionLocks.Keys) {
    $action = $actionLocks[$repository]
    $observation = $observed[$repository]
    $expectedUses = [int] $action['workflowUsage']['expectedUses']

    if ($observation.Count -ne $expectedUses) {
        Add-Failure "$repository occurs $($observation.Count) times; lock requires $expectedUses"
    }

    $expectedInputs = New-OrdinalSet
    foreach ($inputName in @($action['workflowUsage']['inputs'])) {
        [void] $expectedInputs.Add([string] $inputName)
    }

    if (-not $observation.Inputs.SetEquals($expectedInputs)) {
        Add-Failure (
            "$repository consumed inputs changed: observed=[$(Format-Set $observation.Inputs)] " +
            "locked=[$(Format-Set $expectedInputs)]"
        )
    }

    $expectedOutputReferences = $action['workflowUsage']['outputReferences']
    $allOutputNames = New-OrdinalSet
    foreach ($outputName in @($expectedOutputReferences.Keys)) {
        [void] $allOutputNames.Add([string] $outputName)
    }
    foreach ($outputName in $observation.OutputReferences.Keys) {
        [void] $allOutputNames.Add($outputName)
    }

    foreach ($outputName in $allOutputNames) {
        $expectedCount = if ($expectedOutputReferences.Contains($outputName)) {
            [int] $expectedOutputReferences[$outputName]
        }
        else {
            0
        }
        $observedCount = if ($observation.OutputReferences.ContainsKey($outputName)) {
            $observation.OutputReferences[$outputName]
        }
        else {
            0
        }

        if ($observedCount -ne $expectedCount) {
            Add-Failure "$repository output '$outputName' is referenced $observedCount times; lock requires $expectedCount"
        }
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        [Console]::Error.WriteLine("ERROR: $failure")
    }
    exit 1
}

if (-not $Quiet) {
    foreach ($repository in $actionLocks.Keys | Sort-Object) {
        $action = $actionLocks[$repository]
        $observation = $observed[$repository]
        Write-Output (
            "PASS $repository@$($action['pin']) " +
            "release=$($action['release']['tag']) runtime=$($action['contract']['runtime']) " +
            "uses=$($observation.Count) inputs=[$(Format-Set $observation.Inputs)]"
        )

        foreach ($occurrence in $observation.Occurrences) {
            Write-Output "  $occurrence"
        }

        foreach ($outputName in $observation.OutputReferences.Keys | Sort-Object) {
            Write-Output "  output $outputName references=$($observation.OutputReferences[$outputName])"
        }
        foreach ($outputOccurrence in $observation.OutputOccurrences) {
            Write-Output "  output-reference $outputOccurrence"
        }
    }
}

if ($PassThru) {
    [pscustomobject] @{
        WorkflowCount = $workflowPaths.Count
        ActionUseCount = [int] ($observed.Values | Measure-Object Count -Sum).Sum
        Parser = "powershell-yaml $($yamlModule.Version)"
    }
}
