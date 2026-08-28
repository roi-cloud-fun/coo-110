#!/usr/bin/env bash
# CF-110 / COO-110 - bulk student lab deploy / destroy
#
# Each student gets their own Terraform WORKSPACE. That is not optional: the
# module keeps state locally, so without workspaces a second apply would treat
# the first student's resources as drift and destroy them.
#
# Students may sit in DIFFERENT REGIONS. The region is part of the deployment,
# so it is recorded in the workspace name and must be passed on destroy too.
# Pass each student as  <id>:<region>  -
#
#   ./deploy-students.sh apply   01:us-east-1 02:us-east-2 03:us-west-2
#   ./deploy-students.sh destroy 01:us-east-1
#   ./deploy-students.sh roster
#   ./deploy-students.sh status
#
# Student IDs are two digits and must match the IAM user the student signs in
# as: student_id=07 -> resources named cf110-07-*, signed in as user07.
#
# WHY THE REGION MATTERS TO STUDENTS, NOT JUST TO TERRAFORM
# ---------------------------------------------------------
# The lab guides set REGION=$AWS_REGION, which CloudShell inherits from
# whichever region the console is currently showing. A student whose stack is in
# us-west-2 but whose console is in us-east-1 gets empty results from every
# command - not an error, just nothing. With a split cohort that is the single
# most likely way to lose ten minutes, so the region is printed at the top of
# every handout and should be on the whiteboard.
set -uo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$ROOT/lab_env_student"

ACTION="${1:-}"; shift || true
cd "$MODULE" || { echo "module not found: $MODULE"; exit 1; }

split_id()     { echo "${1%%:*}"; }
split_region() { local r="${1#*:}"; [ "$r" = "$1" ] && r="us-east-1"; echo "$r"; }

case "$ACTION" in
  apply)
    [ $# -eq 0 ] && { echo "usage: $0 apply <id>:<region> [...]"; exit 1; }
    for spec in "$@"; do
      id=$(split_id "$spec"); region=$(split_region "$spec")
      echo "=============== student ${id}  (${region})"
      terraform workspace select "student-${id}" 2>/dev/null \
        || terraform workspace new "student-${id}"
      if AWS_REGION="$region" terraform apply -auto-approve \
           -var="student_id=${id}" -var="region=${region}" -no-color \
           > "$ROOT/apply-${id}.log" 2>&1; then
        echo "  OK  $(grep -E 'Apply complete' "$ROOT/apply-${id}.log")"
        AWS_REGION="$region" terraform output -raw student_handout \
          > "$ROOT/handout-${id}.txt" 2>/dev/null
        echo "${id} ${region}" >> "$ROOT/roster.txt"
      else
        echo "  FAILED - see apply-${id}.log"
        grep -E "^Error" "$ROOT/apply-${id}.log" | head -3
      fi
    done
    sort -u -o "$ROOT/roster.txt" "$ROOT/roster.txt" 2>/dev/null
    ;;

  destroy)
    [ $# -eq 0 ] && { echo "usage: $0 destroy <id>:<region> [...]"; exit 1; }
    for spec in "$@"; do
      id=$(split_id "$spec"); region=$(split_region "$spec")
      echo "=============== student ${id}  (${region}) : destroy"
      terraform workspace select "student-${id}" 2>/dev/null || { echo "  no workspace - skipping"; continue; }
      if AWS_REGION="$region" terraform destroy -auto-approve \
           -var="student_id=${id}" -var="region=${region}" -no-color \
           > "$ROOT/destroy-${id}.log" 2>&1; then
        echo "  OK  $(grep -E 'Destroy complete' "$ROOT/destroy-${id}.log")"
      else
        echo "  FAILED - see destroy-${id}.log"
        grep -E "^Error" "$ROOT/destroy-${id}.log" | head -3
      fi
    done
    terraform workspace select default >/dev/null 2>&1
    ;;

  roster)
    printf "%-10s %-12s %s\n" "STUDENT" "REGION" "SIGN-IN"
    if [ -f "$ROOT/roster.txt" ]; then
      while read -r id region; do
        printf "  user%-7s %-12s https://YOUR-ACCOUNT-ALIAS.signin.aws.amazon.com/console\n" "$id" "$region"
      done < "$ROOT/roster.txt"
    else
      echo "  no roster yet - run apply first"
    fi
    ;;

  status)
    echo "=== workspaces ==="; terraform workspace list
    echo ""
    echo "=== running CF-110 instances per region ==="
    for r in us-east-1 us-east-2 us-west-2; do
      n=$(aws ec2 describe-instances --region "$r" \
            --filters "Name=tag:Course,Values=CF-110" "Name=instance-state-name,Values=running" \
            --query "length(Reservations[].Instances[])" --output text 2>/dev/null)
      printf "  %-12s %s instances  (1 per student stack)\n" "$r" "${n:-0}"
    done
    ;;

  *)
    echo "usage: $0 {apply|destroy|roster|status} [<id>:<region> ...]"
    echo ""
    echo "  $0 apply 01:us-east-1 02:us-east-2 03:us-west-2"
    echo "  $0 roster"
    exit 1
    ;;
esac
