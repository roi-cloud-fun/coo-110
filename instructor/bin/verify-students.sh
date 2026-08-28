#!/usr/bin/env bash
# Post-deploy verification. Checks the things the lab guides actually depend on,
# by running the same lookups the students run. A stack that passes here is a
# stack whose guide commands will return what the guide says they return.
#
#   ./verify-students.sh                 # every student in roster.txt
#   ./verify-students.sh 01:us-east-1    # one
set -uo pipefail
export AWS_PROFILE="${AWS_PROFILE:-default}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0; fail=0
chk() { # chk <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1))
  else fail=$((fail+1)); printf "    FAIL %-34s expected[%s] actual[%s]\n" "$1" "$2" "$3"; fi
}

verify() {
  local id="$1" r="$2"
  echo "=== student ${id} (${r})"

  # Lab 1 Task 1 / Lab 2 Task 1: exactly one instance, named to scheme.
  local ids n
  ids=$(aws ec2 describe-instances --region "$r" \
        --filters "Name=tag:Name,Values=cf110-${id}-app" "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[].InstanceId" --output text)
  n=$(echo "$ids" | wc -w)
  chk "one instance named cf110-${id}-app" "1" "$n"
  [ "$n" != "1" ] && { echo "    (skipping instance-dependent checks)"; return; }

  # No leftovers from the three-instance layout.
  local stale
  stale=$(aws ec2 describe-instances --region "$r" \
          --filters "Name=tag:Name,Values=cf110-${id}-lab1-target,cf110-${id}-lab2-private,cf110-${id}-alb-target" \
                    "Name=instance-state-name,Values=running,pending" \
          --query "length(Reservations[].Instances[])" --output text)
  chk "no old-scheme instances" "0" "$stale"

  # Lab 2 Task 1: the instance profile students trace must be MyAppRole.
  local prof
  prof=$(aws ec2 describe-instances --region "$r" --instance-ids "$ids" \
         --query "Reservations[].Instances[].IamInstanceProfile.Arn" --output text)
  chk "profile is MyAppRole" "cf110-${id}-MyAppRole-profile" "${prof##*/}"

  # Lab 1 Task 1 reads 1-minute metrics; basic monitoring makes them look sparse.
  chk "detailed monitoring on" "enabled" \
    "$(aws ec2 describe-instances --region "$r" --instance-ids "$ids" \
       --query "Reservations[].Instances[].Monitoring.State" --output text)"

  # Tags the guides and the facilitator notes name.
  local tags
  tags=$(aws ec2 describe-instances --region "$r" --instance-ids "$ids" \
         --query "Reservations[].Instances[].Tags[?Key=='Application'||Key=='Owner'||Key=='Course'].Value" --output text | tr '\t' ',')
  chk "tags present" "3" "$(echo "$tags" | tr ',' '\n' | grep -c .)"

  # Lab 2 Task 4: the fault. The app SG must exist with NO ingress at all.
  local sgjson ingress
  sgjson=$(aws ec2 describe-security-groups --region "$r" \
           --filters "Name=group-name,Values=cf110-${id}-app-sg" \
           --query "SecurityGroups[0].IpPermissions" --output json 2>/dev/null)
  chk "app-sg exists, zero ingress" "0" "$(echo "$sgjson" | python -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print("missing")')"

  # Lab 2 Task 3 step 2: the SG students rule out must exist and be open on egress.
  chk "private-sg egress open" "1" \
    "$(aws ec2 describe-security-groups --region "$r" \
       --filters "Name=group-name,Values=cf110-${id}-private-sg" \
       --query "length(SecurityGroups[0].IpPermissionsEgress)" --output text 2>/dev/null)"

  # Lab 2 Task 3 step 1: subnet must be findable by tag, since no instance is there.
  chk "private subnet found by tag" "1" \
    "$(aws ec2 describe-subnets --region "$r" --filters "Name=tag:Name,Values=cf110-${id}-private" \
       --query "length(Subnets)" --output text)"

  # Lab 2 Task 3 step 5: the fault is the missing default route.
  local sub
  sub=$(aws ec2 describe-subnets --region "$r" --filters "Name=tag:Name,Values=cf110-${id}-private" \
        --query "Subnets[0].SubnetId" --output text)
  chk "private RT has no 0.0.0.0/0" "0" \
    "$(aws ec2 describe-route-tables --region "$r" --filters "Name=association.subnet-id,Values=$sub" \
       --query "length(RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'])" --output text)"

  # Lab 2 Task 3 step 4: NAT must exist and be healthy (it is ruled out, not the fault).
  chk "NAT available" "1" \
    "$(aws ec2 describe-nat-gateways --region "$r" \
       --filter "Name=tag:Name,Values=cf110-${id}-nat" "Name=state,Values=available" \
       --query "length(NatGateways)" --output text)"

  # Lab 2 Task 4: the ALB's only target must be the one instance.
  local tg
  tg=$(aws elbv2 describe-target-groups --region "$r" --names "cf110-${id}-tg" \
       --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null)
  if [ -n "$tg" ] && [ "$tg" != "None" ]; then
    chk "ALB target is the app instance" "$ids" \
      "$(aws elbv2 describe-target-health --region "$r" --target-group-arn "$tg" \
         --query "TargetHealthDescriptions[].Target.Id" --output text)"
  else
    fail=$((fail+1)); echo "    FAIL target group cf110-${id}-tg not found"
  fi

  # Lab 1 Task 4: gp2 specifically -- BurstBalance does not exist on gp3.
  chk "burst volume is gp2" "gp2" \
    "$(aws ec2 describe-volumes --region "$r" --filters "Name=tag:Name,Values=cf110-${id}-burst-volume" \
       --query "Volumes[0].VolumeType" --output text 2>/dev/null)"

  # Lab 1 Task 2: the timeout must stay above the guide's @duration > 25000 filter.
  chk "lambda timeout 30s" "30" \
    "$(aws lambda get-function-configuration --region "$r" \
       --function-name "cf110-${id}-slow-function" --query "Timeout" --output text 2>/dev/null)"
}

if [ $# -gt 0 ]; then
  for spec in "$@"; do verify "${spec%%:*}" "${spec#*:}"; done
else
  [ -f "$ROOT/roster.txt" ] || { echo "no roster.txt"; exit 1; }
  while read -r id r; do [ -n "$id" ] && verify "$id" "$r"; done < "$ROOT/roster.txt"
fi

echo ""
echo "============================================"
echo "  PASS ${pass}   FAIL ${fail}"
[ "$fail" -eq 0 ] && echo "  every stack matches what the guides claim" || echo "  fix the above before class"
