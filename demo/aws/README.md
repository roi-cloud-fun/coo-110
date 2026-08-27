# AWS Demo Environment — "OrderFlow"

Instructor demo environment for **COO-110 AWS Troubleshooting Deep Dive**. One coherent
application, deployed broken on purpose, with the full observability stack wired around it.

It exists so every chapter demo runs against real infrastructure instead of placeholder commands
read off a slide. **This is not the student lab environment** — the student labs are in
[`../../lab_1/`](../../lab_1/README.md) and [`../../lab_2/`](../../lab_2/README.md), and their per-student
Terraform is maintained separately. This stack is deployed once, by the instructor, for the
front of the room.

| | |
|---|---|
| **Deploys** | 62 resources |
| **Cost** | ~**$1.30/day** at defaults · ~$2.40/day with the NAT gateway |
| **Region** | us-east-1 (override with `-var="region=..."`) |
| **VPC CIDR** | `10.80.0.0/16` — deliberately different from the student lab's `10.60.0.0/16` |

---

## The scenario

**OrderFlow** is a small order-processing service:

- An **ALB** in front of two web nodes, `web-a` and `web-b`
- An **order processor Lambda** invoked once a minute, calling a simulated payment gateway
- An **orders S3 bucket** holding CSV exports
- A **batch worker** in a private subnet
- **VPC Flow Logs**, **CloudTrail** (with S3 data events), a **CloudWatch dashboard**, and three **alarms**

Five faults are injected, one per chapter. They are intentional — do not "fix" them in Terraform.

| Ch | Fault | What the instructor shows |
|----|-------|---------------------------|
| 1 | One of two ALB targets is unhealthy | `UnHealthyHostCount` confirms a hypothesis |
| 2 | Lambda's gateway call sometimes exceeds its 30s timeout | Measured duration against a configured ceiling |
| 3 | `SettlementRole` trusts the wrong principal | Both halves of a trust relationship |
| 4 | Private route table has no default route | A fault that leaves no trace anywhere |
| 5 | App role granted `ListBucket` but not `GetObject` | Narrowing `AccessDenied` to one action |

### The design decision worth knowing

`web-a` and `web-b` run the **same AMI, same user data, same web server**. They differ in exactly
one way: `web-b`'s security group has no ingress rule for the ALB. That gives you a controlled
comparison — "one works, one does not, and here is the single difference" — which is both the most
useful real-world technique and a far better demo than a single broken resource.

It also produces a genuinely non-zero `UnHealthyHostCount` for the Chapter 1 metric demo while
OrderFlow itself stays up and serving from `web-a`.

---

## Deploy

```bash
cd demo_environment
terraform init
terraform apply
terraform output -raw demo_handout    # every identifier the runbook needs
```

Then open the dashboard URL from the handout. That single screen is where most of the demo runs.

### Give it ten minutes before demoing

Three things need time to become true. Deploy at the start of the day, not the start of the demo:

| Signal | Ready after |
|--------|-------------|
| ALB target health settles to 1 healthy / 1 unhealthy | ~2 min (two 30s check cycles) |
| Lambda timeout history accumulates | ~5 min (invoked once a minute) |
| VPC Flow Log REJECT records appear | up to 10 min (aggregation interval) |
| CloudTrail S3 data events appear | up to **15 min** |

**CloudTrail is the one that catches people out.** If you plan to demo it, trigger a denied
`GetObject` at the *start* of the session and come back to it later in the day.

### Options

```bash
# Add the NAT gateway (~$1.10/day) only if you want to apply the Ch4 fix live.
# The fault presents identically without it.
terraform apply -var="create_nat_gateway=true"

# Skip the CloudTrail trail. Note this breaks the Ch3/Ch5 CloudTrail demos —
# S3 data events are not recorded without it.
terraform apply -var="create_cloudtrail=false"

# AWS Config rules — READ THE WARNING BELOW FIRST
terraform apply -var="create_config_rules=true"
```

> ### AWS Config: check before you enable it
>
> AWS permits **exactly one configuration recorder per region per account**, and most training
> accounts already have one. This module therefore creates **rules only** — never a recorder or
> delivery channel — so it cannot collide with an existing setup.
>
> The rules evaluate against whatever recorder already exists. If the account has none, they
> deploy but never evaluate and show "No results available". Check first:
>
> ```bash
> aws configservice describe-configuration-recorder-status
> ```
>
> If that returns an empty list, either leave `create_config_rules = false` or enable Config in
> the console before applying.

