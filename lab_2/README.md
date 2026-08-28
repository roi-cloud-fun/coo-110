# Lab 2: AWS IAM and Network Troubleshooting

**Course:** AWS Troubleshooting Deep Dive
**Duration:** 60 minutes

---

## Overview

Every fault in Lab 1 lived inside a single resource. The four in this lab live *between* resources, which is what makes them harder: each component reports itself as healthy, and the fault only exists in the relationship. A role that is allowed to call `AssumeRole` still cannot assume a role that does not trust it back. A subnet with a working NAT gateway still has no internet if nothing routes to it. A web server returning `200` to itself is still unhealthy to a load balancer whose probes never arrive.

In all four cases the component you are told to suspect is fine. The evidence you need is on the other side of the relationship, and the discipline is to go and read it rather than to keep re-examining the thing that was reported.

## Objectives

By completing this lab, you will:

- Trace an `AccessDenied` from an EC2 instance profile through to the specific missing IAM action
- Read both halves of a role trust relationship and identify which half denies the call
- Distinguish a permissions policy failure from a trust policy failure by the error they produce
- Diagnose a private subnet with no internet egress by eliminating security groups, network ACLs, and the NAT gateway in turn
- Use VPC Flow Logs to prove that load balancer health checks are being rejected before they arrive
- Correlate a `Target.Timeout` health check reason with the security group rule that causes it
- Escalate a finding with the evidence an on-call engineer would need

---

## Before You Begin

This lab uses the same pre-deployed environment as Lab 1. **You create nothing** — every resource already exists in your own stack, and several carry a deliberately injected fault. Your job is to diagnose them.

**What you need:**

- [ ] Your student ID, and the handout your instructor issued for your stack
- [ ] AWS Console access with your lab IAM sign-in, set to **your** region (your handout names it)
- [ ] Your completed Lab 1 playbook entries — the method carries over

> **Check your region before anything else.** Students in this class are spread across more than
> one AWS region, so there is no single "class region" — your handout names yours, and it may not
> be the one the console opens in. Set the region selector in the top navigation bar to match your
> handout before you run a single command.
>
> This matters more than it sounds. CloudShell takes `AWS_REGION` from whichever region the
> console is showing, and every command in this lab uses it. In the wrong region they do not
> error — they return **nothing at all**, which reads exactly like a missing resource. If a
> command comes back empty, check the region before you check anything else.

**Already provisioned for you:**

| Resource | Name | Used in |
|----------|------|---------|
| IAM role — application identity | `cf110-01-MyAppRole` | Task 1 |
| IAM role — the caller | `cf110-01-SourceRole` | Task 2 |
| IAM role — the target | `cf110-01-TargetRole` | Task 2 |
| IAM role — Lab 1 EC2 role | `cf110-01-lab1-ec2-role` | Task 2 |
| EC2 instance in the private subnet | `cf110-01-lab2-private` | Task 3 |
| Private subnet and its route table | `cf110-01-private` | Task 3 |
| NAT gateway | `cf110-01-nat` | Task 3 |
| Application Load Balancer and target group | `cf110-01-alb`, `cf110-01-tg` | Task 4 |
| Target instance and its security group | `cf110-01-alb-target` | Task 4 |
| VPC Flow Logs log group | `/cf110/01/vpc-flow-logs` | Task 4 |

Substitute your own student ID for `01` throughout.

> **Note:** Your VPC uses the CIDR `10.60.0.0/16`. Several queries in this lab filter on addresses in that range. If your handout shows a different CIDR, adjust those filters — a query that filters on the wrong range returns zero rows and looks like a healthy result.

---

## Part 1: Access Faults

### Task 1: Trace an IAM AccessDenied

**Goal:** Take an application-level `AccessDenied` and narrow it to one missing action on one resource.

An application running on an EC2 instance reports `AccessDenied` when it reads from S3. The instance is running, the bucket exists, and the object is there. Start from the identity the application actually uses, not the one you assume it uses.

