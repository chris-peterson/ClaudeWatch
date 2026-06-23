#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../watches/watch-node.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-node ==="

echo "--- block (bash target): destructive primitives in node -e ---"
t "node fs.rmSync /etc"     block '{"tool_name":"Bash","tool_input":{"command":"node -e \"require('"'"'fs'"'"').rmSync('"'"'/etc'"'"', {recursive:true})\""}}'
t "node fs.rmSync ~"        block '{"tool_name":"Bash","tool_input":{"command":"node -e \"require('"'"'fs'"'"').rmSync('"'"'~/foo'"'"', {recursive:true})\""}}'
t "node exec rm -rf /"      block '{"tool_name":"Bash","tool_input":{"command":"node -e \"require('"'"'child_process'"'"').execSync('"'"'rm -rf /'"'"')\""}}'
t "node new Function"       block '{"tool_name":"Bash","tool_input":{"command":"node -e \"new Function('"'"'return process.env'"'"')()\""}}'

echo "--- ask (bash target): general fs/child_process/eval primitives ---"
t "node fs.rmSync recursive" ask  '{"tool_name":"Bash","tool_input":{"command":"node -e \"require('"'"'fs'"'"').rmSync('"'"'./build'"'"', {recursive:true})\""}}'
t "node fs.unlinkSync"      ask   '{"tool_name":"Bash","tool_input":{"command":"node -e \"require('"'"'fs'"'"').unlinkSync('"'"'tmp.log'"'"')\""}}'
t "node child_process.exec" ask   '{"tool_name":"Bash","tool_input":{"command":"node -e \"require('"'"'child_process'"'"').exec('"'"'ls'"'"')\""}}'
t "node vm.runInThisContext" ask  '{"tool_name":"Bash","tool_input":{"command":"node -e \"require('"'"'vm'"'"').runInThisContext('"'"'1+1'"'"')\""}}'
t "node eval"               ask   '{"tool_name":"Bash","tool_input":{"command":"node -e \"console.log(eval('"'"'1+1'"'"'))\""}}'

echo "--- allow (bash target): benign node ---"
t "node version"            allow '{"tool_name":"Bash","tool_input":{"command":"node --version"}}'
t "node print"              allow '{"tool_name":"Bash","tool_input":{"command":"node -e \"console.log('"'"'hi'"'"')\""}}'
t "node no filter match"    allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
t "node obj.eval not eval"  allow '{"tool_name":"Bash","tool_input":{"command":"node -e \"obj.eval('"'"'x'"'"')\""}}'

echo "--- block (file target): destructive primitives in .js / .ts ---"
t "Write .js fs.rmSync /etc" block '{"tool_name":"Write","tool_input":{"file_path":"clean.js","content":"const fs = require('"'"'fs'"'"'); fs.rmSync('"'"'/etc'"'"', {recursive:true});\n"}}'
t "Write .ts new Function"   block '{"tool_name":"Write","tool_input":{"file_path":"bad.ts","content":"const f = new Function('"'"'return 1'"'"');\n"}}'
t "Write .mjs exec rm -rf /" block '{"tool_name":"Write","tool_input":{"file_path":"bad.mjs","content":"import {execSync} from '"'"'child_process'"'"'; execSync('"'"'rm -rf /'"'"');\n"}}'

echo "--- ask (file target): general fs/child_process/eval ---"
t "Write .js exec"           ask   '{"tool_name":"Write","tool_input":{"file_path":"a.js","content":"const {exec} = require('"'"'child_process'"'"'); exec('"'"'ls'"'"');\n"}}'
t "Write .js fs.unlink"      ask   '{"tool_name":"Write","tool_input":{"file_path":"a.js","content":"require('"'"'fs'"'"').unlinkSync('"'"'x'"'"');\n"}}'
t "Write .js fs.rm recursive" ask  '{"tool_name":"Write","tool_input":{"file_path":"a.js","content":"fs.rm('"'"'./build'"'"', {recursive: true});\n"}}'
t "Write .ts vm.run"         ask   '{"tool_name":"Write","tool_input":{"file_path":"a.ts","content":"import vm from '"'"'vm'"'"'; vm.runInThisContext('"'"'1+1'"'"');\n"}}'
t "Write .js eval"           ask   '{"tool_name":"Write","tool_input":{"file_path":"a.js","content":"console.log(eval('"'"'1+1'"'"'));\n"}}'

echo "--- allow (file target): benign .js / non-matching ---"
t "Write .js log"            allow '{"tool_name":"Write","tool_input":{"file_path":"hi.js","content":"console.log('"'"'hi'"'"');\n"}}'
t "Write .js obj.eval"       allow '{"tool_name":"Write","tool_input":{"file_path":"a.js","content":"obj.eval('"'"'x'"'"');\n"}}'
t "Write .css eval"          allow '{"tool_name":"Write","tool_input":{"file_path":"x.css","content":".eval { color: red; }"}}'

print_results
