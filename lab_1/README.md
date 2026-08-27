# Lab 1: AWS Compute and Storage Troubleshooting

**Course:** AWS Troubleshooting Deep Dive
**Duration:** 60 minutes

---

## Overview

A payments service is behaving badly and nobody can tell you why. You have four reports on your queue: an instance somebody wants "checked," a Lambda function that fails often enough to page but not often enough to be obvious, an application that can list an S3 bucket but cannot read from it, and a volume somebody blames for being slow. None of the reports tell you where the fault is — that is your job.

The discipline in this lab is not memorising commands. It is proving where a fault *is not*, one layer at a time, until only one explanation survives. Two of these four reports turn out to have nothing wrong with them. Deciding that confidently, and being able to show why, is as much a result as finding a broken policy.

## Objectives

By completing this lab, you will:

- Read EC2 status checks and separate an AWS infrastructure fault from a guest operating system fault
- Rule a layer out with evidence, rather than assuming it is healthy
- Use CloudWatch Log Analytics to find the pattern behind an intermittent Lambda timeout
- Compare a function's configured timeout against its measured duration to explain the failure
- Diagnose an S3 `AccessDenied` down to the specific IAM action that is missing
- Read `BurstBalance` and `VolumeQueueLength` to judge whether a gp2 volume is genuinely throttled
- Record findings in a troubleshooting playbook another engineer could act on

---

## Before You Begin

The lab environment is deployed before class. **You create nothing** — every resource already exists in your own stack, and some carry a deliberately injected fault. Your job is to work out which ones.

**What you need:**

- [ ] Your student ID, and the handout your instructor issued for your stack
- [ ] AWS Console access with your lab IAM sign-in, in the class region
- [ ] Somewhere to record findings — you build four playbook entries as you go

**Already provisioned for you:**

| Resource | Name | Used in |
|----------|------|---------|
| EC2 instance | `cf110-01-lab1-target` | Task 1 |
| Lambda function and its log group | `cf110-01-slow-function` | Task 2 |
| IAM role for the S3 investigation | `cf110-01-CrossAccountRole` | Task 3 |
| S3 bucket with fixture objects | `cf110-01-target-<suffix>` | Task 3 |
| gp2 EBS volume attached at `/dev/sdf` | `cf110-01-lab1-burst-volume` | Task 4 |

The bucket carries a random six-character suffix, so you discover it rather than type it.

> **Note:** Substitute your own student ID wherever this guide shows `01`, and your own resource IDs wherever it shows an example like `i-0a1b2c3d4e5f67890`. Instance and volume IDs differ for every student and change every time the environment is rebuilt. Other students share this account, so confirm the student ID in a resource name matches yours before you touch it.

---

## Part 1: Establish a Baseline

### Task 1: Read the EC2 Status Checks

**Goal:** Determine whether the reported instance has an infrastructure fault, a guest fault, or no fault at all — and be able to prove which.

A ticket that says "check this instance" is not a diagnosis. Before you look at anything inside the instance, EC2 runs its own checks, and the two that matter most divide the whole problem space in half.

- **System status** — reports on **AWS's** infrastructure underneath your instance: host hardware, host networking, power. If this fails, nothing you do inside the guest fixes it; the remedy is to stop and start the instance so it lands on new hardware. The underlying CloudWatch metric is `StatusCheckFailed_System`.
- **Instance status** — reports on **your** guest operating system: kernel panic, exhausted disk, a corrupt `/etc/fstab`, a failed network stack. If this fails, the fix is inside the instance. The metric is `StatusCheckFailed_Instance`.

The console shows two more alongside them. **EBS status** covers the attached volumes, and **Application status** is a newer check that only reports if something has been associated with it — expect `None associated` here. Neither is used in this lab, but knowing they exist stops you wondering which of four results you are supposed to be reading.

1. **Open the EC2 console.** Type `ec2` in the console search bar and choose **EC2**. In the left navigation pane, choose **Instances**.
    <!-- source: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/monitoring-system-instance-status-check.html -->

2. **Filter to your instance.** In the search box above the instance table, type `cf110-01-lab1-target`, substituting your student ID.

    **Expected Result:** Exactly one instance, with **Instance state** showing `Running`.

