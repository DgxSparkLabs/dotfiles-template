# Child-process dispatcher runner for tests: preserves arg boundaries (incl. zero args),
# isolates $HOME, dot-sources the dispatcher, runs it, and propagates the exit code.
param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $A)
Set-Variable -Name HOME -Value $env:HOME -Force -ErrorAction SilentlyContinue
. $env:DOTFILES_DISPATCHER
if ($null -eq $A) { $A = @() }
dotfiles @A
exit $LASTEXITCODE