### Terraform state and Google Drive

This directory lives inside a Google Drive-synced folder. Drive sync **corrupts the
`.terraform/providers` cache**, producing checksum errors on `validate` and `plan`:

```
Error: the cached package for registry.terraform.io/hashicorp/random ...
does not match any of the checksums recorded in the dependency lock file
```

Two ways around it:

```bash
# Preferred — keep the provider cache outside the synced folder
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

# Or work from a local copy
cp -r demo_environment ~/cf110-demo && cd ~/cf110-demo
```

If you hit it anyway: `rm -rf .terraform .terraform.lock.hcl && terraform init -upgrade`.

---

## Teardown — same day

```bash
terraform destroy
```

At defaults this is ~$1.30/day, so a forgotten stack is not catastrophic — but the ALB and the
three instances bill continuously. Confirm nothing survives:

```bash
aws ec2 describe-instances --filters "Name=tag:Purpose,Values=instructor-demo" \
  "Name=instance-state-name,Values=running" --query "length(Reservations[].Instances[])"
aws elbv2 describe-load-balancers --query "length(LoadBalancers)"
```

---

# Demo runbook

Every command below runs verbatim once you export the handout values. Nothing is a placeholder.

```bash
export AWS_PROFILE=<your-profile> AWS_REGION=us-east-1
export ALB_DIM=$(terraform output -raw alb_dimension)
export BUCKET=$(terraform output -raw orders_bucket)
export TG_ARN=$(terraform output -raw target_group_arn)
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export PREFIX=cf110-demo
```

---

## Demo 1 — Chapter 1: the structured method, end to end

**Story:** "Support says OrderFlow is degraded. Work the five phases."

**Symptom.** Show the app is up:

```bash
curl -s http://$(terraform output -raw alb_dns_name)/ | grep node
```

**Hypothesis.** It serves, so it is not down — it may be degraded. If a target were failing,
`UnHealthyHostCount` would be non-zero.

**Investigate.**

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB --metric-name UnHealthyHostCount \
  --dimensions Name=LoadBalancer,Value="${ALB_DIM}" \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Maximum --output table
```

**Expect:** `Maximum` of `1.0`. One of two targets is down; the service survives on the other.

> **Teaching point.** Note what the date arithmetic is doing. The version of this command on the
> old Chapter 1 slide used hardcoded `2024-01-01` timestamps, which return an empty result set
> forever. An empty metric result looks identical to "no problem" — always anchor the window
> relative to now.

**Resolve and document** are Demos 4 and 5. Close by naming the phases you just walked.

---

## Demo 2 — Chapter 2: separating a host fault from a guest fault

**Story:** "A ticket says 'check web-b'. That is not a diagnosis."

```bash
WEB_B=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PREFIX}-web-b" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text)

aws ec2 describe-instance-status --instance-ids "${WEB_B}" \
  --query "InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}" \
  --output table
```

**Expect:** both `ok`.

> **Teaching point — this is the most important minute of the day.** The instance is healthy.
> The system check covers AWS's hardware; the instance check covers the guest OS. Both pass, so
> both layers are excluded, and that exclusion is a *result*. Say so explicitly: students meet
> the same finding in Lab 1 Task 1 and will otherwise assume they made a mistake.
>
> Add the remedies while you are here: a failing **system** check is fixed by stop-start, which
> moves the instance to new hardware. A reboot keeps it on the same host and fixes nothing.

Then the Lambda:

```bash
aws lambda get-function-configuration \
  --function-name ${PREFIX}-order-processor \
  --query "{Timeout:Timeout,Runtime:Runtime}" --output table