3. **Read the checks.** Select the instance and open the **Status and alarms** tab, then look at the **Status checks** section at the top.

    **Expected Result:** Four rows, each with its own verdict:

    | Check | Reads |
    |-------|-------|
    | **System status** | `Check passed` |
    | **Instance status** | `Check passed` |
    | **EBS status** | `Check passed` |
    | **Application status - new** | `None associated or included` |

    The first two are the ones this task is about. Record what you see — a baseline is only useful if you wrote it down.

> **Common Pitfall:** In the 2026 console these checks live on the **Status and alarms** tab, inside a **Status checks** section. Older documentation and screenshots refer to a **Status checks** *tab*, which no longer exists — and they name the individual rows "System status check" and "Instance status check", where the console now says simply **System status** and **Instance status**. The concepts and the CloudWatch metric names are unchanged; only the console labels moved.

4. **Confirm the same result from the CLI.** Open CloudShell with the terminal icon (`>_`) in the top navigation bar, then set your working variables.

    ```bash
    STUDENT_ID=01
    ```
    <!-- source: https://docs.aws.amazon.com/cloudshell/latest/userguide/working-with-aws-cli.html -->

    ```bash
    REGION=$AWS_REGION
    ```
    <!-- source: https://docs.aws.amazon.com/cloudshell/latest/userguide/working-with-aws-cli.html -->

    ```bash
    INSTANCE_ID=$(aws ec2 describe-instances --region "${REGION}" --filters "Name=tag:Name,Values=cf110-${STUDENT_ID}-lab1-target" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].InstanceId" --output text)
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instances.html -->

    ```bash
    echo "instance=${INSTANCE_ID}"
    ```
    <!-- source: https://docs.aws.amazon.com/cloudshell/latest/userguide/working-with-aws-cli.html -->

    **Expected Result:** One instance ID, for example `instance=i-0a1b2c3d4e5f67890`. If this prints `instance=` with nothing after it, your `STUDENT_ID` does not match your resource names — fix that before continuing, because every later command depends on it.

> **Common Pitfall:** `STUDENT_ID` and `REGION` are used by every remaining task in this lab, and a CloudShell session drops its shell variables when it times out after a period of inactivity. If you take a break and come back to find commands returning nothing, or errors naming an empty resource, the variables are gone rather than the resources. Re-run this block to restore them:
>
> ```bash
> STUDENT_ID=01
> REGION=$AWS_REGION
> INSTANCE_ID=$(aws ec2 describe-instances --region "${REGION}" --filters "Name=tag:Name,Values=cf110-${STUDENT_ID}-lab1-target" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].InstanceId" --output text)
> ```
>
> An unset variable expands to an empty string rather than raising an error, which is why the failure looks like a missing resource instead of a missing variable.

5. **Query both status checks directly.**

    ```bash
    aws ec2 describe-instance-status --region "${REGION}" --instance-ids "${INSTANCE_ID}" --query "InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status,State:InstanceState.Name}" --output table
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instance-status.html -->

    **Expected Result:**

    ```
    -------------------------------------
    |       DescribeInstanceStatus      |
    +----------+----------+-------------+
    | Instance |  State   |   System    |
    +----------+----------+-------------+
    |  ok      |  running |  ok         |
    +----------+----------+-------------+
    ```

6. **Record the finding.** Both checks report `ok`. The instance is healthy at both the infrastructure and guest layers.

    **Expected Result:** You can state, with evidence, that the reported instance has no status-check fault. Write the command output into your playbook in Task 5 — "I checked and it was fine" is not evidence; the table above is.

> **Key Insight:** This is a real outcome, not a trick. A large share of production troubleshooting ends with "this layer is healthy, so the fault is elsewhere." The value of Task 1 is that you can now *exclude* host hardware and guest OS from every hypothesis you form in Tasks 2 through 4, and you can show the evidence that lets you exclude them.

> **Note:** `StatusCheckFailed_System` reports on hardware AWS owns. It cannot be triggered on demand, which is exactly why this instance is healthy — a lab cannot manufacture an AWS hardware failure. What you *can* rehearse is the decision procedure: if the system check had failed, you would stop and start the instance to move it to new hardware; if the instance check had failed, you would look inside the guest at boot logs and `/etc/fstab`. A reboot alone fixes neither, because it keeps the instance on the same host.

