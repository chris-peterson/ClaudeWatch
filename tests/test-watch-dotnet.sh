#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../rules/watch-dotnet.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-dotnet ==="

echo "--- ask: .NET decompilers ---"
t "ilspycmd"        ask '{"tool_name":"Bash","tool_input":{"command":"ilspycmd Newtonsoft.Json.dll"}}'
t "ildasm"          ask '{"tool_name":"Bash","tool_input":{"command":"ildasm /out=foo.il Foo.dll"}}'
t "dotpeek"         ask '{"tool_name":"Bash","tool_input":{"command":"dotpeek Some.dll"}}'
t "dnspy"           ask '{"tool_name":"Bash","tool_input":{"command":"dnspy Foo.dll"}}'
t "dnspyex"         ask '{"tool_name":"Bash","tool_input":{"command":"dnspyex Foo.dll"}}'
t "justdecompile"   ask '{"tool_name":"Bash","tool_input":{"command":"justdecompile Foo.dll"}}'
t "dotnet ilspycmd" ask '{"tool_name":"Bash","tool_input":{"command":"dotnet ilspycmd /path/to/Foo.dll"}}'
t "dnSpy (capital)" ask '{"tool_name":"Bash","tool_input":{"command":"dnSpy Foo.dll"}}'
t "ILDASM (caps)"   ask '{"tool_name":"Bash","tool_input":{"command":"ILDASM /out=foo.il Foo.dll"}}'

echo "--- ask: extract .nupkg ---"
t "unzip nupkg"     ask '{"tool_name":"Bash","tool_input":{"command":"unzip Newtonsoft.Json.13.0.3.nupkg"}}'
t "unzip -p nupkg"  ask '{"tool_name":"Bash","tool_input":{"command":"unzip -p foo.nupkg lib/net6.0/foo.dll > foo.dll"}}'
t "tar nupkg"       ask '{"tool_name":"Bash","tool_input":{"command":"tar -xf foo.nupkg"}}'

echo "--- ask: download .nupkg ---"
t "curl nupkg"      ask '{"tool_name":"Bash","tool_input":{"command":"curl -L -o foo.nupkg https://www.nuget.org/api/v2/package/Foo/1.0.0"}}'
t "curl nupkg url"  ask '{"tool_name":"Bash","tool_input":{"command":"curl https://example.com/Foo.1.0.0.nupkg -o pkg.zip"}}'
t "wget nupkg"      ask '{"tool_name":"Bash","tool_input":{"command":"wget https://www.nuget.org/api/v2/package/Foo/1.0.0 -O foo.nupkg"}}'

echo "--- ask: nuget install ---"
t "nuget install"     ask '{"tool_name":"Bash","tool_input":{"command":"nuget install Newtonsoft.Json"}}'
t "nuget install ver" ask '{"tool_name":"Bash","tool_input":{"command":"nuget install Newtonsoft.Json -Version 13.0.3 -OutputDirectory ./packages"}}'

echo "--- allow: normal .NET workflow ---"
t "dotnet build"           allow '{"tool_name":"Bash","tool_input":{"command":"dotnet build"}}'
t "dotnet test"            allow '{"tool_name":"Bash","tool_input":{"command":"dotnet test"}}'
t "dotnet run"             allow '{"tool_name":"Bash","tool_input":{"command":"dotnet run"}}'
t "dotnet add package"     allow '{"tool_name":"Bash","tool_input":{"command":"dotnet add package Newtonsoft.Json"}}'
t "dotnet restore"         allow '{"tool_name":"Bash","tool_input":{"command":"dotnet restore"}}'
t "dotnet nuget locals"    allow '{"tool_name":"Bash","tool_input":{"command":"dotnet nuget locals all --list"}}'
t "nuget list"             allow '{"tool_name":"Bash","tool_input":{"command":"nuget list Newtonsoft.Json"}}'
t "curl non-nupkg"         allow '{"tool_name":"Bash","tool_input":{"command":"curl -L https://example.com/foo.tar.gz -o foo.tar.gz"}}'
t "unzip non-nupkg"        allow '{"tool_name":"Bash","tool_input":{"command":"unzip release.zip"}}'
t "tar non-nupkg"          allow '{"tool_name":"Bash","tool_input":{"command":"tar -xf release.tar.gz"}}'
t "nuget restore"          allow '{"tool_name":"Bash","tool_input":{"command":"nuget restore MySolution.sln"}}'
t "unzip; then .nupkg"     allow '{"tool_name":"Bash","tool_input":{"command":"unzip foo.zip; echo done.nupkg"}}'
t "unzip && curl .nupkg"   ask   '{"tool_name":"Bash","tool_input":{"command":"unzip foo.zip && curl https://example.com/Foo.nupkg -o pkg.nupkg"}}'
t "ls"                     allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
t "Write tool"             allow '{"tool_name":"Write","tool_input":{"file_path":"Program.cs","content":"class Program {}"}}'

print_results