```

**Expect:** timeout `30`, runtime `python3.12`. Hold that 30.

In the console: **CloudWatch → Logs → Log Analytics**, select `/aws/lambda/cf110-demo-order-processor`,
time range 30 minutes:

```
fields @timestamp, @duration
| filter @type = 'REPORT' and @duration > 25000
| sort @timestamp desc
| limit 20
```

**Expect:** rows with `@duration` at exactly `30000` — a hard wall, the signature of a timeout.

```
fields @timestamp, @message
| filter @message like /calling payment gateway/
| sort @timestamp desc
| limit 30
```

**Expect:** two clusters — 90–260 ms, and 31000/38000/45000 ms. Every slow value exceeds the
ceiling. The function is not slow on average; a dependency occasionally cannot finish in time.

> **Teaching point.** Searching for `Task timed out` returns **nothing** here, even though the
> function is definitely timing out. On the Python 3.12 runtime the timeout is recorded as
> `Status: timeout` on the REPORT line. Nearly every published example still shows the old
> string. A zero-row result is not evidence of health.

---

## Demo 3 — Chapter 3: which half of the trust relationship denies?

**Story:** "The reporting job cannot assume the settlement role. Its team says their permissions
are fine. They are right — and it still fails."

**Half one, the caller:**

```bash
aws iam get-role-policy --role-name ${PREFIX}-ReportingRole \
  --policy-name AllowAssumeSettlement \
  --query "PolicyDocument.Statement" --output json
```

**Expect:** allows `sts:AssumeRole` on the SettlementRole ARN. Correct.

**Half two, the target:**

```bash
aws iam get-role --role-name ${PREFIX}-SettlementRole \
  --query "Role.AssumeRolePolicyDocument.Statement[].Principal" --output json
```

**Expect:** trusts `...:role/cf110-demo-OrderFlowWebRole` — the **web** role, not ReportingRole.

> **Teaching point.** Both halves must approve. The caller may try; the target refuses. Both
> failure modes return the same `AccessDenied`, which is why engineers lose hours re-reading the
> caller's policy. Quick discriminator: if the caller's policy allows `sts:AssumeRole` on the
> exact target ARN and it still fails, suspect the trust policy.
>
> Also flag the *wrong* fix: naming the account root makes it work while delegating the decision
> to every identity in the account. Name the specific role ARN.

Then the Policy Simulator, one action per resource ARN:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${ACCOUNT}:role/${PREFIX}-OrderFlowAppRole" \
  --action-names s3:ListBucket --resource-arns "arn:aws:s3:::${BUCKET}" \
  --query "EvaluationResults[].EvalDecision" --output text
# -> allowed

aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${ACCOUNT}:role/${PREFIX}-OrderFlowAppRole" \
  --action-names s3:GetObject --resource-arns "arn:aws:s3:::${BUCKET}/orders/README.txt" \
  --query "EvaluationResults[].EvalDecision" --output text
# -> implicitDeny
```

> **Teaching point — the highest-value idea in Chapter 3.** Two separate calls, deliberately.
> Pass both ARNs to one call and the top-level `EvalDecision` collapses to the most restrictive
> result across all resources: `ListBucket` reports `implicitDeny` even though it is genuinely
> allowed. The call succeeds and tells you the opposite of the truth.
>
> And `implicitDeny` ≠ `explicitDeny`. Implicit means nothing granted it — add the Allow.
> Explicit means something forbids it, and adding an Allow changes nothing.

---

## Demo 4 — Chapter 4: two faults, one loud and one silent

This is the strongest demo in the set. Run both halves together; the contrast is the lesson.

### The silent one — a missing route

```bash
SUBNET=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=${PREFIX}-private" \
  --query "Subnets[].SubnetId" --output text)

aws ec2 describe-security-groups --filters "Name=group-name,Values=${PREFIX}-batch-sg" \
  --query "SecurityGroups[].IpPermissionsEgress[].IpProtocol" --output text
# -1  -> egress wide open. Not the SG.

aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=${SUBNET}" \
  --query "NetworkAcls[].Entries[?RuleNumber==\`100\`].[RuleAction,Egress]" --output text
# allow  -> default NACL. Not the NACL.

aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${SUBNET}" \
  --query "RouteTables[].Routes[].{Dest:DestinationCidrBlock,Gateway:GatewayId}" --output table
# ONE route: 10.80.0.0/16 local. No 0.0.0.0/0.
```

> **Teaching point.** Nothing logged. No rejected packet, no error, no alarm — traffic addressed
> outside the VPC has no matching route and is silently discarded. You cannot find this by
> looking harder at the host; you find it by reading the routing table. Eliminate in order and
> the answer arrives by subtraction.

### The loud one — rejected health probes

```bash
aws elbv2 describe-target-health --target-group-arn "${TG_ARN}" \
  --query "TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}" \
  --output table
```

**Expect:** one `healthy`, one `unhealthy` with reason `Target.Timeout`.

