# Lab 3: Azure Compute and Storage Troubleshooting

**Course:** COO-110 AWS Troubleshooting Deep Dive — bonus material
**Duration:** 60 minutes, self-paced

---

> ## Bonus material — read this first
>
> This lab is **optional, self-paced, and not delivered in class.** The taught labs are Lab 1
> and Lab 2, which run on AWS against an environment your instructor deploys for you.
>
> Two things make this one different, and you should know both before you start:
>
> 1. **No environment is provided.** Lab 1 and Lab 2 run against a per-student stack built for
>    you. There is no equivalent Azure stack — you need your own Azure subscription and enough
>    access to create the resources each task describes.
> 2. **The expected results here are derived from Microsoft's documentation, not observed.**
>    Every command in Labs 1 and 2 was executed against live infrastructure and its real output
>    is what those guides print. That is not true here. Treat each **Expected Result** below as
>    "what the documentation says should happen" rather than "what was seen to happen", and
>    expect to adapt to your own tenant.
>
> **Why do it anyway.** The four fault shapes are the same ones you diagnosed on AWS — compute,
> storage, identity, network. Working them a second time in a different cloud is what turns a
> set of AWS commands into a method you can carry anywhere. That transfer is the entire point of
> the course, and this is where you prove it to yourself.
>
> **Partial shortcut.** The instructor demo stack at [`demo/azure`](../../demo/azure/README.md) builds roughly half of what
> this lab needs — the storage account with a managed identity holding only a control-plane
> role, the NSG and route-table faults, and the load balancer with a blocked health probe. It
> does **not** include an App Service or a Key Vault. If you have it deployed, Tasks 3 here and
> Tasks 3 and 4 of Lab 4 will work against it directly.

---

## Overview

In Labs 1 and 2 you worked the AWS side of a fault: status checks, CloudWatch metrics, Log Analytics, the IAM Policy Simulator. The same four shapes of problem appear in Azure, and the method transfers exactly — establish a baseline, eliminate layers with evidence, name the component you can prove is at fault. The tools change; the discipline does not.

What does change is where the evidence lives. Azure separates *platform* telemetry from *guest* telemetry more sharply than AWS does. Metrics about a virtual machine's host are collected automatically; anything from inside the guest operating system arrives only if an agent is installed and a data collection rule tells it what to gather. A large share of Azure troubleshooting time is lost to querying a table that is empty because nothing was ever configured to fill it — and an empty table looks identical to a healthy system.

## Objectives

By completing this lab, you will:

- Read platform metrics for a virtual machine in Azure Monitor and distinguish them from guest metrics
- Query the `Perf` and `InsightsMetrics` tables in Log Analytics using KQL
- Recognise when an empty query result means "not collected" rather than "nothing wrong"
- Diagnose an App Service returning HTTP 500 by correlating access logs with application exceptions
- Resolve a storage access failure for a managed identity by locating the missing RBAC role assignment
- Distinguish a data-plane RBAC failure from a control-plane one, and from a storage firewall block
- Identify disk throttling using the IOPS and bandwidth consumed-percentage metrics
- Record findings in the same playbook format you used on Day 1

> **Note:** Your instructor provides the resource group name, virtual machine name, storage account name, and Log Analytics workspace for your own environment. Substitute them wherever this guide shows an example such as `cf110-01-rg` or `cf110-01-vm`.

> **Note:** Azure resource names are case-sensitive in KQL comparisons. `Computer == "cf110-01-vm"` does not match a machine registered as `CF110-01-VM`. When a query returns nothing, checking the case of your literals is the cheapest thing to rule out.

---

## Part 1: Compute

### Task 1: Investigate Virtual Machine Performance

**Goal:** Determine whether a virtual machine reported as "slow" is actually resource-constrained, and know which layer your evidence comes from.

1. **Open the virtual machine's platform metrics.** Sign in to the Azure portal, search for **Virtual machines**, and select your machine. In the left menu under **Monitoring**, choose **Metrics**.
    <!-- source: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/metrics-getting-started -->