7. **Read the boot output**, the evidence you would rely on if the *instance* check had failed.

    ```bash
    aws ec2 get-console-output --region "${REGION}" --instance-id "${INSTANCE_ID}" --output text | tail -20
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/get-console-output.html -->

    **Expected Result:** Kernel and boot messages ending in a normal startup, with no panic or mount failure. On a recently launched instance this can be empty for the first few minutes — that is timing, not a fault.

---

## Part 2: An Intermittent Compute Fault

### Task 2: Diagnose the Lambda Timeout

**Goal:** Explain why a function fails *sometimes*, using its measured duration against its configured ceiling.

The `cf110-01-slow-function` Lambda is invoked once a minute by an EventBridge rule, so by the time you reach this task there is already a history of both successes and failures to read. Intermittent is the hard case: an always-broken function is a one-glance fix, while this one forces you to find the pattern.

1. **Read the configured timeout first.** The ceiling is the number every later measurement is judged against.

    ```bash
    FN=cf110-${STUDENT_ID}-slow-function
    ```
    <!-- source: https://docs.aws.amazon.com/cloudshell/latest/userguide/working-with-aws-cli.html -->

    ```bash
    aws lambda get-function-configuration --region "${REGION}" --function-name "${FN}" --query "{Timeout:Timeout,Memory:MemorySize,Runtime:Runtime}" --output table
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/lambda/get-function-configuration.html -->

    **Expected Result:**

    ```
    ---------------------------------------
    |      GetFunctionConfiguration       |
    +----------+------------+-------------+
    |  Memory  |  Runtime   |  Timeout    |
    +----------+------------+-------------+
    |  128     |  python3.12|  30         |
    +----------+------------+-------------+
    ```

    The timeout is **30 seconds**. Hold on to that number.

2. **Open the log query editor.** Type `cloudwatch` in the console search bar and choose **CloudWatch**. In the left navigation pane, expand **Logs**, then choose **Log Analytics**.
    <!-- source: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/AnalyzingLogData.html -->

    **Expected Result:** A query editor. Across the top are a **Query by** selector reading **All log groups**, a **Search log groups...** box with a **Browse** button beside it, and a row of time-range buttons — **5m**, **30m**, **1h**, **3h**, **12h** — next to a date picker.

> **Common Pitfall:** There is no menu item called **Logs Insights** in the current console. AWS replaced it during 2026 with **Log Analytics**, which combines Logs Insights, Live Tail, and Contributor Insights into one surface. The **Logs** group now contains **Log Management**, **Log Analytics**, and **Log Anomalies** — so a student following any older instruction, screenshot, or AWS documentation page that says "choose Logs Insights" will not find it. Most published material, including parts of the AWS documentation, still shows the old name.

> **Common Pitfall:** The first time you open **Log Analytics** a dialog appears explaining the new experience, offering **OK** and **Opt out (Logs Insights)**. Choose **OK** — this lab is written against the new editor, and the query language is identical either way. If someone has already opted out on your account you will land in the classic Logs Insights editor instead; every query in this lab runs unchanged there. You can switch back at any time from the **Preferences** menu at the top right.

3. **Select the log group.** Choose **Browse** next to the search box. In the dialog that opens, find `/aws/lambda/cf110-01-slow-function` — substituting your student ID — tick its checkbox, and apply the selection.

    **Expected Result:** The **Query by** selector now names your log group instead of **All log groups**, and the first line of the query editor updates to a `SOURCE` line naming it.

> **Common Pitfall:** The editor opens **prefilled** with a query whose first line is
> `SOURCE logGroups(namePrefix: [], class: "STANDARD") START=-1w END=0s |`. That `SOURCE` line is what scopes the query to a log group and a time window — it is not decoration. If you select the whole editor and paste over it, you delete the scope along with the sample query, and what runs afterwards is not what you think you are running. In every step below, **replace only the lines beneath the `SOURCE` line** and leave that first line in place.

4. **Set the time range** by choosing the **30m** button above the query editor. The drumbeat rule invokes once a minute, so thirty minutes is roughly thirty invocations — enough to show a pattern without waiting.

