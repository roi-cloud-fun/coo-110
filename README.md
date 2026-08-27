# COO-110 — AWS Troubleshooting Deep Dive

Lab guides for ROI Training's COO-110 course. Two hands-on labs that teach a repeatable method
for diagnosing AWS faults: **establish a baseline, eliminate layers with evidence, and name the
component you can prove is at fault.**

Each student gets their own AWS stack (prefix `cf110-<student_id>-` on every named resource)
deployed **broken on purpose**. Students create nothing — they diagnose what is already there.

## What's where

```
coo-110/
├── lab_1/README.md   AWS Compute and Storage Troubleshooting  (60 min)
├── lab_2/README.md   AWS IAM and Network Troubleshooting      (60 min)
└── demo/             Instructor demo environment - Terraform + runbook
    ├── README.md     Deploy instructions and the five chapter demos
    ├── *.tf          One application, deployed broken on purpose
    └── scripts/      Lambda source for the injected timeout fault
```

**Students** need only `lab_1/` and `lab_2/` — their environment is deployed for them and they
never run Terraform.

**Instructors** deploy [`demo/`](demo/README.md) once for the front of the room. It stands up
"OrderFlow", a small order-processing app carrying one injected fault per chapter, with VPC Flow
Logs, CloudTrail, a CloudWatch dashboard and alarms wired around it — so every chapter demo runs
against real infrastructure instead of placeholder commands. Roughly $1.30/day; `terraform
destroy` when done.

## The two labs

| Lab | Focus | Faults |
|-----|-------|--------|
| **[Lab 1](lab_1/README.md)** | EC2 status checks, Lambda timeouts, S3 access, EBS performance | 2 real, **2 deliberate non-faults** |
| **[Lab 2](lab_2/README.md)** | IAM policy evaluation, role trust, VPC routing, ALB health | 4 real, none in the reported component |

### What makes these different

**Two of the four investigations in Lab 1 conclude that nothing is wrong.**

That is deliberate and it is the hardest idea in the course. Engineers are trained to keep
digging until they find something, and a large share of real operational time goes on hunting
faults that were never there. Closing an investigation with defensible evidence — "here is what
I checked, here is why nothing is wrong" — is a result, not a failure. Brief this before Lab 1
or students will assume they have made a mistake.

**In Lab 2 the fault is never in the component that was reported.** A role permitted to call
`AssumeRole` still cannot assume a role that does not trust it back. A subnet with a healthy NAT
gateway still has no internet if nothing routes to it. A web server returning `200` to itself is
still unhealthy to a load balancer whose probes never arrive.

## The environment students diagnose

```
              Application Load Balancer  (public subnets, 2 AZs)
                          │
                          ▼
              cf110-NN-alb-target        Lab 2 · Task 4
              nginx serving 200 locally, target SG has NO ingress
              from the ALB SG → Target.Timeout, REJECTs in flow logs

   cf110-NN-lab1-target                  Lab 1 · Tasks 1, 4
   status checks ok/ok (rule-out) + 1 GiB gp2 volume, burst full (rule-out)

   cf110-NN-slow-function                Lab 1 · Task 2
   30 s timeout, downstream call sometimes takes 45 s, invoked once a minute

   cf110-NN-target-<suffix>              Lab 1 · Task 3 · Lab 2 · Task 1
   S3 bucket. Roles granted s3:ListBucket but never s3:GetObject

   cf110-NN-lab2-private  (private subnet)   Lab 2 · Task 3
   SG egress open, NACL default, NAT healthy — route table has NO 0.0.0.0/0

   IAM: MyAppRole · SourceRole · TargetRole  Lab 2 · Task 2
   TargetRole's trust policy names the wrong principal

   VPC Flow Logs (10.60.0.0/16) → CloudWatch Logs
```