2. **Plot host CPU.** Set **Metric** to **Percentage CPU** and the aggregation to **Average**, then set the time range to the last hour.

    **Expected Result:** A time chart of CPU. This metric comes from the **host**, not from inside the guest, so it is present without any agent installed.

> **Key Insight:** Azure's platform metrics measure what the hypervisor can see: CPU, disk, and network at the host boundary. **Percentage CPU** is therefore always available. **Memory** is not — the host cannot see inside the guest's memory manager, exactly as an AWS EC2 instance publishes no memory metric by default. If you need memory, something must run inside the guest and report it.

3. **Check Resource Health** before assuming the fault is yours. In the left menu under **Help**, choose **Resource health**.
    <!-- source: https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview -->

    **Expected Result:** A status of **Available**, meaning the platform believes the machine is healthy. This is the Azure equivalent of the EC2 system status check you read in Lab 1 — it reports on the platform underneath your machine, not on your workload.

4. **Confirm the same picture from the CLI.**

    ```bash
    RG=cf110-01-rg
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/azure-cli-variables -->

    ```bash
    VM=cf110-01-vm
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/azure-cli-variables -->

    ```bash
    az vm show --resource-group "${RG}" --name "${VM}" --query "{Name:name,Size:hardwareProfile.vmSize,Location:location}" --output table
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/vm#az-vm-show -->

    **Expected Result:** The machine's name, its SKU size, and its region. The size determines its CPU, memory, and uncached disk throughput limits, so record it — Task 4 needs it.

5. **Query guest performance data in Log Analytics.** In the portal, open your Log Analytics workspace and choose **Logs**. Run:

    ```kql
    Perf
    | where Computer == "cf110-01-vm"
    | where ObjectName == "Processor" and CounterName == "% Processor Time"
    | where InstanceName == "_Total"
    | summarize AvgCPU = avg(CounterValue) by bin(TimeGenerated, 5m)
    | render timechart
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/perf -->

    **Expected Result:** Either a time chart of guest-measured CPU, or **no results**. Both are findings, and step 6 tells them apart.

6. **If the query returned nothing, establish why before concluding anything.** An empty result has two very different causes: the machine is not sending data, or your filter does not match.

    ```kql
    Perf
    | where TimeGenerated > ago(1h)
    | summarize Records = count() by Computer
    | order by Records desc
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/get-started-queries -->

    **Expected Result:** A list of every machine sending performance data, with counts. If your machine is absent from this list entirely, no agent is reporting and the `Perf` table can never answer your question. If it is present but your earlier query returned nothing, your `Computer` literal did not match — compare the exact spelling and case.

> **Common Pitfall:** This is the single most expensive mistake in Azure troubleshooting. A KQL query against an empty table succeeds, returns zero rows, and looks exactly like "no problem found." Before you treat an empty result as evidence of health, prove the table contains data for your resource at all. The same trap appeared on Day 1 with CloudWatch Logs Insights, and it costs more here because Azure has more tables that are empty by default.

> **Key Insight:** Guest metrics reach Log Analytics only when the Azure Monitor Agent is installed **and** a Data Collection Rule targets the machine and names the counters to gather. Installing the agent alone collects nothing — the rule is what defines the payload. If `Perf` is empty for your machine, the remedy is a data collection rule, not more querying.

7. **Check memory pressure**, if guest data is arriving.

    ```kql
    Perf
    | where Computer == "cf110-01-vm"
    | where ObjectName == "Memory" and CounterName == "Available MBytes"
    | summarize AvgAvailableMB = avg(CounterValue) by bin(TimeGenerated, 5m)
    | render timechart
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/perf -->

    **Expected Result:** Available memory over time. A value trending toward zero indicates real memory pressure; a flat line well above zero rules memory out.

8. **Record your verdict.** State whether the machine is resource-constrained, and name the layer your evidence came from — host metrics, guest metrics, or both.

    **Expected Result:** A conclusion that cites its source. "CPU averaged 4 percent per host metrics over the last hour, and guest counters are not being collected" is a usable finding. "The VM looked fine" is not.

---

