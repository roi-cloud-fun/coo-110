# Instructor: deploying the COO-110 lab environments

Terraform for the per-student AWS environments used by [Lab 1](../lab_1/README.md) and
[Lab 2](../lab_2/README.md). Every fault the labs ask students to diagnose is deliberately
injected here.

**This is the answer key.** The injected faults are listed below and commented in the `.tf`
files. That is intentional — you cannot run the day without knowing which faults are planted
and why — but it does mean a student who finds this folder has the answers. The lab guides
already show the expected output of every command, so it leaks less than it first appears.

---

## What one student gets

One `terraform apply` with `-var="student_id=NN"` builds about 58 resources in their own VPC
(`10.60.0.0/16`), isolated so one student's routing faults cannot affect anyone else.

| Resource | Name | Purpose |
|---|---|---|
| VPC, 2 public subnets, 1 private subnet | `cf110-NN-vpc` | Isolation per student |
| IGW, NAT gateway, route tables | `cf110-NN-nat` | NAT is healthy; the private route table is the Lab 2 Task 3 fault |
| **EC2 instance** | `cf110-NN-app` | **The only instance.** Serves all four instance-related tasks |
| Security group | `cf110-NN-app-sg` | Egress only, no ingress — the Lab 2 Task 4 fault |
| Security group | `cf110-NN-private-sg` | Attached to nothing; exists so Task 3 has a real object to rule out |
| EBS volume, gp2 | `cf110-NN-burst-volume` | gp2 specifically — `BurstBalance` does not exist on gp3 |
| Lambda + EventBridge rule | `cf110-NN-slow-function` | 30s timeout, sleeps up to 45s, invoked every minute |
| S3 bucket | `cf110-NN-target-XXXXXX` | Random suffix so students discover it rather than type it |
| ALB, target group, listener | `cf110-NN-alb` | Target reports `Target.Timeout` |
| IAM roles | `MyAppRole`, `SourceRole`, `TargetRole`, `CrossAccountRole`, `lab1-ec2-role` | Each carries an injected policy or trust fault |
| VPC flow logs | `/cf110/NN/vpc-flow-logs` | Evidence for Lab 2 Task 4 |

### One instance, four roles

Earlier versions ran three instances per student. They are now one, because only one ever
needed to be running:

- **Lab 1 Task 1** — its status checks are read. Both pass; the rule-out *is* the result
- **Lab 1 Task 4** — the gp2 burst volume attaches to it
- **Lab 2 Task 1** — its instance profile is `MyAppRole`, which students trace
- **Lab 2 Task 4** — it runs nginx and is the ALB's only target

---

## The injected faults

| Lab / Task | Fault | Where |
|---|---|---|
| L1 T1 | *None.* Status checks pass. Ruling the host layer out is the lesson | `lab1.tf` |
| L1 T2 | Lambda sleeps up to 45s against a 30s timeout | `lab1.tf` |
| L1 T3 | Role can `s3:ListBucket` but not `s3:GetObject` | `lab1.tf` |
| L1 T4 | Volume is gp2, so `BurstBalance` exists as a metric | `lab1.tf` |
| L2 T1 | `MyAppRole` missing `s3:GetObject` on the target bucket | `lab2.tf` |
| L2 T2 | `TargetRole` trust policy names the wrong principal | `lab2.tf` |
| L2 T3 | Private route table has **no** `0.0.0.0/0` route. The NAT exists and is healthy | `network.tf` |
| L2 T4 | `cf110-NN-app-sg` has **no ingress**, so ALB health probes never arrive | `lab1.tf` |

> **Two faults are defined by absence, not presence.** The missing route in `network.tf` and
> the missing ingress rule in `lab1.tf` are both "nothing is there". Adding either one while
> tidying up silently removes the fault, and the stack still applies cleanly — you find out
> when a student says the answer does not match. Both are commented in place.

---

## Prerequisites

- Terraform >= 1.5 and AWS CLI v2
- An AWS account you can create VPCs, EC2, ALBs, Lambda and IAM roles in
- Administrative credentials for the deploy (`AWS_PROFILE`)

### Student sign-in users are NOT created by this Terraform

This module builds the lab *resources*. It does not create the IAM users students sign in as.
You need one per student, named to match their `student_id` — `student_id=07` produces
resources called `cf110-07-*` and the student signs in as `user07`.