5. **Count how often the function fails.** Leaving the `SOURCE` line in place, replace the lines below it with:

    ```
    fields @timestamp, @message
    | filter @type = 'REPORT' and @message like /Status: timeout/
    | sort @timestamp desc
    | limit 50
    ```
    <!-- source: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html -->

    Choose **Run** — the orange button at the bottom right of the editor, or press `Ctrl+Enter`.

    **Expected Result:** Several `REPORT` rows, each ending in `Status: timeout` and carrying `Duration: 30000.00 ms`. Roughly one invocation in three fails. The exact count varies because the fault is random — what matters is that failures are frequent but not universal.

> **Common Pitfall:** Searching for the string `Task timed out` finds **nothing** on this function, and the query still reports success — it simply returns zero rows. On the Python 3.12 runtime a timeout is recorded as `Status: timeout` on the `REPORT` line, not as the separate `Task timed out after N seconds` error line that older runtimes and most published examples show. A zero-row result is not proof that a function is healthy; confirm your filter matches text that actually exists before drawing any conclusion from an empty result.

6. **Measure the duration of every invocation.** Every completed invocation writes a `REPORT` line carrying `@duration` in milliseconds.

    ```
    fields @timestamp, @duration
    | filter @type = 'REPORT'
    | filter @duration > 25000
    | sort @timestamp desc
    | limit 50
    ```
    <!-- source: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html -->

    **Expected Result:** Rows with `@duration` at or just above `30000` — the timed-out invocations, stopped dead at the 30-second ceiling.

> **Key Insight:** A timed-out invocation still emits a `REPORT` line, and its `@duration` equals the timeout almost exactly. That flat ceiling is the signature of a timeout: a function that is merely slow shows a spread of durations, while a function hitting its limit shows a hard wall at one number.

7. **Find the cause inside the function.** The handler logs how long its downstream call took, before it makes that call. Those log lines survive even when the invocation is later killed.

    ```
    fields @timestamp, @message
    | filter @message like /calling external API/
    | sort @timestamp desc
    | limit 30
    ```
    <!-- source: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html -->

    **Expected Result:** Lines reading `calling external API took NNNms`. Two clusters appear: fast calls in the hundreds of milliseconds, and slow calls of `31000`, `38000`, or `45000` ms. Every slow value exceeds the 30-second timeout; every fast one is far below it.

> **Key Insight:** This is the whole diagnosis in one screen. The function is not slow on average — it is fast most of the time and occasionally makes a downstream call that cannot possibly finish inside 30 seconds. The failure is a property of the dependency, not of the function's own code path.

8. **Confirm the pattern holds across the metric**, not just the logs.

    ```bash
    aws cloudwatch get-metric-statistics --region "${REGION}" --namespace AWS/Lambda --metric-name Duration --dimensions Name=FunctionName,Value="${FN}" --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period 300 --statistics Maximum Average --output table
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/cloudwatch/get-metric-statistics.html -->

    **Expected Result:** `Maximum` sits near `30000` in most periods while `Average` is far lower. That gap between maximum and average is the numeric shape of an intermittent fault.

9. **Record the resolution you would recommend.** You are not applying it — the environment stays broken for the next student — but Task 5 asks you to write it down.

    **Expected Result:** Your playbook entry names the timeout as the *symptom* and the slow downstream call as the *cause*, and proposes a remedy that addresses the cause: a timeout on the downstream call itself, a retry with backoff, or moving the work to an asynchronous invocation. Raising the Lambda timeout above 45 seconds hides the symptom while leaving a caller waiting 45 seconds for a response.

---

## Part 3: Storage and Access

### Task 3: Resolve an S3 AccessDenied

**Goal:** Narrow an `AccessDenied` from "something about S3 is broken" to the one missing IAM action.

An application reports that it can see the bucket's contents but cannot download anything from it. That asymmetry is the entire diagnosis, and it rules out most of the usual suspects before you run a single command.

1. **Identify the role and bucket** from your handout.

    ```bash
    ROLE=cf110-${STUDENT_ID}-CrossAccountRole
    ```
    <!-- source: https://docs.aws.amazon.com/cloudshell/latest/userguide/working-with-aws-cli.html -->

    ```bash
    BUCKET=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'cf110-${STUDENT_ID}-target')].Name" --output text)
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/s3api/list-buckets.html -->

    ```bash
    echo "role=${ROLE} bucket=${BUCKET}"
    ```
    <!-- source: https://docs.aws.amazon.com/cloudshell/latest/userguide/working-with-aws-cli.html -->

    **Expected Result:** A bucket name of the form `cf110-01-target-abc123`. The six-character suffix is random per deployment, which is why you discover it rather than type it.