### Task 2: Diagnose App Service HTTP 500 Errors

**Goal:** Separate the symptom recorded at the web front end from the exception that caused it.

An App Service is returning HTTP 500 to callers. A 500 is the server declining to explain itself, so the access log tells you *that* it happened and never *why*. You need two sources correlated.

1. **Confirm the failures in the access log.** Open your Log Analytics workspace, choose **Logs**, and run:

    ```kql
    AppServiceHTTPLogs
    | where TimeGenerated > ago(1h)
    | where ScStatus >= 500
    | project TimeGenerated, CsMethod, CsUriStem, ScStatus, TimeTaken
    | order by TimeGenerated desc
    | take 100
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/appservicehttplogs -->

    **Expected Result:** Rows showing the failing requests, each with the method, the path, the status code, and how long the request took before failing. Note which paths fail — if a single endpoint accounts for all of them, that narrows the search enormously.

> **Note:** `AppServiceHTTPLogs` is populated only when diagnostic settings on the App Service send **AppServiceHTTPLogs** to your Log Analytics workspace. If the table does not exist or is empty, open the App Service, choose **Diagnostic settings** under **Monitoring**, and confirm a rule sends that category to the workspace. As in Task 1, an empty table is a configuration finding, not a health finding.

2. **Read `TimeTaken` on the failing rows.** It distinguishes two very different faults.

    **Expected Result:** Either short durations, or durations close to a timeout threshold.

> **Key Insight:** A 500 returned in a few milliseconds is an exception thrown almost immediately — a null reference, a bad configuration value, a failed startup. A 500 returned after 30 or 230 seconds is a *timeout* waiting on something downstream: a database, an API, a lock. The status code is identical; `TimeTaken` is what separates them, and it points you at completely different evidence. This is the same reasoning you applied to the Lambda in Lab 1, where duration against a ceiling revealed the fault.

3. **Find the exception behind the status code.**

    ```kql
    AppExceptions
    | where TimeGenerated > ago(1h)
    | project TimeGenerated, ExceptionType, OuterMessage, Method
    | order by TimeGenerated desc
    | take 50
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/appexceptions -->

    **Expected Result:** Exception records carrying a type and message. `AppExceptions` is an Application Insights table, so it is present only if Application Insights is enabled for the App Service.

4. **Correlate the two by time.** Line up an exception timestamp with a 500 in the access log.

    ```kql
    AppServiceHTTPLogs
    | where TimeGenerated > ago(1h)
    | where ScStatus >= 500
    | project HttpTime = TimeGenerated, CsUriStem, ScStatus
    | join kind=inner (
        AppExceptions
        | where TimeGenerated > ago(1h)
        | project ExTime = TimeGenerated, ExceptionType, OuterMessage
      ) on $left.HttpTime == $right.ExTime
    | take 20
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/data-explorer/kusto/query/joinoperator -->

    **Expected Result:** Rows pairing a failing request with the exception thrown while serving it. An exact-timestamp join is strict and may return nothing even when both tables hold relevant data; if so, compare the two result sets by eye on their timestamps instead.

> **Common Pitfall:** Joining two telemetry tables on an exact timestamp rarely works. The web front end and the application runtime record their events at slightly different instants, so equality matches almost nothing. Either widen the join with `bin(TimeGenerated, 1m)` on both sides, or read the two result sets side by side. A join returning zero rows is not evidence that the exception and the 500 are unrelated.

5. **Record the root cause and the fix you would recommend.**

    **Expected Result:** Your notes name the failing endpoint, the exception type and message, and whether the 500 is an immediate exception or a downstream timeout.

---

## Part 2: Storage and Access

### Task 3: Resolve Storage Access for a Managed Identity

**Goal:** Find why a virtual machine using a managed identity cannot read a blob, choosing correctly between three candidate causes.

A workload on the virtual machine authenticates with its managed identity and fails when it reads from a storage account. Three things could cause this, and they need different fixes:

- the identity has no **data-plane** RBAC role on the storage account,
- the storage account's **firewall** blocks the machine's network path, or
- the identity is not enabled at all.

1. **Confirm the identity exists and capture its principal ID.**

    ```bash
    PRINCIPAL_ID=$(az vm identity show --resource-group "${RG}" --name "${VM}" --query principalId --output tsv)
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/vm/identity#az-vm-identity-show -->

    ```bash
    echo "principal=${PRINCIPAL_ID}"
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/azure-cli-variables -->

    **Expected Result:** A GUID. If the command returns nothing or an error, no managed identity is assigned — that is the fault, and the remedy is to enable one rather than to grant roles to something that does not exist.

2. **List the role assignments that identity actually holds.**

    ```bash
    az role assignment list --assignee "${PRINCIPAL_ID}" --all --query "[].{Role:roleDefinitionName,Scope:scope}" --output table
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/role/assignment#az-role-assignment-list -->

    **Expected Result:** A table of roles and scopes, quite possibly empty, and quite possibly containing a role that looks sufficient but is not. Read the next insight before judging it.

