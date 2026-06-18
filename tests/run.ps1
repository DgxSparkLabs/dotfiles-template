# Run every test_*.ps1 in its own child pwsh; exit nonzero if any fails.
$here = Split-Path -Parent $PSCommandPath
$rc = 0
Get-ChildItem -Path $here -Filter 'test_*.ps1' | ForEach-Object {
  Write-Output "`n##### RUN $($_.Name) #####"
  & pwsh -NoProfile -File $_.FullName
  if ($LASTEXITCODE -ne 0) { $rc = 1 }
}
Write-Output "`n##### run.ps1 overall rc=$rc #####"
exit $rc