2. **Reproduce both behaviours.** Do not take the report on trust — establish the asymmetry yourself.

    ```bash
    aws s3 ls "s3://${BUCKET}/data/"
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/s3/ls.html -->

    **Expected Result:** Two objects listed — `README.txt` and `transactions.csv`.

3. **Read the role's permissions.** The role carries one inline policy.

    ```bash
    aws iam list-role-policies --role-name "${ROLE}" --output text
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/iam/list-role-policies.html -->

    **Expected Result:** One policy named `S3ListOnly`. The name is a strong hint, but confirm it rather than trusting it.

    ```bash
    aws iam get-role-policy --role-name "${ROLE}" --policy-name S3ListOnly --query "PolicyDocument.Statement" --output json
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/iam/get-role-policy.html -->

    **Expected Result:** A single statement allowing `s3:ListBucket` on the bucket ARN. There is no `s3:GetObject` anywhere in the document, and no `Deny` statement either.

4. **Prove it with the IAM Policy Simulator** rather than by reading the JSON. Reading a policy tells you what it says; simulating it tells you what it *does* once every attached policy is evaluated together.

    ```bash
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/sts/get-caller-identity.html -->

    Simulate each action against **its own** resource ARN. `s3:ListBucket` is a bucket-level action, so it takes the bucket ARN:

    ```bash
    aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::${ACCOUNT}:role/${ROLE}" --action-names s3:ListBucket --resource-arns "arn:aws:s3:::${BUCKET}" --query "EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}" --output table
    ```
    <!-- source: https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html -->

    **Expected Result:**

    ```
    -------------------------------
    |   SimulatePrincipalPolicy   |
    +----------------+------------+
    |     Action     | Decision   |
    +----------------+------------+
    |  s3:ListBucket |  allowed   |
    +----------------+------------+
    ```

    `s3:GetObject` is an object-level action, so it takes the object ARN:

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

    There is the asymmetry, confirmed by evaluation rather than by reading: the role may list the bucket and may not read what is in it.

> **Common Pitfall:** Do not pass both resource ARNs to a single `simulate-principal-policy` call. When you supply several resources, the top-level `EvalDecision` for each action collapses to the **most restrictive** result across all of them — so `s3:ListBucket` reports `implicitDeny` purely because it was also evaluated against an object ARN, where it does not apply. The run looks authoritative and tells you the opposite of the truth. Either simulate one action against one resource, as above, or read the per-resource breakdown in `ResourceSpecificResults[]` instead of the top-level decision.

> **Key Insight:** `implicitDeny` and `explicitDeny` are different findings with different fixes. `implicitDeny` means no policy ever granted the action — the fix is to add it. `explicitDeny` means a policy actively forbids it, and adding an `Allow` changes nothing, because an explicit `Deny` always wins. Reading which of the two you have tells you whether your fix will work before you attempt it.

