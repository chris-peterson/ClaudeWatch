#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../watches/watch-remote.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-remote ==="

echo "--- block: repo delete ---"
t "gh repo delete"       block '{"tool_name":"Bash","tool_input":{"command":"gh repo delete owner/project --yes"}}'
t "gh repo delete (cwd)" block '{"tool_name":"Bash","tool_input":{"command":"gh repo delete"}}'
t "glab repo delete"     block '{"tool_name":"Bash","tool_input":{"command":"glab repo delete group/project -y"}}'
t "gh -R repo delete"    block '{"tool_name":"Bash","tool_input":{"command":"gh --repo owner/x repo delete --yes"}}'

echo "--- block: stack destroy ---"
t "terraform destroy"    block '{"tool_name":"Bash","tool_input":{"command":"terraform destroy -auto-approve"}}'
t "terraform -chdir destroy" block '{"tool_name":"Bash","tool_input":{"command":"terraform -chdir=envs/dev destroy"}}'
t "terraform apply -destroy" block '{"tool_name":"Bash","tool_input":{"command":"terraform apply -destroy -auto-approve"}}'
t "tofu destroy"         block '{"tool_name":"Bash","tool_input":{"command":"tofu destroy"}}'
t "pulumi destroy"       block '{"tool_name":"Bash","tool_input":{"command":"pulumi destroy --yes"}}'
t "pulumi down"          block '{"tool_name":"Bash","tool_input":{"command":"pulumi down -s dev"}}'

echo "--- block: kubectl delete namespace / --all ---"
t "delete namespace"     block '{"tool_name":"Bash","tool_input":{"command":"kubectl delete namespace production"}}'
t "delete ns"            block '{"tool_name":"Bash","tool_input":{"command":"kubectl delete ns preview"}}'
t "--context delete ns"  block '{"tool_name":"Bash","tool_input":{"command":"kubectl --context prod delete ns preview"}}'
t "delete pods --all"    block '{"tool_name":"Bash","tool_input":{"command":"kubectl delete pods --all -n app"}}'
t "delete --all-namespaces" block '{"tool_name":"Bash","tool_input":{"command":"kubectl delete deploy web --all-namespaces"}}'
t "delete ns --dry-run=client" allow '{"tool_name":"Bash","tool_input":{"command":"kubectl delete namespace production --dry-run=client"}}'
t "delete --all --dry-run=server" allow '{"tool_name":"Bash","tool_input":{"command":"kubectl delete pods --all --dry-run=server"}}'
t "delete ns --dry-run=none (real)" block '{"tool_name":"Bash","tool_input":{"command":"kubectl delete namespace production --dry-run=none"}}'
t "terraform destroy -help" allow '{"tool_name":"Bash","tool_input":{"command":"terraform destroy -help"}}'
t "gh repo delete --help" allow '{"tool_name":"Bash","tool_input":{"command":"gh repo delete --help"}}'

echo "--- allow: reads and scoped changes ---"
t "gh repo view"         allow '{"tool_name":"Bash","tool_input":{"command":"gh repo view owner/project"}}'
t "gh pr list"           allow '{"tool_name":"Bash","tool_input":{"command":"gh pr list --state open"}}'
t "terraform plan"       allow '{"tool_name":"Bash","tool_input":{"command":"terraform plan -out=tf.plan"}}'
t "terraform plan -destroy" allow '{"tool_name":"Bash","tool_input":{"command":"terraform plan -destroy"}}'
t "terraform apply"      allow '{"tool_name":"Bash","tool_input":{"command":"terraform apply tf.plan"}}'
t "pulumi preview"       allow '{"tool_name":"Bash","tool_input":{"command":"pulumi preview"}}'
t "kubectl get ns"       allow '{"tool_name":"Bash","tool_input":{"command":"kubectl get ns"}}'
t "kubectl delete pod x" allow '{"tool_name":"Bash","tool_input":{"command":"kubectl delete pod web-7d9f -n app"}}'
t "grep terraform destroy" allow '{"tool_name":"Bash","tool_input":{"command":"grep -rn \"destroy\" terraform/"}}'

print_results