> **Key Insight:** **Owner**, **Contributor**, and **Reader** are *control-plane* roles. They govern managing the storage account — its keys, its configuration, its existence — and grant **no access to blob data whatsoever**. Reading a blob with Entra ID credentials requires a *data-plane* role such as **Storage Blob Data Reader** or **Storage Blob Data Contributor**. An identity holding **Contributor** on a storage account can delete the entire account and still receive `AuthorizationPermissionMismatch` when it tries to read one blob. This trips up experienced engineers constantly, because the assignment list looks generous.

3. **Check the assignments scoped to the storage account itself.**

    ```bash
    STORAGE=cf110storage01
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/azure-cli-variables -->

    ```bash
    SCOPE=$(az storage account show --resource-group "${RG}" --name "${STORAGE}" --query id --output tsv)
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/storage/account#az-storage-account-show -->

    ```bash
    az role assignment list --scope "${SCOPE}" --include-inherited --query "[].{Principal:principalId,Role:roleDefinitionName,Scope:scope}" --output table
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/role/assignment#az-role-assignment-list -->

    **Expected Result:** Every assignment that applies here, including those inherited from the resource group and subscription. Look for a **Storage Blob Data** role naming your principal ID. Its absence is the likely fault.

4. **Rule out the storage firewall** before concluding it is RBAC.

    ```bash
    az storage account show --resource-group "${RG}" --name "${STORAGE}" --query "networkRuleSet.{Default:defaultAction,VNets:virtualNetworkRules[].id,IPs:ipRules[].ipAddressOrRange}" --output json
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/storage/account#az-storage-account-show -->

    **Expected Result:** If `Default` is `Allow`, the firewall permits all networks and is **not** the fault. If it is `Deny`, only the listed virtual network rules and IP ranges may connect, and your machine's subnet must appear among them.

> **Key Insight:** The two faults produce different errors, and reading the error first saves a round of investigation. A missing data-plane role returns **403 `AuthorizationPermissionMismatch`** — the request reached the service and was refused on authorisation. A firewall block returns **403 `AuthorizationFailure`**, or the connection fails outright — the request was refused on network origin. Capturing the exact error code from the failing application is worth more than any amount of reading configuration.

5. **Confirm the identity can obtain a token.** Run this **on the virtual machine**, not in Cloud Shell — the endpoint is link-local and only answers from inside the machine.

    ```bash
    curl -s -H "Metadata: true" "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/"
    ```
    <!-- source: https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-to-use-vm-token -->

    **Expected Result:** A JSON document containing an `access_token`. This proves the identity is enabled and can authenticate. A token proves *authentication*; it says nothing about *authorisation* — which is precisely why a workload can hold a valid token and still be refused the blob.