Create them separately:

```bash
aws iam create-group --group-name coo110-students
aws iam attach-group-policy --group-name coo110-students \
  --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess

for i in $(seq -w 1 12); do
  aws iam create-user --user-name "user${i}"
  aws iam add-user-to-group --group-name coo110-students --user-name "user${i}"
done
```

Set console passwords through the IAM console or your identity provider. Do not commit them.
`ReadOnlyAccess` plus CloudShell covers every command in both labs — students diagnose, they
do not remediate.

---

## Deploy

### One student

```bash
export AWS_PROFILE=your-profile
terraform init
terraform workspace new student-01
terraform apply -var="student_id=01" -var="region=us-east-1"
terraform output -raw student_handout
```

> **Workspaces are not optional.** State is local, so without a workspace per student the
> second apply treats the first student's resources as drift and destroys them.

### A whole class

`bin/deploy-students.sh` is sequential and easy to follow. `bin/deploy-parallel.sh` runs one
worker per region concurrently and is what you want beyond a handful. Both take
`<id>:<region>` pairs:

```bash
./bin/deploy-parallel.sh 01:us-east-1 02:us-east-2 03:us-west-2 04:us-east-1
```

Each writes `handout-NN.txt` and appends to `roster.txt`. A stack takes 4–6 minutes, so twelve
students across three regions land in about ten.

### Verify before class

```bash
./bin/verify-students.sh              # everything in roster.txt
./bin/verify-students.sh 01:us-east-1 # one student
```

This runs the same lookups the students run — 13 checks per stack, including confirming the
injected faults are actually present. A stack that passes is one whose guide commands return
what the guide says they return. Run it the morning of the class, not the night before.

---

## Capacity: NAT gateways are the ceiling

**10 students per region.** NAT gateways are limited to **10 per Availability Zone**, and every
student's NAT lands in the same AZ. That quota, not vCPUs, is what caps a class.

| Quota | Default limit | Binding? |
|---|---|---|
| NAT gateways per AZ | 10 | **Yes** |
| VPCs per region | 5 | Yes — request an increase |
| Elastic IPs per region | 5 | Yes — request an increase |
| Running on-demand vCPUs | 75 | No |

Spread across `us-east-1`, `us-east-2` and `us-west-2` and you can run 30. Beyond that, either
request a NAT quota increase or set `create_nat_gateway = false` for students who only need
Lab 1.

> **Tell students their region, and put it on the whiteboard.** The guides set
> `REGION=$AWS_REGION`, which CloudShell inherits from whichever region the console is showing.
> In the wrong region every command returns *nothing at all* rather than an error, which reads
> exactly like a missing resource. With a split cohort this is the single most likely way to
> lose ten minutes.

---

## Cost

Per student, per day, at defaults:

| Component | Cost |
|---|---|
| NAT gateway | ~$1.08 |
| ALB | ~$0.54 |
| t3.micro | ~$0.25 |
| 2 × public IPv4 | ~$0.24 |
| Flow logs, Lambda, CloudWatch | ~$0.20 |
| **Total** | **~$2.30** |

Twelve students is about **$28/day**. Setting `create_nat_gateway = false` removes roughly half.
**Destroy the same day** — the NAT gateway and ALB bill continuously whether anyone is signed
in or not.

```bash
./bin/deploy-students.sh destroy 01:us-east-1 02:us-east-2
```

---

## Known traps

**Renaming a security group can deadlock the apply.** Changing an SG's `name` forces
replacement, and AWS refuses to delete the old group while an instance's ENI still references
it, so the apply spins on `DependencyViolation` until it times out.
`aws_security_group.lab1_instance` therefore sets `create_before_destroy = true`.

That works *only because the rename also changes the name*. A security group's `description` is
immutable too — change it while leaving `name` alone and `create_before_destroy` collides with
itself, failing `InvalidGroup.Duplicate`. If you hit that: move the instance to another SG,
delete the stale group, re-apply.

**Do not run concurrent Terraform in this directory without separate `TF_DATA_DIR`s.** State is
per-workspace and safe; the provider cache is not. `deploy-parallel.sh` sets this for you.

**Google Drive corrupts `.terraform`.** If you keep this in a synced folder, copy it to a local
path before running Terraform, or you will get provider checksum errors on every `plan`.
