#!/usr/bin/env bash
# Bulk deploy, one worker per region, running regions concurrently.
#
#   ./deploy-parallel.sh 01:us-east-1 02:us-east-2 03:us-west-2 ...
#   ./deploy-parallel.sh $(seq -w 1 12 | awk '{print $1":us-east-1"}')
#
# Students in the same region are applied sequentially by that region's worker;
# different regions run at the same time. A full stack takes 4-6 minutes, so a
# 30-student class spread over 3 regions lands in about 20 minutes rather than
# 2.5 hours.
#
# Concurrency safety: terraform runs in ONE directory here. That works only
# because each worker exports its own TF_DATA_DIR (so the provider cache is not
# shared) and each student is a separate workspace (so state files are
# separate). Do not remove the TF_DATA_DIR export.
set -uo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT"

[ $# -eq 0 ] && { echo "usage: $0 <id>:<region> [<id>:<region> ...]"; exit 1; }

# Bucket the arguments by region.
REGIONS=""
for spec in "$@"; do
  r="${spec#*:}"; [ "$r" = "$spec" ] && r="us-east-1"
  case " $REGIONS " in *" $r "*) ;; *) REGIONS="$REGIONS $r" ;; esac
done

worker() {
  local region="$1"; shift
  export TF_DATA_DIR="$ROOT/.tf-$region"
  cd "$MODULE" || return 1
  terraform init -input=false -no-color >/dev/null 2>&1
  for id in "$@"; do
    terraform workspace select "student-${id}" 2>/dev/null \
      || terraform workspace new "student-${id}" >/dev/null 2>&1
    if AWS_REGION="$region" terraform apply -auto-approve -input=false \
         -var="student_id=${id}" -var="region=${region}" -no-color \
         > "$ROOT/apply-${id}.log" 2>&1; then
      echo "OK   ${id} ${region}"
      AWS_REGION="$region" terraform output -raw student_handout > "$ROOT/handout-${id}.txt" 2>/dev/null
      echo "${id} ${region}" >> "$ROOT/roster.txt"
    else
      echo "FAIL ${id} ${region}  $(grep -m1 '^Error' "$ROOT/apply-${id}.log" | cut -c1-90)"
    fi
  done
}

for r in $REGIONS; do
  ids=""
  for spec in "$@"; do
    sr="${spec#*:}"; [ "$sr" = "$spec" ] && sr="us-east-1"
    [ "$sr" = "$r" ] && ids="$ids ${spec%%:*}"
  done
  # shellcheck disable=SC2086
  worker "$r" $ids &
done
wait

sort -u -o "$ROOT/roster.txt" "$ROOT/roster.txt" 2>/dev/null
echo "=== done ==="