1. **Set your working variables.** Open CloudShell with the terminal icon (`>_`) in the top navigation bar.

    ```bash
    STUDENT_ID=01
    ```
    <!-- source: https://docs.aws.amazon.com/cloudshell/latest/userguide/working-with-aws-cli.html -->

    ```bash
    REGION=$AWS_REGION
    ```
    <!-- source: https://docs.aws.amazon.com/cloudshell/latest/userguide/working-with-aws-cli.html -->

    ```bash
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/sts/get-caller-identity.html -->

    ```bash
    BUCKET=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'cf110-${STUDENT_ID}-target')].Name" --output text)
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/s3api/list-buckets.html -->

    ```bash
    echo "account=${ACCOUNT} bucket=${BUCKET}"
    ```
    <!-- source: https://docs.aws.amazon.com/cloudshell/latest/userguide/working-with-aws-cli.html -->

    **Expected Result:** Both values print. If `BUCKET` is empty, your `STUDENT_ID` does not match your resource names.

> **Common Pitfall:** `STUDENT_ID`, `REGION`, `ACCOUNT` and `PRIVATE_ID` are used by every remaining task in this lab, and a CloudShell session drops its shell variables when it times out after a period of inactivity. If you take a break and return to find commands returning nothing — particularly in Task 3, which reuses `PRIVATE_ID` set in step 2 below — the variables are gone rather than the resources. Re-run steps 1 and 2 to restore them.
>
> An unset variable expands to an empty string rather than raising an error, so `--instance-ids ""` fails as though the instance were missing. If a command behaves as if a resource has vanished, echo the variable before investigating the resource.

2. **Find which role the application actually runs as.** Never assume — an instance profile is the only thing that determines an EC2 application's identity.

    ```bash
    PRIVATE_ID=$(aws ec2 describe-instances --region "${REGION}" --filters "Name=tag:Name,Values=cf110-${STUDENT_ID}-lab2-private" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].InstanceId" --output text)
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instances.html -->

    ```bash
    aws ec2 describe-instances --region "${REGION}" --instance-ids "${PRIVATE_ID}" --query "Reservations[].Instances[].IamInstanceProfile.Arn" --output text
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instances.html -->

    **Expected Result:** An instance profile ARN ending in `cf110-01-MyAppRole-profile`.

> **Key Insight:** An instance profile and the role inside it are two different objects that usually share a name. The application's permissions come from the **role**, so that is what you inspect and what you name in a Policy Simulator call. Passing an instance profile ARN where a role ARN is expected fails with a confusing error.

3. **Read the role's policies.**

    ```bash
    ROLE=cf110-${STUDENT_ID}-MyAppRole
    ```
    <!-- source: https://docs.aws.amazon.com/cloudshell/latest/userguide/working-with-aws-cli.html -->

    ```bash
    aws iam list-role-policies --role-name "${ROLE}" --output text
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/iam/list-role-policies.html -->

    ```bash
    aws iam list-attached-role-policies --role-name "${ROLE}" --query "AttachedPolicies[].PolicyName" --output text
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/iam/list-attached-role-policies.html -->

    **Expected Result:** One inline policy, `S3ListOnly`, and one attached managed policy, `AmazonSSMManagedInstanceCore`. Both matter — a role's effective permissions are the union of its inline and attached policies, and checking only one of the two is a common way to miss the answer.

4. **Confirm the gap with the Policy Simulator.**

    ```bash
    aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::${ACCOUNT}:role/${ROLE}" --action-names s3:GetObject --resource-arns "arn:aws:s3:::${BUCKET}/data/transactions.csv" --query "EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}" --output table
    ```
    <!-- source: https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html -->

    **Expected Result:**

    ```
    ----------------------------------
    |     SimulatePrincipalPolicy    |
    +---------------+----------------+
    |    Action     |   Decision     |
    +---------------+----------------+
    |  s3:GetObject |  implicitDeny  |
    +---------------+----------------+
    ```

> **Common Pitfall:** Simulate one action against one resource ARN at a time. If you pass several resource ARNs in a single call, the top-level `EvalDecision` collapses to the most restrictive result across all of them, and an action that is genuinely allowed on its correct resource is reported as `implicitDeny`. The call succeeds and the answer is wrong.

