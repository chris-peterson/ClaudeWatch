#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../watches/watch-python.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-python ==="

echo "--- block (bash target): destructive primitives in python3 -c ---"
t "shutil.rmtree /etc"      block '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"import shutil; shutil.rmtree('"'"'/etc'"'"')\""}}'
t "shutil.rmtree /"         block '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"import shutil; shutil.rmtree('"'"'/'"'"')\""}}'
t "shutil.rmtree ~"         block '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"import shutil; shutil.rmtree('"'"'~/code'"'"')\""}}'
t "pickle.loads"            block '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"import pickle; pickle.loads(b'"'"'data'"'"')\""}}'
t "__import__ os.system"    block '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"__import__('"'"'os'"'"').system('"'"'rm -rf /'"'"')\""}}'
t "subprocess shell=True rm" block '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"import subprocess; subprocess.run('"'"'rm -rf foo'"'"', shell=True)\""}}'

echo "--- ask (bash target): general subprocess / os primitives ---"
t "shutil.rmtree relative"  ask   '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"import shutil; shutil.rmtree('"'"'./build'"'"')\""}}'
t "os.remove file"          ask   '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"import os; os.remove('"'"'temp.log'"'"')\""}}'
t "os.unlink file"          ask   '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"import os; os.unlink('"'"'temp.log'"'"')\""}}'
t "os.system ls"            ask   '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"import os; os.system('"'"'ls'"'"')\""}}'
t "subprocess shell=True"   ask   '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"import subprocess; subprocess.run('"'"'ls'"'"', shell=True)\""}}'
t "eval expression"         ask   '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"print(eval('"'"'1+1'"'"'))\""}}'
t "exec statement"          ask   '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"exec('"'"'x=1'"'"')\""}}'

echo "--- allow (bash target): benign python ---"
t "python version"          allow '{"tool_name":"Bash","tool_input":{"command":"python3 --version"}}'
t "python print"            allow '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"print('"'"'hi'"'"')\""}}'
t "python no filter match"  allow '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
t "Executor not exec"       allow '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"from concurrent.futures import Executor\""}}'

echo "--- block (file target): destructive primitives in .py ---"
t "Write .py rmtree /etc"   block '{"tool_name":"Write","tool_input":{"file_path":"clean.py","content":"import shutil\nshutil.rmtree(\"/etc\")\n"}}'
t "Write .py pickle.loads"  block '{"tool_name":"Write","tool_input":{"file_path":"load.py","content":"import pickle\npickle.loads(open(\"data\",\"rb\").read())\n"}}'
t "Write .py __import__"    block '{"tool_name":"Write","tool_input":{"file_path":"escape.py","content":"__import__(\"os\").system(\"id\")\n"}}'
t "Write .py shell=True rm" block '{"tool_name":"Write","tool_input":{"file_path":"bad.py","content":"import subprocess\nsubprocess.run(\"rm -rf /tmp/x\", shell=True)\n"}}'

echo "--- ask (file target): general os/subprocess/eval/exec ---"
t "Write .py os.system"     ask   '{"tool_name":"Write","tool_input":{"file_path":"a.py","content":"import os\nos.system(\"ls\")\n"}}'
t "Write .py os.remove"     ask   '{"tool_name":"Write","tool_input":{"file_path":"a.py","content":"import os\nos.remove(\"x\")\n"}}'
t "Write .py shell=True"    ask   '{"tool_name":"Write","tool_input":{"file_path":"a.py","content":"import subprocess\nsubprocess.run(\"ls\", shell=True)\n"}}'
t "Write .py eval"          ask   '{"tool_name":"Write","tool_input":{"file_path":"a.py","content":"print(eval(\"1+1\"))\n"}}'
t "Write .py exec"          ask   '{"tool_name":"Write","tool_input":{"file_path":"a.py","content":"exec(\"x=1\")\n"}}'

echo "--- allow (file target): benign .py / non-matching extension ---"
t "Write .py print"         allow '{"tool_name":"Write","tool_input":{"file_path":"hello.py","content":"print(\"hi\")\n"}}'
t "Write .py Executor"      allow '{"tool_name":"Write","tool_input":{"file_path":"jobs.py","content":"from concurrent.futures import Executor\n"}}'
t "Write .txt eval"         allow '{"tool_name":"Write","tool_input":{"file_path":"notes.txt","content":"discuss eval(...) tomorrow"}}'

echo "--- Edit adds destructive primitive to existing .py ---"
TMPFILE_PY=$(mktemp /tmp/py-edit.XXXXXX.py)
printf 'def helper():\n    return 1\n' > "$TMPFILE_PY"
t "Edit adds eval" ask \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$TMPFILE_PY"'","old_string":"return 1","new_string":"return eval(\"1+1\")"}}'
t "Edit adds rmtree /etc" block \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$TMPFILE_PY"'","old_string":"return 1","new_string":"import shutil; shutil.rmtree(\"/etc\")"}}'
rm -f "$TMPFILE_PY"

print_results