5. **Note why the bucket policy is not the cause.** A bucket-level fault would break listing too.

    ```bash
    aws s3api get-bucket-policy --bucket "${BUCKET}" 2>&1 | head -3
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/s3api/get-bucket-policy.html -->

    **Expected Result:** `NoSuchBucketPolicy`. There is no bucket policy at all, so access is governed entirely by the identity policy you just simulated. This is a rule-out, exactly like Task 1.

> **Common Pitfall:** `AccessDenied` on S3 has several possible sources — the identity policy, a bucket policy, an S3 Block Public Access setting, an Object Ownership or ACL setting, or a KMS key policy on an encrypted object. Confirming which one applies is the difference between a one-line fix and an afternoon. The asymmetry between `ListBucket` succeeding and `GetObject` failing pointed at the identity policy from the start, because a bucket-level control would have blocked both.

6. **Write down the fix.** The remedy is to add `s3:GetObject` on the *object* ARN — note the `/*`, because object actions apply to objects inside the bucket, not to the bucket itself.

    ```json
    {
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::BUCKET-NAME/*"
    }
    ```
    <!-- source: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_resource.html -->

    **Expected Result:** Your playbook records the missing action, the ARN it belongs on, and the simulator output as evidence.

> **Common Pitfall:** `s3:ListBucket` takes the bucket ARN (`arn:aws:s3:::my-bucket`), while `s3:GetObject` takes the object ARN (`arn:aws:s3:::my-bucket/*`). Granting `GetObject` on the bucket ARN is one of the most common IAM mistakes, and it fails silently — the policy saves without error and the access still does not work.

---

### Task 4: Judge the EBS Volume

**Goal:** Decide whether the volume blamed for slowness is actually throttled, using the two metrics that answer that question.

A 1 GiB gp2 volume is attached to your Lab 1 instance at `/dev/sdf`. Someone has reported it as slow. Two metrics decide the case.

1. **Read the volume's configuration.**

    ```bash
    VOL=$(aws ec2 describe-volumes --region "${REGION}" --filters "Name=tag:Name,Values=cf110-${STUDENT_ID}-lab1-burst-volume" --query "Volumes[].VolumeId" --output text)
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-volumes.html -->

    ```bash
    aws ec2 describe-volumes --region "${REGION}" --volume-ids "${VOL}" --query "Volumes[].{Id:VolumeId,Type:VolumeType,Size:Size,Iops:Iops,State:State}" --output table
    ```
    <!-- source: https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-volumes.html -->

    **Expected Result:** A `gp2` volume of `1` GiB reporting `100` IOPS, in state `in-use`.

> **Key Insight:** gp2 grants 3 IOPS per GiB with a floor of 100. A 1 GiB volume therefore sits exactly on that floor — its baseline is 100 IOPS no matter how small it is. Volume *size* is what buys sustained performance on gp2, which is why undersized gp2 volumes are a recurring cause of unexplained I/O stalls.

2. **Read `BurstBalance`**, the credit pool that lets a gp2 volume exceed its baseline.

    ```bash
    aws cloudwatch get-metric-statistics --region "${REGION}" --namespace AWS/EBS --metric-name BurstBalance --dimensions Name=VolumeId,Value="${VOL}" --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period 300 --statistics Average --query "sort_by(Datapoints, &Timestamp)[-6:].{Time:Timestamp,Pct:Average}" --output table
    ```
    <!-- source: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ebs-metricscollected.html -->

    **Expected Result:** Values at or very near `100` percent. The credit pool is full.

3. **Read `VolumeQueueLength`**, the number of I/O requests waiting.

    ```bash
    aws cloudwatch get-metric-statistics --region "${REGION}" --namespace AWS/EBS --metric-name VolumeQueueLength --dimensions Name=VolumeId,Value="${VOL}" --start-time "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period 300 --statistics Average --output table
    ```
    <!-- source: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ebs-metricscollected.html -->

    **Expected Result:** Values at or near `0`. Nothing is queuing, because nothing is driving I/O against this volume.

4. **Reach a verdict.**

    **Expected Result:** You can state that the volume is **not** throttled: burst credits are full and the queue is empty. The report of slowness is not supported by the evidence, and the correct next step is to find out what the reporter actually measured — which application, on which mount point, at what time.

> **Key Insight:** These two metrics answer different questions and you need both. `BurstBalance` falling toward zero means the volume is *about to be* throttled to its baseline. `VolumeQueueLength` rising means requests are *already* waiting. A depleted balance with an empty queue is a volume that will struggle under future load; a full balance with a deep queue points away from the volume and toward the application's I/O pattern. Only both at once — drained credits and a deep queue — indicts the volume itself.

> **Note:** This volume is deliberately left healthy. Draining a gp2 burst bucket takes hours of sustained I/O, far longer than a 60-minute lab, so the honest exercise is reading the metrics and interpreting what they mean. If your instructor has run a load generator against `/dev/sdf` before class, you will see `BurstBalance` below 100 and can watch it recover.

---

## Part 4: Documentation

### Task 5: Complete the Troubleshooting Playbook

**Goal:** Turn four investigations into records another engineer could act on without asking you anything.

1. **Complete one playbook entry per task.** Two of your four findings are "no fault present" — record those with the same rigour as the faults. An investigation that concluded nothing was wrong is only useful to the next person if they can see what you checked.

    | Field | Content |
    |-------|---------|
    | Incident ID | Your ticket reference |
    | Symptom | The behaviour as reported, in the reporter's terms |
    | Affected resource | Instance ID, function name, bucket name, or volume ID |
    | Investigation steps | The commands you ran, in order |
    | Evidence | The actual output that supports your conclusion |
    | Root cause | The identified cause, or "no fault found" with what you ruled out |
    | Resolution | The fix applied, or the fix recommended and why |
    | Verification | How the fix would be confirmed |
    | Prevention | What would stop this recurring, or detect it sooner |

2. **Check your four entries against what the evidence supports.**

    | Task | Finding | Root cause |
    |------|---------|------------|
    | 1 — EC2 status checks | No fault | Both checks `ok`; host and guest layers excluded |
    | 2 — Lambda timeouts | Fault confirmed | Downstream call sometimes exceeds the 30-second timeout |
    | 3 — S3 AccessDenied | Fault confirmed | Role policy grants `s3:ListBucket` but never `s3:GetObject` |
    | 4 — EBS performance | No fault | `BurstBalance` full, `VolumeQueueLength` zero |

    **Expected Result:** Every entry names its evidence. "The instance was fine" is not a record; "`describe-instance-status` returned `System: ok, Instance: ok` at 14:32 UTC" is.

> **Key Insight:** Two of four reports had no fault. That ratio is normal. The engineer who can close a ticket with "here is what I checked and here is why nothing is wrong" saves more time than the one who keeps digging for a fault that was never there — provided the evidence is written down. Without it, the next person repeats the whole investigation.

---

## Troubleshooting Reference

| Issue | Symptom | Solution |
|-------|---------|----------|
| Wrong region | Resource lists are empty although the resources exist | Check the region selector in the top navigation bar and switch to your class region |
| `INSTANCE_ID` is empty | `echo "instance=${INSTANCE_ID}"` prints nothing after the `=` | `STUDENT_ID` does not match your resource names. Check your handout — it is `01`, not `user01` |
| Another student's resources | A command returns a resource whose name carries a different student ID | Every filter in this lab includes `cf110-${STUDENT_ID}`. Confirm you exported your own ID |
| Log Analytics returns nothing | Query runs successfully but finds zero rows | Widen the time range to 30 minutes, and confirm the selected log group is `/aws/lambda/cf110-<id>-slow-function` |
| Cannot find Logs Insights | No such item in the CloudWatch navigation pane | It no longer exists under that name. Expand **Logs** and choose **Log Analytics**, which replaced it in 2026 |
| Unexpected dialog on first query | A panel describes a "new Log Analytics experience" | Choose **OK**. Every query in this lab works in either editor; **Opt out (Logs Insights)** returns you to the classic one |
| Console output is empty | `get-console-output` returns no text | The instance booted only minutes ago. Wait and retry — this is timing, not a fault |
| Simulator returns `implicitDeny` for everything | Every action denied, including `ListBucket` | Check the `--policy-source-arn` names a role that exists, and that the account ID resolved correctly |
| `BurstBalance` has no datapoints | Empty result table | The metric exists only on gp2 volumes. Confirm `VolumeType` is `gp2` and that you used the burst volume, not the root volume |
| Session expired | Console redirects to the sign-in page mid-lab | Sign in again with the same lab credentials |

## Next Steps

In **[Lab 2: AWS IAM and Network Troubleshooting](../lab_2/README.md)**, you move from single-resource faults to faults that live *between* resources — a role that cannot be assumed because of a trust policy written on the other side, a subnet with no route to the internet, and a load balancer whose health checks never arrive. The rule-out discipline you used in Tasks 1 and 4 becomes the main tool rather than a side result.

---

## Resources

- [Status checks for Amazon EC2 instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/monitoring-system-instance-status-check.html)
- [Troubleshoot Lambda function timeouts](https://docs.aws.amazon.com/lambda/latest/dg/troubleshooting-invocation.html)
- [CloudWatch Logs Insights query syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html)
- [Testing IAM policies with the Policy Simulator](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html)
- [Troubleshoot access denied error messages in Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/troubleshoot-403-errors.html)
- [Amazon EBS CloudWatch metrics](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ebs-metricscollected.html)
- [Amazon EBS volume types](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html)
- [AWS CloudShell User Guide](https://docs.aws.amazon.com/cloudshell/latest/userguide/welcome.html)

---

*Lab 1 Complete*