5. **Corroborate with CloudTrail.** The simulator tells you what *would* happen; CloudTrail tells you what *did*.

    ```bash
    aws cloudtrail lookup-events --region "${REGION}" --lookup-attributes AttributeKey=EventName,AttributeValue=GetObject --max-results 20 --query "Events[].{Time:EventTime,User:Username,Event:EventName}" --output table
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/cloudtrail/lookup-events.html -->

    **Expected Result:** A table of recent `GetObject` events, or an empty table. Both are acceptable findings here.

> **Note:** S3 object-level operations are **data events**, and CloudTrail does not record them unless data event logging is explicitly enabled on the trail. Management events such as `AssumeRole` are always recorded. If this lookup returns nothing, that is a property of the trail's configuration, not evidence that the application never called S3 — and knowing that difference stops you from drawing a false conclusion from an empty result. Task 2 uses `AssumeRole`, which *is* a management event and does appear.

6. **Record the fix.** The role needs `s3:GetObject` on the object ARN — note the `/*` suffix.

    **Expected Result:** Your notes name the role, the missing action, the correct resource ARN form, and the simulator output as evidence.

---

### Task 2: Diagnose a Failing Role Assumption

**Goal:** Determine which side of a trust relationship denies an `AssumeRole` call.

A scheduled job that assumes `TargetRole` has started failing. The team that owns the calling role insists its permissions are correct. They are right — and the call still fails.

Assuming a role requires **two** independent approvals:

- The **caller's** identity policy must allow `sts:AssumeRole` on the target role. This is the permissions half.
- The **target** role's trust policy must name the caller as a principal it accepts. This is the trust half.

Either one missing produces `AccessDenied`, and the error text barely distinguishes them. You must read both.

1. **Read the caller's permissions half.**

    ```bash
    aws iam get-role-policy --role-name cf110-${STUDENT_ID}-SourceRole --policy-name AllowAssumeTarget --query "PolicyDocument.Statement" --output json
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/iam/get-role-policy.html -->

    **Expected Result:** A statement allowing `sts:AssumeRole` on the ARN of `cf110-01-TargetRole`. The caller is permitted to *try*. This half is correct, so the fault is not here.

2. **Read the target's trust half.** This is the document that decides who may assume the role.

    ```bash
    aws iam get-role --role-name cf110-${STUDENT_ID}-TargetRole --query "Role.AssumeRolePolicyDocument.Statement[].Principal" --output json
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/iam/get-role.html -->

    **Expected Result:**

    ```json
    [
        {
            "AWS": "arn:aws:iam::123456789012:role/cf110-01-lab1-ec2-role"
        }
    ]
    ```

    The account ID is yours and the student ID is yours, but the shape is the point: the trusted principal is **`cf110-01-lab1-ec2-role`** — the Lab 1 EC2 role. It is not `cf110-01-SourceRole`.

3. **State the fault precisely.** `SourceRole` is allowed to call `AssumeRole`, and `TargetRole` does not accept `SourceRole`. The permissions half passes and the trust half fails, so the call is denied.

    **Expected Result:** You can name which of the two halves fails and cite the document that proves it.

> **Key Insight:** The error returned to the caller is `AccessDenied` in both cases, which is why engineers lose hours re-reading the caller's policy. A quick discriminator: if the caller's policy allows `sts:AssumeRole` on the exact target ARN and the call still fails, the fault is almost always on the trust side. Read the trust policy second, but read it every time.

4. **Find the denial in CloudTrail.** `AssumeRole` is a management event, so it is recorded whether or not data events are enabled.

    ```bash
    aws cloudtrail lookup-events --region "${REGION}" --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole --max-results 25 --query "Events[].{Time:EventTime,User:Username,Event:EventName}" --output table
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/cloudtrail/lookup-events.html -->

    **Expected Result:** Recent `AssumeRole` events. CloudTrail delivery lags by up to about 15 minutes, so a call made moments ago may not appear yet — absence here is not evidence of absence.

5. **Write the corrected trust policy.** The fix is one line: name `SourceRole` as the trusted principal.

    ```json
    {
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {
          "AWS": "arn:aws:iam::ACCOUNT-ID:role/cf110-01-SourceRole"
        },
        "Action": "sts:AssumeRole"
      }]
    }
    ```
    <!-- source: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_principal.html -->

    **Expected Result:** Your notes carry the corrected document with your own account ID and student ID substituted.

> **Common Pitfall:** Writing the principal as the account root (`arn:aws:iam::ACCOUNT-ID:root`) also makes the call succeed, and it is the wrong fix. Trusting the root principal delegates the decision to that entire account — any identity in it that is granted `sts:AssumeRole` can then assume your role. Name the specific role ARN.

> **Note:** A third mechanism can deny an assumption even when both halves are correct: an **external ID**, used by third-party integrations to prevent the confused-deputy problem. If a trust policy carries a `sts:ExternalId` condition, the caller must supply a matching value. There is no external ID in this environment — confirming its absence in the trust document you read in step 2 is another rule-out.

---

## Part 2: Network Faults

### Task 3: Restore Egress from a Private Subnet

**Goal:** Find why an instance in a private subnet cannot reach the internet, eliminating each candidate in turn.

A batch worker in the private subnet cannot download its dependencies. Four things could be responsible: the security group, the network ACL, the NAT gateway, or the route table. Check them in that order and the answer arrives by elimination.

1. **Identify the instance and its subnet.**

    ```bash
    SUBNET=$(aws ec2 describe-instances --region "${REGION}" --instance-ids "${PRIVATE_ID}" --query "Reservations[].Instances[].SubnetId" --output text)
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instances.html -->

    ```bash
    echo "instance=${PRIVATE_ID} subnet=${SUBNET}"
    ```
    <!-- source: https://docs.aws.amazon.com/cloudshell/latest/userguide/working-with-aws-cli.html -->

    **Expected Result:** Both values print, for example `instance=i-0a1b2c3d4e5f67890 subnet=subnet-0a1b2c3d4e5f67890`.

2. **Rule out the security group.** Outbound traffic is governed by egress rules.

    ```bash
    aws ec2 describe-security-groups --region "${REGION}" --filters "Name=group-name,Values=cf110-${STUDENT_ID}-lab2-private-sg" --query "SecurityGroups[].IpPermissionsEgress" --output json
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-security-groups.html -->

    **Expected Result:** One rule allowing all protocols (`IpProtocol: "-1"`) to `0.0.0.0/0`. Egress is fully open, so the security group is **not** the fault.

> **Key Insight:** Security groups are stateful — a permitted outbound request has its reply admitted automatically, with no matching inbound rule required. This is why an instance with no inbound rules at all can still make outbound calls, and why an empty inbound list is not evidence of an egress problem.

3. **Rule out the network ACL.** Unlike security groups, NACLs are stateless and apply at the subnet boundary.

    ```bash
    aws ec2 describe-network-acls --region "${REGION}" --filters "Name=association.subnet-id,Values=${SUBNET}" --query "NetworkAcls[].Entries[].{Rule:RuleNumber,Proto:Protocol,Action:RuleAction,Cidr:CidrBlock,Egress:Egress}" --output table
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-network-acls.html -->

    **Expected Result:** The default NACL: rule `100` allowing all traffic in each direction, and rule `32767` denying all. Because rules are evaluated lowest number first, rule 100 permits the traffic and the deny is never reached. The NACL is **not** the fault.

> **Common Pitfall:** Because NACLs are stateless, a custom NACL must allow the **return** traffic explicitly, on the ephemeral port range (1024–65535). A NACL that permits outbound 443 but no inbound ephemeral range blocks every reply, and the symptom looks exactly like a routing failure. That is not what is happening here, but it is the reason NACLs are worth ruling out rather than assuming.

4. **Rule out the NAT gateway.** A NAT gateway that is missing or unhealthy would explain the symptom.

    ```bash
    aws ec2 describe-nat-gateways --region "${REGION}" --filter "Name=state,Values=available" --query "NatGateways[].{Id:NatGatewayId,State:State,Subnet:SubnetId}" --output table
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-nat-gateways.html -->

    **Expected Result:** One NAT gateway in state `available`, sitting in a **public** subnet. It exists and it is healthy, so the NAT gateway is **not** the fault.

> **Key Insight:** A NAT gateway must live in a *public* subnet — one whose route table sends `0.0.0.0/0` to an internet gateway. A NAT gateway placed in the private subnet it is meant to serve cannot reach the internet itself, and creates a routing loop. Confirming which subnet it occupies is part of ruling it out.

5. **Read the route table.** Three candidates are eliminated; this is the fourth.

    ```bash
    aws ec2 describe-route-tables --region "${REGION}" --filters "Name=association.subnet-id,Values=${SUBNET}" --query "RouteTables[].Routes[].{Dest:DestinationCidrBlock,Gateway:GatewayId,Nat:NatGatewayId,State:State}" --output table
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-route-tables.html -->

    **Expected Result:**

    ```
    ----------------------------------------------
    |             DescribeRouteTables            |
    +---------------+-------+---------+----------+
    |     Dest      |  Nat  |  State  | Target   |
    +---------------+-------+---------+----------+
    |  10.60.0.0/16 |  None |  active |  local   |
    +---------------+-------+---------+----------+
    ```

    **Exactly one route.** The `local` route carries traffic within the VPC, and there is no `0.0.0.0/0` entry at all. Any packet addressed outside `10.60.0.0/16` has nowhere to go and is discarded.

6. **State the fault and the fix.**

    **Expected Result:** The private route table is missing a default route to the NAT gateway. The fix adds one route — destination `0.0.0.0/0`, target the NAT gateway ID from step 4 — to the route table associated with the private subnet.

> **Key Insight:** This fault is invisible from the instance. There is no error message and no rejected packet to find in a log; traffic addressed outside the VPC simply has no matching route and is dropped. A missing route is diagnosed by *reading the routing table*, never by looking harder at the host. That is the opposite of Task 4, where the fault leaves an explicit trail.

---

### Task 4: Diagnose Failing ALB Health Checks

**Goal:** Explain why a load balancer reports a healthy web server as unhealthy, and prove it with flow logs.

The load balancer in front of the web tier reports its target as unhealthy. The web server is running and serves a page correctly when tested locally.

1. **Read the target's health and, critically, its reason code.**

    ```bash
    TG=$(aws elbv2 describe-target-groups --region "${REGION}" --names cf110-${STUDENT_ID}-tg --query "TargetGroups[].TargetGroupArn" --output text)
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/elbv2/describe-target-groups.html -->

    ```bash
    aws elbv2 describe-target-health --region "${REGION}" --target-group-arn "${TG}" --query "TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}" --output table
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/elbv2/describe-target-health.html -->

    **Expected Result:** State `unhealthy`, reason `Target.Timeout`, description `Request timed out`.

> **Key Insight:** The reason code is the diagnosis, not decoration. `Target.Timeout` means the probe got **no answer at all** — the connection never completed. `Target.ResponseCodeMismatch` means the server answered with the wrong status code, which is an application problem. `Target.FailedHealthChecks` is the generic case. A timeout points at the network path; a code mismatch points at the application. Reading the reason first tells you which half of the stack to investigate and saves you from debugging a web server that is working perfectly.

2. **Confirm the health check configuration is sane** before suspecting the network.

    ```bash
    aws elbv2 describe-target-groups --region "${REGION}" --target-group-arns "${TG}" --query "TargetGroups[].{Path:HealthCheckPath,Port:HealthCheckPort,Protocol:HealthCheckProtocol,Matcher:Matcher.HttpCode,Timeout:HealthCheckTimeoutSeconds,Interval:HealthCheckIntervalSeconds}" --output table
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/elbv2/describe-target-groups.html -->

    **Expected Result:** Path `/`, protocol `HTTP`, port `traffic-port`, matcher `200`, timeout `5` seconds, interval `30` seconds. The configuration is correct — it is probing the right path for the right response — so the fault is not a misconfigured health check.

3. **Read the target's inbound rules.**

    ```bash
    aws ec2 describe-security-groups --region "${REGION}" --filters "Name=group-name,Values=cf110-${STUDENT_ID}-alb-target-sg" --query "SecurityGroups[].{Name:GroupName,Id:GroupId,Ingress:IpPermissions}" --output json
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-security-groups.html -->

    **Expected Result:**

    ```json
    [
        {
            "Name": "cf110-01-alb-target-sg",
            "Id": "sg-0a1b2c3d4e5f67890",
            "Ingress": []
        }
    ]
    ```

    The ingress list is **empty**. Nothing at all may connect to this instance — including the load balancer's health probes.

4. **Prove it from the network's own record.** A security group rejection is visible in VPC Flow Logs, which is what turns a hypothesis into evidence.

    In the CloudWatch console expand **Logs** in the left navigation pane and choose **Log Analytics** — this is what replaced Logs Insights in 2026, so there is no menu item by the old name. Choose **Browse**, tick `/cf110/01/vpc-flow-logs` in the dialog and apply it, then choose the **30m** time-range button.

    Leaving the prefilled `SOURCE` line at the top of the editor in place, replace the lines beneath it with:

    ```
    fields @timestamp, srcAddr, dstAddr, srcPort, dstPort, action
    | filter dstPort = 80 and action = 'REJECT'
    | sort @timestamp desc
    | limit 50
    ```
    <!-- source: https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-cwl.html -->

    Choose **Run**, or press `Ctrl+Enter`.

    **Expected Result:** Rows of rejected traffic to port 80, roughly two every 30 seconds — the health check interval, multiplied by the load balancer's nodes in each Availability Zone:

    ```
    @timestamp                srcAddr       dstAddr       srcPort  dstPort  action
    2026-08-22 22:41:16.000   10.60.1.130   10.60.0.145   53894    80       REJECT
    2026-08-22 22:41:16.000   10.60.0.157   10.60.0.145   28684    80       REJECT
    2026-08-22 22:40:16.000   10.60.0.157   10.60.0.145   53834    80       REJECT
    ```

    The source addresses are the load balancer's network interfaces in your two public subnets. The destination is your target instance. Every probe is rejected before the web server ever sees it.

> **Common Pitfall:** Do not add a `srcAddr` filter unless you have confirmed the actual address range. A filter such as `filter srcAddr like /10\.0\./` matches nothing in a `10.60.0.0/16` VPC, because no address in that range contains the literal text `10.0.` — and the query still reports success while returning zero rows. An empty Logs Insights result is ambiguous by nature: it means "no matching records," which is equally consistent with a healthy system and with a filter that cannot match anything. Always run the query without the narrow filter first, confirm rows exist, and only then narrow.

5. **Correlate the two findings.** The `REJECT` records name the source addresses; the security group explains why they were rejected.

    **Expected Result:** You can state the causal chain in one sentence: the target security group has no inbound rule permitting the ALB's security group on port 80, so probes are dropped at the boundary, so the target times out and is marked unhealthy.

6. **Record the fix.** Add one inbound rule to the target security group: protocol TCP, port 80, source the **ALB's security group ID** — not a CIDR range.

    **Expected Result:** Your notes name the rule to add and the security group to add it to.

> **Key Insight:** Reference the load balancer's security group as the source, rather than a CIDR block. A load balancer's private addresses are assigned from the subnet pool and change when it scales or is replaced, so a CIDR-based rule either breaks later or is written so wide that it admits the whole subnet. A security-group reference keeps working and stays narrow.

---

## Part 3: Escalation and Documentation

### Task 5: Escalate and Document

**Goal:** Convert four investigations into records and one escalation another engineer can act on immediately.

> **Note:** The severity criteria below follow standard ITIL incident priority definitions. Substitute your organisation's own escalation procedure and severity ladder wherever they differ.

1. **Record each finding** using the playbook template from Lab 1. All four faults in this lab are real; unlike Lab 1, there are no "no fault found" outcomes.

    | Task | Root cause | Fix |
    |------|-----------|-----|
    | 1 — IAM AccessDenied | `MyAppRole` grants `s3:ListBucket` but never `s3:GetObject` | Add `s3:GetObject` on the object ARN (`.../*`) |
    | 2 — AssumeRole denied | `TargetRole` trusts the Lab 1 EC2 role, not `SourceRole` | Correct the trust policy to name `SourceRole`'s ARN |
    | 3 — No private egress | Private route table has no `0.0.0.0/0` route | Add a default route to the NAT gateway |
    | 4 — ALB targets unhealthy | Target security group has no ingress from the ALB security group on port 80 | Add TCP/80 ingress referencing the ALB security group |

2. **Choose one finding to escalate** and classify its severity.

    | Severity | Criteria | Escalation path |
    |----------|----------|-----------------|
    | Critical | Production system down, or data loss risk | Immediate page to on-call |
    | High | Significant degradation, workaround exists | Notify team lead within 1 hour |
    | Medium | Single user or service affected | Create ticket, assign to queue |
    | Low | Minor issue, no immediate impact | Document for next business day |

    **Expected Result:** A defensible severity with a stated reason. The ALB fault is the strongest candidate for the highest severity — with every target unhealthy the load balancer has nothing to route to, so the service is entirely unavailable rather than degraded.

3. **Write the escalation.** Include the evidence, not just the conclusion.

    **Expected Result:** Your escalation contains the affected resource identifiers, the exact command output or flow-log rows that demonstrate the fault, the root cause, the proposed fix, and what you have already ruled out. The last item matters most: it stops the receiving engineer from repeating the elimination work you have already done.

> **Key Insight:** Three of these four faults were in a component nobody reported. The ticket named the application, the batch worker, and the web server; the faults were in a trust policy, a route table, and a security group. An escalation that says only "the web server is down" sends the next engineer to the wrong machine. Name the component you proved is at fault, and list the ones you cleared.

---

## Troubleshooting Reference

| Issue | Symptom | Solution |
|-------|---------|----------|
| Variables empty | `echo` prints nothing after `=` | `STUDENT_ID` does not match your resource names — check your handout, it is `01`, not `user01` |
| Wrong region | Resource lookups return nothing | Confirm the region selector matches your class region; CloudShell sets `AWS_REGION` for you |
| Simulator denies everything | Even actions you expect to pass report `implicitDeny` | Simulate one action against one resource ARN. Multiple ARNs collapse the top-level decision to the most restrictive result |
| Simulator errors on the ARN | `Invalid Entity Arn` | You passed the instance profile ARN. Use the **role** ARN — the two differ despite the similar name |
| CloudTrail shows no `GetObject` | Lookup returns an empty table | S3 object operations are data events and are not logged unless enabled on the trail. This is expected, not a fault |
| CloudTrail missing a recent call | The event you just triggered is absent | Delivery lags up to about 15 minutes. Wait and retry |
| Flow log query returns nothing | Query succeeds, zero rows | Remove any `srcAddr` filter and re-run. The VPC is `10.60.0.0/16`, so a filter written for `10.0.` matches nothing |
| Flow logs have no recent data | Log group exists but is empty | Flow logs are aggregated and delivered on an interval of up to 10 minutes. Wait and retry |
| Target still unhealthy after a fix | Health state does not change immediately | The target group needs 2 consecutive passing checks at 30-second intervals — allow about a minute |
| Cannot find Logs Insights | Not visible in the CloudWatch navigation pane | It no longer exists under that name. Expand **Logs** and choose **Log Analytics**, which replaced it in 2026. Log groups now live under **Log Management** |
| Unexpected dialog on first query | A panel describes a "new Log Analytics experience" | Choose **OK**. Every query in this lab works in either editor; **Opt out (Logs Insights)** returns you to the classic one |

## Next Steps

You have now worked all four fault domains this course covers — compute, storage, identity, and network — and the method never changed: establish a baseline, eliminate layers with evidence, read the error precisely enough to tell similar failures apart, and record what you ruled out alongside what you found.

Nothing about that method is specific to the services covered today. The next time you meet a service this course never mentioned, the sequence is the same; only the evidence sources change.

Take the playbook entries from both labs back to your own environment — they are the deliverable that outlives the class. Running one real ticket through the same template in the week after the course is the single most effective way to make the habit stick.

**CF-111: Incident Response Labs** applies this method to full-scenario incidents, where several of these faults present at once and you have to decide what to investigate first.

---

## Resources

- [Troubleshoot access denied error messages in Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/troubleshoot-403-errors.html)
- [Testing IAM policies with the Policy Simulator](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html)
- [How to use trust policies with IAM roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_terms-and-concepts.html)
- [IAM JSON policy elements: Principal](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_principal.html)
- [Route tables for your VPC](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html)
- [NAT gateways](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html)
- [Compare security groups and network ACLs](https://docs.aws.amazon.com/vpc/latest/userguide/infrastructure-security.html)
- [Target group health checks for Application Load Balancers](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html)
- [Publishing VPC flow logs to CloudWatch Logs](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-cwl.html)

---

*Lab 2 Complete*