| Lab · Task | Injected fault | What students find |
|------------|----------------|--------------------|
| 1 · 1 | *None — not injectable* | `SystemStatus: ok`, `InstanceStatus: ok`. Host and guest layers excluded |
| 1 · 2 | Lambda 30 s timeout vs a 45 s call | `@duration` pinned at `30000` on roughly 1 invocation in 3 |
| 1 · 3 | Role granted `ListBucket`, never `GetObject` | `s3 ls` succeeds, `s3 cp` denied; simulator returns `implicitDeny` |
| 1 · 4 | *None — burst not depleted* | `BurstBalance` ~100 %, `VolumeQueueLength` ~0 |
| 2 · 1 | `MyAppRole` denied `s3:GetObject` | Same asymmetry, traced from the instance profile |
| 2 · 2 | `TargetRole` trusts the wrong principal | Caller may try; target refuses. Same `AccessDenied` text |
| 2 · 3 | Private route table has no default route | Exactly one route: `10.60.0.0/16 local` |
| 2 · 4 | Target SG has no ingress from the ALB SG | `Target.Timeout` + REJECT records on port 80 |

## What students need

- The AWS Console, in the lab region, signed in as their own IAM user
- Their student ID and the handout the instructor issues (instance IDs, bucket name, role ARNs)
- No local tooling — every command runs in CloudShell

Permissions, all read-only except where a lab applies a fix:

```
ec2:Describe*                       ec2:GetConsoleOutput
cloudwatch:GetMetricStatistics      lambda:GetFunctionConfiguration
s3:ListBucket  s3:ListAllMyBuckets  s3:GetBucketPolicy
logs:StartQuery  logs:GetQueryResults  logs:DescribeLogGroups
iam:GetRole  iam:GetRolePolicy  iam:ListRolePolicies
iam:ListAttachedRolePolicies        iam:SimulatePrincipalPolicy
elasticloadbalancing:DescribeTargetGroups + DescribeTargetHealth
cloudtrail:LookupEvents
```

## Console navigation changed in 2026

Two names in most published AWS documentation are now wrong, and both appear in these labs:

| Older docs say | Current console |
|----------------|-----------------|
| CloudWatch → **Logs Insights** | CloudWatch → **Logs** → **Log Analytics** |
| EC2 instance → **Status checks** tab | EC2 instance → **Status and alarms** tab |

Log Analytics replaced Logs Insights and unified it with Live Tail and Contributor Insights.
Opening it for the first time raises a dialog offering **OK** / **Opt out (Logs Insights)** —
choose OK. The query language is identical either way.

## Three commands that succeed while telling you the opposite of the truth

Each is flagged where it appears, but the pattern is worth knowing up front:

1. **A Logs query filtered on the wrong text returns zero rows and reports success.** Searching
   Lambda logs for `Task timed out` finds nothing on the Python 3.12 runtime — timeouts are
   recorded as `Status: timeout` on the REPORT line.
2. **A flow-log query filtered on the wrong CIDR does the same.** The lab VPC is
   `10.60.0.0/16`; a filter written for `10.0.` matches nothing.
3. **`simulate-principal-policy` with several resource ARNs collapses its verdict** to the most
   restrictive result across all of them, so an action that is genuinely allowed reports
   `implicitDeny`. Simulate one action against one resource ARN.

The habit: **an empty result is ambiguous by nature.** It means "no matching records", which is
equally consistent with a healthy system and with a query that could never have matched.

## Status

**Live-tested 2026-08-24** against a real training account. Every command in both guides was
executed and its actual output is what appears as the printed **Expected Result** — nothing is
invented.

| Check | Result |
|-------|--------|
| Lab commands executed verbatim against live AWS | 27 / 27 |
| CloudWatch Log Analytics queries returning rows | 4 / 4 |
| Automated environment suite (Playwright) | 20 passed, 2 skipped (manual doc tasks) |
| Console navigation claims | 2 / 2 |
| Validation gates (format, citations, URLs, walkthrough, setup gaps) | 8 / 8 |

Every command carries an HTML comment citing the AWS documentation page it came from. Those
render invisibly on GitHub but are present in the raw markdown.
