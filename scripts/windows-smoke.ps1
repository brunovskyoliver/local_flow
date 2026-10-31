# Feature 024: opens the Rust client on each page in a temp data root; a process that exits fails the job.
# The UIA dumps are uploaded as evidence and don't fail it: a runner may have no usable desktop session.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$out = 'build/smoke'; New-Item -ItemType Directory -Force $out | Out-Null
$failed = @()
$walk = [System.Windows.Automation.TreeWalker]::RawViewWalker
function Dump($e, $d, $f) {
  if ($d -gt 40) { return }
  ('{0}{1} name=[{2}]' -f (' ' * $d), $e.Current.ControlType.ProgrammaticName, $e.Current.Name) | Add-Content $f
  $k = $walk.GetFirstChild($e)
  while ($k) { Dump $k ($d + 1) $f; $k = $walk.GetNextSibling($k) }
}
$cases = @(
  @('settings', ''), @('history', ''), @('insights', ''), @('dictionary', ''), @('meetings', ''),
  @('onboarding', ''), @('onboarding', 'onboarding.purpose')
)
foreach ($c in $cases) {
  $name = ($c[0] + '-' + $c[1]) -replace '[^\w\-]', '_'
  $root = Join-Path $env:RUNNER_TEMP "lf-$name"; New-Item -ItemType Directory -Force $root | Out-Null
  $setup = if ($c[0] -eq 'onboarding') { 0 } else { 1 }
  [IO.File]::WriteAllText("$root/preferences.json", "{`"setupVersion`":$setup,`"appearance`":`"light`"}")
  $env:LOCALFLOW_DATA_ROOT = $root; $env:LOCALFLOW_AUDIT_WINDOW = '1'; $env:LOCALFLOW_PAGE = $c[0]; $env:LOCALFLOW_SCENARIO = $c[1]
  $p = Start-Process build/rust/debug/localflow.exe -PassThru -RedirectStandardError "$out/$name.stderr.txt"
  Start-Sleep -Seconds 6
  if ($p.HasExited) { $failed += "$name exited $($p.ExitCode)"; continue }
  try {
    $p.Refresh()
    if ($p.MainWindowHandle -ne 0) {
      # The first read only turns the tree on; it fills on a later frame.
      $el = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
      $null = $walk.GetFirstChild($el); Start-Sleep -Seconds 2
      Dump $el 0 "$out/$name.uia.txt"
    } else { 'no main window' | Set-Content "$out/$name.uia.txt" }
  } catch { "$_" | Set-Content "$out/$name.uia.txt" }
  Stop-Process -Id $p.Id -Force
}
if ($failed) { $failed; exit 1 }
'All pages stayed open.'