```bash
aws ec2 describe-security-groups --filters "Name=group-name,Values=${PREFIX}-web-b-sg" \
  --query "SecurityGroups[].IpPermissions" --output json
# []  -> no inbound rules at all

aws ec2 describe-security-groups --filters "Name=group-name,Values=${PREFIX}-web-a-sg" \
  --query "SecurityGroups[].IpPermissions[].UserIdGroupPairs[].GroupId" --output text
# the ALB security group -> the single difference between the two nodes
```

Then the evidence, in **Log Analytics** on `/cf110-demo/vpc-flow-logs`:

```
fields @timestamp, srcAddr, dstAddr, dstPort, action
| filter dstPort = 80 and action = 'REJECT'
| sort @timestamp desc
| limit 50
```

**Expect:** REJECT records from the ALB nodes to `web-b`, roughly two every 30 seconds.

> **Teaching point.** `Target.Timeout` means the probe got no answer — a network path problem.
> `Target.ResponseCodeMismatch` would mean the server answered wrongly — an application problem.
> Reading the reason code first tells you which half of the stack to investigate.
>
> **Do not add a `srcAddr` filter without checking the CIDR.** This VPC is `10.80.0.0/16`. A
> filter written for `10.0.` — as the old Chapter 4 slide had it — matches nothing and returns
> zero rows while reporting success. Query broad, confirm rows, then narrow.

---

## Demo 5 — Chapter 5: narrowing AccessDenied to one action

```bash
aws s3 ls "s3://${BUCKET}/orders/"
# succeeds - two objects
```

Now assume the app role and try to read (or simply simulate it, as in Demo 3):

```bash
aws s3api get-bucket-policy --bucket "${BUCKET}" 2>&1 | head -2
# NoSuchBucketPolicy

aws s3api get-public-access-block --bucket "${BUCKET}" \
  --query "PublicAccessBlockConfiguration" --output table

aws s3api get-bucket-ownership-controls --bucket "${BUCKET}" \
  --query "OwnershipControls.Rules[].ObjectOwnership" --output text
# BucketOwnerEnforced
```

> **Teaching point.** The asymmetry does the work. Listing succeeds and reading fails, so every
> *bucket-level* control is already excluded — a bucket policy, Block Public Access, or an
> ownership setting would have blocked the listing too. The fault has to be action-level, which
> points at the identity policy. `NoSuchBucketPolicy` confirms the identity policy is the only
> control in play.
>
> The fix is `s3:GetObject` on the **object** ARN (`.../*`), not the bucket ARN. Granting an
> object action on a bucket ARN is among the most common IAM mistakes and it fails silently —
> the policy saves without error and access still does not work.

**CloudTrail** (only if you triggered a denied read ≥15 minutes ago):

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=GetObject \
  --max-results 10 --query "Events[].{Time:EventTime,User:Username}" --output table
```

> **Teaching point.** This works here **only because the trail in this module logs S3 data
> events**. Object-level calls are data events and are invisible to Event history and to a
> default trail. If this returns nothing, that is a property of trail configuration, not
> evidence that nobody called S3 — and knowing the difference stops a false conclusion.

---

## Escalating the scenario

To show a **full outage** (ALB returns 503) rather than partial degradation, remove `web-a`'s
ingress rule so both targets fail:

```bash
SG_A=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${PREFIX}-web-a-sg" \
  --query "SecurityGroups[].GroupId" --output text)
SG_ALB=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${PREFIX}-alb-sg" \
  --query "SecurityGroups[].GroupId" --output text)

aws ec2 revoke-security-group-ingress --group-id "${SG_A}" \
  --protocol tcp --port 80 --source-group "${SG_ALB}"
```

Wait a minute, then `curl` the ALB — **503**. Restore with `authorize-security-group-ingress`
using the same arguments, or `terraform apply` to put it back.

This is also the most satisfying way to end Demo 4: apply the fix live and watch the target go
healthy while the class watches the metric move.

---

## Cost

| Component | Per day |
|-----------|---------|
| 3 × `t3.micro` | ~$0.75 |
| Application Load Balancer | ~$0.55 |
| CloudTrail data events, logs, S3, dashboard | pennies |
| **Default total** | **~$1.30** |
| NAT gateway, if enabled | +$1.10 |

The CloudWatch dashboard is free — AWS allows three per account at no charge.
