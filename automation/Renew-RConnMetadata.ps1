$ErrorActionPreference = 'Stop'
$repository = 'ahmetakarsu/MedusaRelease'
if ($env:GITHUB_REPOSITORY -ne $repository) { throw 'Renewal repository mismatch.' }
$tag = $env:RCONN_RENEWAL_TAG
$testDraft = $env:RCONN_RENEWAL_TEST_DRAFT -eq 'true'
if ($tag -and $tag -notmatch '^rconn-v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw 'Invalid release tag.' }
if ($testDraft -and -not $tag) { throw 'Draft verification requires one explicit tag.' }
function Invoke-Gh([string[]]$Arguments) {
    $result = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'GitHub operation failed.' }
    return $result
}
$work = Join-Path $env:RUNNER_TEMP ('rconn-renewal-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
# Immutable tool identity: changing the tool release asset alone cannot change executed code.
$toolZip = Join-Path $work 'RConn.MetadataRenewal-v1-win-x64.zip'
Invoke-Gh -Arguments @('release','download','rconn-metadata-renewal-tool-v1','--repo',$repository,'--pattern',
    'RConn.MetadataRenewal-v1-win-x64.zip','--dir',$work) | Out-Null
if ((Get-FileHash -LiteralPath $toolZip -Algorithm SHA256).Hash -ne
    'A4E237867575538E308F9D111005D19C39051C3CD61DD59026B21B07ED3FB196') { throw 'Verifier hash mismatch.' }
$tool = Join-Path $work 'verifier'
Expand-Archive -LiteralPath $toolZip -DestinationPath $tool
# GitHub's by-tag endpoint does not return unpublished draft tags. Listing with
# the same narrowly scoped repository token supports the explicit draft QA route.
$pages = Invoke-Gh -Arguments @('api',('repos/' + $repository + '/releases?per_page=100'),'--paginate','--slurp') | ConvertFrom-Json
$all = @($pages | ForEach-Object { $_ | ForEach-Object { $_ } })
if ($tag) { $all = @($all | Where-Object tag_name -eq $tag) }
$verified = 0; $changed = 0
foreach ($release in $all) {
    if ($release.tag_name -notmatch '^rconn-v((0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*))$') { continue }
    $version = $Matches[1]
    if (($release.draft -or $release.prerelease) -and -not $testDraft) { continue }
    $bundle = @($release.assets | Where-Object name -eq 'rconn-product-renewals.json')
    if ($bundle.Count -eq 0) {
        if ($tag) { throw 'Requested release has no signed renewal bundle.' }
        Write-Output ('Legacy release without rolling renewals: ' + $release.tag_name)
        continue
    }
    $anchor = @($release.assets | Where-Object name -eq 'rconn-product-update.json')
    if ($bundle.Count -ne 1 -or $bundle[0].size -lt 1 -or $bundle[0].size -gt 1048576 -or
        $anchor.Count -ne 1 -or $anchor[0].size -lt 1 -or $anchor[0].size -gt 65536) { throw 'Invalid metadata asset boundary.' }
    $inputDir = Join-Path $work $version
    New-Item -ItemType Directory -Path $inputDir | Out-Null
    foreach ($name in @('rconn-product-update.json','rconn-product-renewals.json')) {
        Invoke-Gh -Arguments @('release','download',$release.tag_name,'--repo',$repository,'--pattern',$name,'--dir',$inputDir) | Out-Null
    }
    $nextDir = Join-Path $inputDir 'next'
    New-Item -ItemType Directory -Path $nextDir | Out-Null
    $current = Join-Path $inputDir 'rconn-product-update.json'
    $next = Join-Path $nextDir 'rconn-product-update.json'
    & dotnet (Join-Path $tool 'RConn.MetadataRenewal.dll') (Join-Path $inputDir 'rconn-product-renewals.json') $current $version $next
    if ($LASTEXITCODE -ne 0) { throw 'Signed renewal verification failed. Existing metadata retained.' }
    $verified++
    if ((Get-FileHash -LiteralPath $current).Hash -eq (Get-FileHash -LiteralPath $next).Hash) {
        Write-Output ('CURRENT ' + $release.tag_name); continue
    }
    # Renew ONLY the fixed metadata asset. Never edit version, notes, draft/prerelease,
    # installer binaries, latest-release selection, user consent or executable hashes.
    Invoke-Gh -Arguments @('release','upload',$release.tag_name,$next,'--repo',$repository,'--clobber') | Out-Null
    $readback = Join-Path $inputDir 'readback'
    New-Item -ItemType Directory -Path $readback | Out-Null
    Invoke-Gh -Arguments @('release','download',$release.tag_name,'--repo',$repository,'--pattern','rconn-product-update.json','--dir',$readback) | Out-Null
    if ((Get-FileHash -LiteralPath (Join-Path $readback 'rconn-product-update.json')).Hash -ne (Get-FileHash -LiteralPath $next).Hash) {
        throw 'Published metadata readback mismatch.'
    }
    $changed++
    Write-Output ('RENEWED ' + $release.tag_name)
}
if ($tag -and $verified -ne 1) { throw 'Requested release was not verified.' }
Write-Output ('Verified releases: ' + $verified + '; renewed assets: ' + $changed)
