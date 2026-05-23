#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../rules/watch-ruby.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-ruby ==="

echo "--- block (bash target): destructive primitives in ruby -e ---"
t "ruby FileUtils.rm_rf /etc" block '{"tool_name":"Bash","tool_input":{"command":"ruby -e \"require '"'"'fileutils'"'"'; FileUtils.rm_rf('"'"'/etc'"'"')\""}}'
t "ruby FileUtils.rm_rf ~"   block '{"tool_name":"Bash","tool_input":{"command":"ruby -e \"FileUtils.rm_rf('"'"'~/code'"'"')\""}}'
t "ruby Marshal.load"        block '{"tool_name":"Bash","tool_input":{"command":"ruby -e \"Marshal.load(STDIN)\""}}'
t "ruby YAML.load"           block '{"tool_name":"Bash","tool_input":{"command":"ruby -e \"YAML.load(File.read('"'"'x.yml'"'"'))\""}}'

echo "--- ask (bash target): general delete/system/eval primitives ---"
t "ruby FileUtils.rm_rf rel" ask   '{"tool_name":"Bash","tool_input":{"command":"ruby -e \"FileUtils.rm_rf('"'"'./build'"'"')\""}}'
t "ruby File.delete"         ask   '{"tool_name":"Bash","tool_input":{"command":"ruby -e \"File.delete('"'"'tmp.log'"'"')\""}}'
t "ruby system call"         ask   '{"tool_name":"Bash","tool_input":{"command":"ruby -e \"system('"'"'ls'"'"')\""}}'
t "ruby eval"                ask   '{"tool_name":"Bash","tool_input":{"command":"ruby -e \"puts eval('"'"'1+1'"'"')\""}}'
t "ruby instance_eval"       ask   '{"tool_name":"Bash","tool_input":{"command":"ruby -e \"x.instance_eval { puts self }\""}}'

echo "--- allow (bash target): benign ruby ---"
t "ruby version"             allow '{"tool_name":"Bash","tool_input":{"command":"ruby --version"}}'
t "ruby print"               allow '{"tool_name":"Bash","tool_input":{"command":"ruby -e \"puts '"'"'hi'"'"'\""}}'
t "ruby no filter match"     allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
t "ruby YAML.safe_load"      allow '{"tool_name":"Bash","tool_input":{"command":"ruby -e \"YAML.safe_load(s)\""}}'

echo "--- block (file target): destructive primitives in .rb ---"
t "Write .rb rm_rf /etc"     block '{"tool_name":"Write","tool_input":{"file_path":"clean.rb","content":"require '"'"'fileutils'"'"'\nFileUtils.rm_rf('"'"'/etc'"'"')\n"}}'
t "Write .rb Marshal.load"   block '{"tool_name":"Write","tool_input":{"file_path":"load.rb","content":"data = Marshal.load(File.read('"'"'cache.dat'"'"'))\n"}}'
t "Write .rb YAML.load"      block '{"tool_name":"Write","tool_input":{"file_path":"cfg.rb","content":"cfg = YAML.load(File.read('"'"'config.yml'"'"'))\n"}}'

echo "--- ask (file target): general system/eval primitives ---"
t "Write .rb system"         ask   '{"tool_name":"Write","tool_input":{"file_path":"a.rb","content":"system('"'"'ls'"'"')\n"}}'
t "Write .rb File.delete"    ask   '{"tool_name":"Write","tool_input":{"file_path":"a.rb","content":"File.delete('"'"'x'"'"')\n"}}'
t "Write .rb FileUtils.rm_rf" ask  '{"tool_name":"Write","tool_input":{"file_path":"a.rb","content":"FileUtils.rm_rf('"'"'./build'"'"')\n"}}'
t "Write .rb backtick interp" ask  '{"tool_name":"Write","tool_input":{"file_path":"a.rb","content":"result = `ls #{path}`\n"}}'
t "Write .rb eval"           ask   '{"tool_name":"Write","tool_input":{"file_path":"a.rb","content":"puts eval('"'"'1+1'"'"')\n"}}'
t "Write .rb instance_eval"  ask   '{"tool_name":"Write","tool_input":{"file_path":"a.rb","content":"x.instance_eval { 1 }\n"}}'

echo "--- allow (file target): benign .rb / non-matching ---"
t "Write .rb puts"           allow '{"tool_name":"Write","tool_input":{"file_path":"hi.rb","content":"puts '"'"'hi'"'"'\n"}}'
t "Write .rb YAML.safe_load" allow '{"tool_name":"Write","tool_input":{"file_path":"a.rb","content":"YAML.safe_load(s)\n"}}'
t "Write .rb obj.eval"       allow '{"tool_name":"Write","tool_input":{"file_path":"a.rb","content":"obj.eval('"'"'x'"'"')\n"}}'
t "Write .txt eval"          allow '{"tool_name":"Write","tool_input":{"file_path":"notes.txt","content":"discuss eval tomorrow"}}'

print_results
