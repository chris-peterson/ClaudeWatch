# PreToolUse launcher (PowerShell): the native-Windows path for hosts where
# Claude Code dispatches command hooks through PowerShell rather than Git Bash.
# Mirrors run-watchdog.sh — resolve a Python interpreter at run time and run the
# engine, with no fabricated decision on failure (see [HK-05], [PL-02], [PL-03]
# in SPEC.md).
#
# On a standard Windows Python install the `py` launcher (py.exe) and `python`
# are reliably on PATH; `python3` is not. Probe python3 -> python -> py and use
# the first one found. Resolution failure is loud (non-zero exit, stderr
# message) rather than a silent no-op, because a PreToolUse hook that produces
# no decision is read by the host as allow-by-default.

$ErrorActionPreference = 'Stop'

$engine  = Join-Path $env:CLAUDE_PLUGIN_ROOT 'scripts/watchdog.py'
$watches = Join-Path $env:CLAUDE_PLUGIN_ROOT 'watches'

# stdin (the tool-input JSON) is read once and forwarded to the interpreter.
$stdin = [Console]::In.ReadToEnd()

foreach ($interp in @('python3', 'python', 'py')) {
    $resolved = Get-Command $interp -ErrorAction SilentlyContinue
    if ($resolved) {
        $stdin | & $resolved.Source $engine $watches
        exit $LASTEXITCODE
    }
}

[Console]::Error.WriteLine('ClaudeWatch: no Python interpreter found (tried python3, python, py); the safety hook cannot run.')
exit 1