6. **Record the fix.** Assign the least-privileged data-plane role that satisfies the workload, scoped as narrowly as possible.

    ```bash
    az role assignment create --assignee "${PRINCIPAL_ID}" --role "Storage Blob Data Reader" --scope "${SCOPE}"
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/storage/blobs/assign-azure-role-data-access -->

    **Expected Result:** Your notes name the role, the principal, and the scope. Prefer the container scope over the account scope when the workload only needs one container.

> **Note:** Role assignments are eventually consistent and can take several minutes to take effect. A workload that still fails immediately after an assignment is not necessarily still misconfigured — wait and retry before changing anything else, or you will stack a second change on top of one that was already correct.

---

### Task 4: Identify Managed Disk Throttling

**Goal:** Decide whether a disk reported as slow is genuinely being throttled, and at which limit.

1. **Read the disk's configuration.**

    ```bash
    az disk show --resource-group "${RG}" --name cf110-01-datadisk --query "{SKU:sku.name,SizeGB:diskSizeGb,IOPS:diskIOPSReadWrite,ThroughputMBps:diskMBpsReadWrite}" --output table
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/disk#az-disk-show -->

    **Expected Result:** The disk's SKU, its size, and its provisioned IOPS and throughput ceilings. Record all four — throttling can only be judged against a stated limit.

> **Key Insight:** On Azure managed disks, performance is a function of the **tier and the size**. A Premium SSD v1 disk's IOPS ceiling steps up at fixed size boundaries — a P10 is capped far below a P30 — so a disk that is large enough for the data can still be far too small for the I/O. This mirrors the gp2 sizing behaviour you saw in Lab 1, where a 1 GiB volume sat on the 100 IOPS floor.

2. **Check whether the disk is hitting its limit.**

    ```kql
    InsightsMetrics
    | where TimeGenerated > ago(1h)
    | where Name == "Data Disk IOPS Consumed Percentage"
    | summarize AvgIOPSPct = avg(Val), MaxIOPSPct = max(Val) by bin(TimeGenerated, 5m)
    | order by TimeGenerated desc
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/insightsmetrics -->

    **Expected Result:** A percentage of the provisioned IOPS being consumed. Values approaching 100 mean the disk is capped — requests are being throttled and latency rises. Values well below 100 rule the disk out.

3. **Check the bandwidth limit as well.** A disk can be under its IOPS ceiling and still be capped on throughput.

    ```kql
    InsightsMetrics
    | where TimeGenerated > ago(1h)
    | where Name == "Data Disk Bandwidth Consumed Percentage"
    | summarize AvgBWPct = avg(Val), MaxBWPct = max(Val) by bin(TimeGenerated, 5m)
    | order by TimeGenerated desc
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/insightsmetrics -->

    **Expected Result:** A percentage of provisioned throughput consumed.

> **Key Insight:** Two ceilings apply at once, and either alone throttles you. Many small reads exhaust **IOPS** while barely touching bandwidth; a few large sequential reads exhaust **bandwidth** while barely touching IOPS. Checking only one metric is how a throttled disk gets declared healthy. There is a third ceiling too — the **virtual machine size** has its own IOPS and throughput limits, and a machine hosting several fast disks can be capped at the VM level while every individual disk sits well under its own limit.

4. **Reach a verdict.**

    **Expected Result:** A statement of whether the disk is throttled, on which ceiling, and what you would change — a larger or higher-tier disk if the disk is the limit, a larger VM size if the machine is, or a change to the application's I/O pattern if neither ceiling is close.

> **Note:** `InsightsMetrics` is populated by **VM Insights**, not by the platform. If these queries return nothing, confirm VM Insights is enabled for the machine. The equivalent figures are also visible without any agent under the virtual machine's **Metrics** blade, using the platform metrics **Data Disk IOPS Consumed Percentage** and **Data Disk Bandwidth Consumed Percentage**.

---

## Part 3: Documentation

### Task 5: Complete the Azure Playbook

**Goal:** Record four Azure investigations so another engineer can act on them without repeating your work.

1. **Complete one entry per task**, using the same structure as Day 1 with the Azure-specific fields filled in.

    | Field | Content |
    |-------|---------|
    | Incident ID | Your ticket reference |
    | Azure resource | Full resource ID, not just the name |
    | Subscription and resource group | Both — names repeat across subscriptions |
    | Symptom | The behaviour as reported |
    | Investigation tools | Azure Monitor, Log Analytics, Resource Health, Network Watcher |
    | KQL queries used | The queries themselves, so they can be re-run |
    | Evidence | Query output or metric values supporting the conclusion |
    | Root cause | The identified cause, or "no fault found" with what was ruled out |
    | Resolution | The fix applied or recommended |
    | Prevention | What would prevent recurrence or detect it sooner |

