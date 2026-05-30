#!/bin/bash
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"

RULES="$SCRIPT_DIR/../rules/watch-aws.yml"
t() { run_test "$RULES" "$@"; }

echo "=== watch-aws ==="

echo "--- block: delete / remove / deregister ---"
t "delete-bucket"        block '{"tool_name":"Bash","tool_input":{"command":"aws s3api delete-bucket --bucket my-bucket"}}'
t "delete-stack"         block '{"tool_name":"Bash","tool_input":{"command":"aws cloudformation delete-stack --stack-name prod"}}'
t "remove-tags"          block '{"tool_name":"Bash","tool_input":{"command":"aws ec2 remove-tags --resources i-123"}}'
t "deregister-task-def"  block '{"tool_name":"Bash","tool_input":{"command":"aws ecs deregister-task-definition --task-definition app:3"}}'

echo "--- block: terminate / purge / reset / revoke / release-address ---"
t "terminate-instances"  block '{"tool_name":"Bash","tool_input":{"command":"aws ec2 terminate-instances --instance-ids i-123"}}'
t "purge-queue"          block '{"tool_name":"Bash","tool_input":{"command":"aws sqs purge-queue --queue-url https://sqs/x"}}'
t "reset-service-setting" block '{"tool_name":"Bash","tool_input":{"command":"aws ssm reset-service-setting --setting-id x"}}'
t "revoke-sg-ingress"    block '{"tool_name":"Bash","tool_input":{"command":"aws ec2 revoke-security-group-ingress --group-id sg-1"}}'
t "release-address"      block '{"tool_name":"Bash","tool_input":{"command":"aws ec2 release-address --allocation-id eipalloc-1"}}'

echo "--- block: s3 high-level rm / rb ---"
t "s3 rm"                block '{"tool_name":"Bash","tool_input":{"command":"aws s3 rm s3://my-bucket/path --recursive"}}'
t "s3 rb"                block '{"tool_name":"Bash","tool_input":{"command":"aws s3 rb s3://my-bucket --force"}}'

echo "--- block: through interspersed global flags ---"
t "global flag before service"   block '{"tool_name":"Bash","tool_input":{"command":"aws --profile prod ec2 terminate-instances --instance-ids i-1"}}'
t "global flag between svc/op"    block '{"tool_name":"Bash","tool_input":{"command":"aws ec2 --region us-east-1 delete-vpc --vpc-id vpc-1"}}'
t "quoted-value global flag"      block '{"tool_name":"Bash","tool_input":{"command":"aws --region \"us east 1\" s3api delete-object --bucket b --key k"}}'

echo "--- ask: mutating operations ---"
t "create-bucket"        ask '{"tool_name":"Bash","tool_input":{"command":"aws s3api create-bucket --bucket new"}}'
t "run-instances"        ask '{"tool_name":"Bash","tool_input":{"command":"aws ec2 run-instances --image-id ami-1"}}'
t "put-object"           ask '{"tool_name":"Bash","tool_input":{"command":"aws s3api put-object --bucket b --key k"}}'
t "update-stack"         ask '{"tool_name":"Bash","tool_input":{"command":"aws cloudformation update-stack --stack-name prod"}}'
t "modify-instance"      ask '{"tool_name":"Bash","tool_input":{"command":"aws ec2 modify-instance-attribute --instance-id i-1"}}'
t "start-instances"      ask '{"tool_name":"Bash","tool_input":{"command":"aws ec2 start-instances --instance-ids i-1"}}'
t "stop-instances"       ask '{"tool_name":"Bash","tool_input":{"command":"aws ec2 stop-instances --instance-ids i-1"}}'
t "configure set"        ask '{"tool_name":"Bash","tool_input":{"command":"aws configure set region us-east-1"}}'

echo "--- ask: s3 high-level mutating (cp / mv / sync) ---"
t "s3 cp"                ask '{"tool_name":"Bash","tool_input":{"command":"aws s3 cp file.txt s3://b/k"}}'
t "s3 sync"              ask '{"tool_name":"Bash","tool_input":{"command":"aws s3 sync ./dist s3://b/site"}}'
t "s3 mv"                ask '{"tool_name":"Bash","tool_input":{"command":"aws s3 mv a.txt s3://b/a.txt"}}'

echo "--- allow: read-only get / list / describe / head ---"
t "describe-instances"   allow '{"tool_name":"Bash","tool_input":{"command":"aws ec2 describe-instances"}}'
t "list-buckets"         allow '{"tool_name":"Bash","tool_input":{"command":"aws s3api list-buckets"}}'
t "get-object"           allow '{"tool_name":"Bash","tool_input":{"command":"aws s3api get-object --bucket b --key k out.txt"}}'
t "get-caller-identity"  allow '{"tool_name":"Bash","tool_input":{"command":"aws sts get-caller-identity"}}'
t "head-object"          allow '{"tool_name":"Bash","tool_input":{"command":"aws s3api head-object --bucket b --key k"}}'
t "describe w/ profile"  allow '{"tool_name":"Bash","tool_input":{"command":"aws --profile prod ec2 describe-instances --region us-east-1"}}'

echo "--- allow: s3 ls and bare aws ---"
t "s3 ls"                allow '{"tool_name":"Bash","tool_input":{"command":"aws s3 ls s3://my-bucket/"}}'
t "aws help"             allow '{"tool_name":"Bash","tool_input":{"command":"aws help"}}'
t "aws --version"        allow '{"tool_name":"Bash","tool_input":{"command":"aws --version"}}'

echo "--- allow: global-flag value beginning with a blocked verb (regression) ---"
t "profile named delete-*"   allow '{"tool_name":"Bash","tool_input":{"command":"aws --profile delete-prod ec2 describe-instances"}}'
t "region named terminate-*" allow '{"tool_name":"Bash","tool_input":{"command":"aws --region terminate-west s3 ls"}}'
t "profile named reset-*"    allow '{"tool_name":"Bash","tool_input":{"command":"aws --profile reset-foo sts get-caller-identity"}}'

echo "--- block: verb-prefixed flag value still blocks a genuinely destructive op ---"
t "delete-* profile + terminate" block '{"tool_name":"Bash","tool_input":{"command":"aws --profile delete-prod ec2 terminate-instances --instance-ids i-1"}}'

echo "--- allow: hyphenated service name still reaches its operation ---"
t "application-autoscaling describe" allow '{"tool_name":"Bash","tool_input":{"command":"aws application-autoscaling describe-scalable-targets --service-namespace ecs"}}'
t "application-autoscaling delete"   block '{"tool_name":"Bash","tool_input":{"command":"aws application-autoscaling delete-scaling-policy --policy-name p"}}'

echo "--- allow: non-aws and other tools ---"
t "non-aws command"      allow '{"tool_name":"Bash","tool_input":{"command":"terraform apply"}}'
t "aws-iam-authenticator" allow '{"tool_name":"Bash","tool_input":{"command":"aws-iam-authenticator token -i cluster"}}'
t "Write tool"           allow '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'

print_results