> **Key Insight:** Record the **full resource ID**, not the friendly name. Azure resource names are unique only within a resource group, so `cf110-01-vm` may exist in several subscriptions at once. An escalation naming only the friendly name sends the next engineer hunting, and occasionally sends them to the wrong machine entirely.

2. **Note which of your findings were configuration gaps rather than faults.**

    **Expected Result:** An honest split. If `Perf` was empty because no data collection rule targeted the machine, the finding is "guest telemetry not collected" — a monitoring gap, not a performance fault. Recording it that way gets the gap fixed; recording it as "no problem found" guarantees the next person hits the same wall.

---

## Troubleshooting Reference

| Issue | Symptom | Solution |
|-------|---------|----------|
| KQL returns nothing | Query succeeds, zero rows | Run the query without the `Computer` or `Name` filter first. If rows appear, your filter is wrong; if not, nothing is sending that data |
| `Perf` table empty for your machine | Other machines appear, yours does not | The Azure Monitor Agent is missing, or no Data Collection Rule targets it. The agent alone collects nothing |
| `Computer` filter matches nothing | Machine appears in the table but your query is empty | KQL string comparison is case-sensitive. Use `=~` for a case-insensitive match |
| `AppServiceHTTPLogs` does not exist | Table name unresolved in the query editor | Diagnostic settings on the App Service are not sending that category to this workspace |
| `AppExceptions` empty | No exception rows despite 500s | Application Insights is not enabled for the App Service |
| Join returns nothing | Both tables have data but the join is empty | Exact timestamp equality rarely matches. Bin both sides to the minute, or compare the result sets by eye |
| Token request fails | `curl` to 169.254.169.254 times out | The IMDS endpoint is link-local and answers only from **inside** the virtual machine. It cannot be reached from Cloud Shell |
| Role assigned but access still denied | 403 continues after assigning a role | Confirm it is a **data-plane** role (Storage Blob Data Reader), not Contributor or Owner. Then allow several minutes for propagation |
| `AuthorizationFailure` rather than `AuthorizationPermissionMismatch` | Different 403 error code | This is the storage firewall, not RBAC. Check `networkRuleSet.defaultAction` |
| `InsightsMetrics` empty | Disk queries return nothing | VM Insights is not enabled. Use the platform metrics on the **Metrics** blade instead |
| Wrong subscription | Resources not found although they exist | `az account set --subscription "<name-or-id>"`, then retry |

## Next Steps

In **[Lab 4: Azure IAM and Network Troubleshooting](../lab_4_azure_iam_network/README.md)**, you move to faults that live between Azure resources — a managed identity refused by Key Vault, a role assignment that appears correct but is overridden, a virtual machine that cannot reach a storage endpoint, and a load balancer whose health probes are blocked before they arrive. As in Lab 2, the second lab is where the fault is never in the component that was reported.

---

## Resources

- [Get started with metrics explorer](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/metrics-getting-started)
- [Azure Resource Health overview](https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview)
- [Log Analytics tutorial](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-tutorial)
- [KQL quick reference](https://learn.microsoft.com/en-us/azure/data-explorer/kql-quick-reference)
- [Azure Monitor Agent data collection rules](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/data-collection-rule-azure-monitor-agent)
- [Assign an Azure role for access to blob data](https://learn.microsoft.com/en-us/azure/storage/blobs/assign-azure-role-data-access)
- [Authorize access to blobs using Microsoft Entra ID](https://learn.microsoft.com/en-us/azure/storage/blobs/authorize-access-azure-active-directory)
- [How to use managed identities to acquire an access token](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-to-use-vm-token)
- [Managed disk performance targets](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-performance)
- [VM Insights overview](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/vminsights-overview)

---

*Lab 3 Complete*
