# Lab 4: Azure IAM and Network Troubleshooting

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

This is the Azure counterpart to Lab 2, and it has the same character: every component reports itself healthy, and the fault lives in the relationship between two of them. A managed identity holds a role and is still refused. A user has been granted Contributor and still cannot act. A virtual machine with open rules still cannot reach a storage endpoint. A load balancer marks a working web server as down.

Azure adds one mechanism that has no direct AWS equivalent and which you must know to diagnose the second task: a **deny assignment** overrides every role assignment, is created by the platform rather than by an administrator, and does not appear in the role assignment list that most engineers check first. An access failure that survives a correct-looking role assignment is often this, and it is invisible unless you go looking for it deliberately.

## Objectives

By completing this lab, you will:

- Diagnose a Key Vault authorisation failure and identify whether the vault uses RBAC or access policies
- Query the Azure Activity Log and `AzureDiagnostics` for the record of a refused request
- Find a deny assignment, and explain why it does not appear in `az role assignment list`
- Distinguish a scope problem from a propagation delay from an outright override
- Use Network Watcher IP flow verify to name the exact security rule blocking a connection
- Identify why a load balancer health probe is dropped and which service tag must be permitted
- Escalate an Azure finding with the resource IDs and evidence the receiving team needs

> **Note:** Your instructor provides your resource group, virtual machine, key vault, and load balancer names. Substitute them wherever this guide shows an example such as `cf110-01-rg`.

> **Note:** Several commands here need the Network Watcher extension enabled in your region, and some need the `AzureNetworkAnalytics_CL` table, which exists only where Traffic Analytics is switched on. Where a prerequisite is missing, the guide says what to check rather than leaving you with an empty result.

---

## Part 1: Identity and Access

### Task 1: Diagnose Key Vault Access for a Managed Identity

**Goal:** Explain why a managed identity holding a role is still refused by Key Vault.

A workload authenticates with its managed identity and receives an authorisation failure reading a secret. Key Vault is unusual in Azure because it has **two** independent permission models, and a vault uses exactly one of them. Checking the wrong one wastes the whole investigation.

1. **Set your variables and capture the identity.**

    ```bash
    RG=cf110-01-rg
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/azure-cli-variables -->

    ```bash
    VM=cf110-01-vm
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/azure-cli-variables -->

    ```bash
    VAULT=cf110-01-kv
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/azure-cli-variables -->

    ```bash
    PRINCIPAL_ID=$(az vm identity show --resource-group "${RG}" --name "${VM}" --query principalId --output tsv)
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/vm/identity#az-vm-identity-show -->

    ```bash
    echo "principal=${PRINCIPAL_ID}"
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/azure-cli-variables -->

    **Expected Result:** A GUID. An empty result means no managed identity is assigned, which is the fault.

2. **Determine which permission model the vault uses.** Do this before checking any permission, because it decides where to look.

    ```bash
    az keyvault show --name "${VAULT}" --query "{Name:name,RbacEnabled:properties.enableRbacAuthorization,PublicAccess:properties.publicNetworkAccess}" --output table
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/keyvault#az-keyvault-show -->

    **Expected Result:** `RbacEnabled` reads either `true` or `false`, and that single value determines everything that follows.

> **Key Insight:** When `enableRbacAuthorization` is **true**, the vault ignores access policies entirely and honours only Azure RBAC roles such as **Key Vault Secrets User**. When it is **false**, the vault ignores RBAC data-plane roles and honours only its own **access policy** list. The two models do not combine and there is no fallback. An engineer who adds a perfect RBAC role assignment to an access-policy vault will see no change at all, and will usually blame propagation delay for an hour before checking this flag.

3. **If the vault uses RBAC**, list the assignments at its scope.

    ```bash
    VAULT_ID=$(az keyvault show --name "${VAULT}" --query id --output tsv)
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/keyvault#az-keyvault-show -->

    ```bash
    az role assignment list --scope "${VAULT_ID}" --include-inherited --query "[].{Principal:principalId,Role:roleDefinitionName}" --output table
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/role/assignment#az-role-assignment-list -->

    **Expected Result:** A table of assignments. Look for your principal ID holding a **Key Vault Secrets User** or **Key Vault Secrets Officer** role. As with storage in Lab 3, **Contributor** grants management of the vault and no access to its secrets.

4. **If the vault uses access policies**, read those instead.

    ```bash
    az keyvault show --name "${VAULT}" --query "properties.accessPolicies[].{ObjectId:objectId,Secrets:permissions.secrets,Keys:permissions.keys}" --output json
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/keyvault#az-keyvault-show -->

    **Expected Result:** A list of object IDs with their permitted operations. Your principal ID must appear with `get` — and `list` if the workload enumerates secrets.

> **Common Pitfall:** `get` and `list` are separate permissions on a vault, exactly as `s3:GetObject` and `s3:ListBucket` were separate in Lab 1. An identity with `list` but not `get` can enumerate secret *names* and cannot read any *value*. The application's error looks like a total failure while the permission list looks populated.

5. **Find the refusal in the vault's own logs.**

    ```kql
    AzureDiagnostics
    | where TimeGenerated > ago(1h)
    | where ResourceProvider == "MICROSOFT.KEYVAULT"
    | where ResultSignature == "Forbidden"
    | project TimeGenerated, OperationName, CallerIPAddress, identity_claim_oid_g, ResultDescription
    | order by TimeGenerated desc
    | take 50
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/key-vault/general/logging -->

    **Expected Result:** Rows for each refused request, including the object ID of the caller. Match that object ID against your principal ID to confirm you are investigating the right identity.

> **Note:** This table is populated only if a diagnostic setting on the key vault sends **AuditEvent** to your Log Analytics workspace. If it is empty, that is a logging gap. Check it before concluding no requests were made — as in Lab 3, an empty table and a healthy system look identical.

6. **Record the fix**, matching the model the vault actually uses.

    ```bash
    az role assignment create --assignee "${PRINCIPAL_ID}" --role "Key Vault Secrets User" --scope "${VAULT_ID}"
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide -->

    **Expected Result:** Your notes state which model the vault uses, what was missing, and the corresponding remedy — an RBAC assignment, or an access policy entry.

---

### Task 2: Investigate an RBAC Assignment That Does Not Work

**Goal:** Explain why a user holding an apparently sufficient role is still denied.

A user has been granted a role and still cannot perform the action. Four explanations are worth testing, in this order.

1. **List every assignment the user holds, at every scope.**

    ```bash
    USER=user@example.com
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/azure-cli-variables -->

    ```bash
    az role assignment list --assignee "${USER}" --all --query "[].{Role:roleDefinitionName,Scope:scope}" --output table
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/role/assignment#az-role-assignment-list -->

    **Expected Result:** Every assignment and the scope each applies at. Read the scopes carefully — this is where the first two explanations live.

> **Key Insight:** Azure RBAC inherits **downward** only: management group, then subscription, then resource group, then resource. A role granted on one resource group does nothing in a sibling resource group, and a role granted on a single resource does not cover the group that contains it. An assignment list that looks generous can still be scoped somewhere that does not include the resource the user is actually touching. Compare the assignment scope against the target resource ID character by character.

2. **Confirm the role definition really contains the action.** Role names are not self-explanatory.

    ```bash
    az role definition list --name "Reader" --query "[0].permissions[].{Actions:actions,NotActions:notActions}" --output json
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/role/definition#az-role-definition-list -->

    **Expected Result:** The `actions` list, and critically the `notActions` list. An action appearing in `notActions` is subtracted from the grant even though a wildcard in `actions` appears to include it.

3. **Check for a deny assignment.** This is the explanation most engineers never reach.

    ```bash
    SUB=$(az account show --query id --output tsv)
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show -->

    ```bash
    az rest --method get --url "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.Authorization/denyAssignments?api-version=2022-04-01" --query "value[].{Name:properties.denyAssignmentName,Actions:properties.permissions[].actions,Principals:properties.principals[].id}" --output json
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments-portal -->

    **Expected Result:** Either an empty list, or one or more deny assignments naming actions and principals. If one matches your user and the action they are attempting, that is the answer.

> **Key Insight:** A **deny assignment** always beats a role assignment. It does not matter that the user is Owner — a matching deny wins. Deny assignments are created by the Azure platform, most often by **Azure Blueprints** or by a **managed application** protecting the resources it owns, and they cannot be created or removed directly by an administrator. The remedy is to change whatever created it, not to grant more roles.

> **Common Pitfall:** `az role assignment list` does **not** return deny assignments — they are a different resource type, which is why the REST call above is necessary. Filtering the role assignment output for a `denyAssignment` field returns nothing regardless of whether a deny assignment exists, because no such field is present. A search that cannot succeed reads exactly like a clean result. In the portal, deny assignments appear under **Access control (IAM)** on their own **Deny assignments** tab.

4. **Rule out propagation delay** before changing anything.

    ```kql
    AzureActivity
    | where TimeGenerated > ago(7d)
    | where OperationNameValue contains "roleAssignments"
    | project TimeGenerated, OperationNameValue, ActivityStatusValue, Caller
    | order by TimeGenerated desc
    | take 50
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/azureactivity -->

    **Expected Result:** The history of role assignment changes, with timestamps and who made them. If the grant is only minutes old, wait — assignments are eventually consistent and can take several minutes to apply.

5. **State which of the four explanations applies.**

    **Expected Result:** Your finding names one of: wrong scope, the action excluded by `notActions`, a deny assignment overriding the grant, or propagation delay — with the evidence that distinguishes it from the other three.

---

## Part 2: Network Faults

### Task 3: Restore Connectivity from a Virtual Machine to Storage

**Goal:** Determine what blocks a virtual machine from reaching a storage endpoint, and name the specific rule responsible.

1. **Test the path and let Azure name the rule.** IP flow verify evaluates the effective security rules for a real packet, rather than making you read rule tables and simulate them mentally.

    ```bash
    az network watcher test-ip-flow --resource-group "${RG}" --vm "${VM}" --direction Outbound --protocol TCP --local 10.0.1.4:60000 --remote 20.150.0.0:443 --output table
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/network/watcher#az-network-watcher-test-ip-flow -->

    **Expected Result:** An `access` value of `Allow` or `Deny`, and when denied, the **name of the rule** that denied it. Substitute your machine's own private address for `--local`.

> **Key Insight:** IP flow verify names the deciding rule, which is what makes it worth reaching for first. Network security groups apply at both the **subnet** and the **network interface**, and a packet must be permitted by both — so a permissive NIC-level rule is worthless if the subnet denies. Reading two rule tables and combining them by hand is where mistakes happen; this command does that evaluation for you.

2. **Read the effective rules** if you need to see how the decision was reached.

    ```bash
    NIC=$(az vm show --resource-group "${RG}" --name "${VM}" --query "networkProfile.networkInterfaces[0].id" --output tsv)
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/vm#az-vm-show -->

    ```bash
    az network nic list-effective-nsg --ids "${NIC}" --output json
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/network/nic#az-network-nic-list-effective-nsg -->

    **Expected Result:** The combined rule set actually in force, merging subnet and interface rules with the platform defaults. This is the authoritative view — not the rules shown on either object alone.

3. **Check the storage account's own firewall.** A network security group is not the only thing that can refuse the connection.

    ```bash
    az storage account show --resource-group "${RG}" --name cf110storage01 --query "networkRuleSet.{Default:defaultAction,VNets:virtualNetworkRules[].id,IPs:ipRules[].ipAddressOrRange}" --output json
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/storage/account#az-storage-account-show -->

    **Expected Result:** If `Default` is `Deny`, the subnet must be listed in `VNets` for the connection to succeed.

4. **Check whether the subnet has the service endpoint** the firewall rule depends on.

    ```bash
    az network vnet subnet show --resource-group "${RG}" --vnet-name cf110-01-vnet --name cf110-01-subnet --query "{Name:name,ServiceEndpoints:serviceEndpoints[].service,PrivateEndpoints:privateEndpoints[].id}" --output json
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/network/vnet/subnet#az-network-vnet-subnet-show -->

    **Expected Result:** Either `Microsoft.Storage` present in `ServiceEndpoints`, or a private endpoint listed, or neither.

> **Key Insight:** A storage firewall rule that permits a virtual network works only if that subnet carries the matching **service endpoint**. Adding the virtual network rule without enabling the endpoint produces a configuration that reads correctly in the portal and still refuses every connection. The two settings live on different resources — the rule on the storage account, the endpoint on the subnet — which is why they drift apart.

5. **Record the fault and the fix.**

    **Expected Result:** Your notes name which layer refused the traffic — a network security group rule, the storage firewall, or a missing service endpoint — and the evidence that identifies it.

---

### Task 4: Diagnose a Failing Load Balancer Health Probe

**Goal:** Explain why a load balancer marks a working backend as unhealthy.

This is Lab 2 Task 4 in Azure form, and the underlying cause is the same shape: the probe never arrives.

1. **Read the probe configuration.**

    ```bash
    az network lb probe list --resource-group "${RG}" --lb-name cf110-01-lb --query "[].{Name:name,Protocol:protocol,Port:port,Path:requestPath,Interval:intervalInSeconds}" --output table
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/network/lb/probe#az-network-lb-probe-list -->

    **Expected Result:** The probe's protocol, port, path, and interval. Confirm the port matches the port the backend application actually listens on — a probe aimed at the wrong port fails exactly like a blocked one.

2. **Test the probe's path with IP flow verify**, using the platform's probe source address.

    ```bash
    az network watcher test-ip-flow --resource-group "${RG}" --vm cf110-01-backend --direction Inbound --protocol TCP --local 10.0.1.5:80 --remote 168.63.129.16:60000 --output table
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/network/watcher#az-network-watcher-test-ip-flow -->

    **Expected Result:** `Deny`, together with the name of the network security group rule responsible.

> **Key Insight:** Azure load balancer health probes originate from the fixed address **168.63.129.16**, a platform address used for probes, DHCP, and DNS. It is not in your virtual network and it is not the load balancer's frontend address, which is why a rule permitting your VNet address space does not admit probes. The correct rule permits the **`AzureLoadBalancer` service tag** as its source. The default network security group ruleset includes exactly such a rule — `AllowAzureLoadBalancerInBound` at priority 65001 — so this fault is nearly always a custom deny rule at a *lower* priority number overriding it.

3. **Check the rules in priority order.** Priority decides everything, and lower numbers win.

    ```bash
    az network nsg rule list --resource-group "${RG}" --nsg-name cf110-01-backend-nsg --query "sort_by([].{Priority:priority,Name:name,Access:access,Direction:direction,Source:sourceAddressPrefix,Port:destinationPortRange}, &Priority)" --output table
    ```
    <!-- source: https://learn.microsoft.com/en-us/cli/azure/network/nsg/rule#az-network-nsg-rule-list -->

    **Expected Result:** Rules ordered by priority. Find the first rule that matches inbound traffic on the probe port — that is the one that decides, and any later rule permitting the same traffic never runs.

4. **Look for the dropped probes in flow logs**, if Traffic Analytics is enabled.

    ```kql
    AzureNetworkAnalytics_CL
    | where TimeGenerated > ago(1h)
    | where FlowStatus_s == "D"
    | project TimeGenerated, SrcIP_s, DestIP_s, DestPort_d, NSGRules_s, FlowDirection_s
    | order by TimeGenerated desc
    | take 50
    ```
    <!-- source: https://learn.microsoft.com/en-us/azure/network-watcher/traffic-analytics-schema -->

    **Expected Result:** Denied flows from `168.63.129.16` to your backend on the probe port, naming the rule that dropped them. `FlowStatus_s == "D"` selects denied flows.

> **Common Pitfall:** Run this query **without** the `FlowStatus_s` filter first to confirm the table holds any rows at all. `AzureNetworkAnalytics_CL` exists only where Traffic Analytics is enabled on the flow log — enabling flow logs alone writes to a storage account and populates no Log Analytics table. An empty result here usually means Traffic Analytics was never switched on, not that no traffic was denied.

> **Note:** Network security group flow logs are being retired in favour of **virtual network flow logs**, which use a different schema. If your environment has been migrated, query `NTANetAnalytics` instead. Check which is in use before assuming a query is broken.

5. **Record the fix.** Add an inbound rule permitting source service tag `AzureLoadBalancer` on the probe port, at a priority **numerically lower** than the deny rule blocking it.

    **Expected Result:** Your notes name the rule to add, its priority relative to the blocking rule, and the flow log or IP flow verify output as evidence.

---

## Part 3: Escalation and Documentation

### Task 5: Escalate and Document

**Goal:** Produce an escalation an Azure on-call engineer can act on without re-investigating.

1. **Record each finding**, using the Lab 3 playbook fields.

    | Task | Likely root cause | Fix |
    |------|------------------|-----|
    | 1 — Key Vault refused | Wrong permission model checked, or a management role granted instead of a data-plane one | Match the remedy to `enableRbacAuthorization` |
    | 2 — RBAC not working | Wrong scope, `notActions` exclusion, deny assignment, or propagation delay | Depends which of the four applies |
    | 3 — Storage unreachable | NSG rule, storage firewall, or missing service endpoint | Name the layer that refused |
    | 4 — Probe failing | Custom rule at a lower priority overriding `AllowAzureLoadBalancerInBound` | Permit the `AzureLoadBalancer` service tag at a lower priority number |

2. **Classify severity and route accordingly.**

    | Issue type | Severity guidance | Escalation path |
    |------------|------------------|-----------------|
    | Security or access | Critical if production access is blocked | Security team and Cloud Ops |
    | Network connectivity | High if several services are affected | Network team |
    | Identity or authentication | Medium unless widespread | Identity team |
    | Performance degradation | Varies with impact scope | Cloud Ops |
    | Configuration error | Low if isolated | Standard ticket queue |

3. **Write the escalation.**

    **Expected Result:** It contains the full resource IDs, the subscription, the exact error codes observed, the command output or KQL results that prove the cause, the proposed fix, and an explicit list of what you ruled out.

> **Key Insight:** Two findings in this lab are things an administrator cannot simply fix by granting more access — a deny assignment must be resolved at whatever created it, and a retired flow log schema must be migrated. Escalations that recommend "grant the user Owner" when a deny assignment is in force waste a cycle and, if acted on, leave the account less secure with the original problem intact. Name the mechanism, not just the symptom.

---

## Troubleshooting Reference

| Issue | Symptom | Solution |
|-------|---------|----------|
| RBAC role added, no change | Key Vault still refuses after assigning a role | Check `enableRbacAuthorization`. If `false`, the vault honours access policies only and ignores RBAC |
| Access policy added, no change | Still refused after adding an access policy | The inverse of the above — if `enableRbacAuthorization` is `true`, access policies are ignored |
| Can list secrets, cannot read one | Names visible, values refused | `list` and `get` are separate permissions. Grant `get` |
| `AzureDiagnostics` empty for the vault | No Key Vault rows | A diagnostic setting sending **AuditEvent** to the workspace is missing |
| Deny assignment not found | Filtering role assignments for deny returns nothing | `az role assignment list` never returns deny assignments. Use the `denyAssignments` REST endpoint, or the portal's **Deny assignments** tab |
| Role assigned but still denied | Assignment visible and correct | Compare the assignment scope with the target resource ID; check `notActions`; then allow several minutes for propagation |
| `test-ip-flow` fails to run | Command errors rather than returning a verdict | Network Watcher must be enabled in that region, and the VM must be running |
| `test-connectivity` rejects the source | Error naming the source resource | The source must be a **virtual machine** with the Network Watcher extension. A load balancer cannot be a source |
| `AzureNetworkAnalytics_CL` missing | Table unresolved in the query editor | Traffic Analytics is not enabled. Flow logs alone write to storage and populate no table |
| Flow log table exists but is empty | Query returns nothing | Remove the `FlowStatus_s` filter and confirm any rows exist. Also check whether the environment migrated to `NTANetAnalytics` |
| Probe still failing after a rule change | Backend remains unhealthy | Confirm the new rule's priority number is **lower** than the deny rule, and that the source is the `AzureLoadBalancer` service tag |
| Wrong subscription | Resources not found although they exist | `az account set --subscription "<name-or-id>"`, then retry |

## Next Steps

You have now worked the same four fault shapes — compute, storage, identity, and network — in both AWS and Azure. The tools were different in every case and the method never changed: establish a baseline, eliminate layers with evidence, read the error precisely enough to tell similar failures apart, and record what you ruled out alongside what you found. Take the playbook entries from all four labs back to your own environment; they are the deliverable that outlives the class.

---

## Resources

- [Azure Key Vault RBAC guide](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide)
- [Key Vault access policies](https://learn.microsoft.com/en-us/azure/key-vault/general/assign-access-policy)
- [Key Vault logging](https://learn.microsoft.com/en-us/azure/key-vault/general/logging)
- [Understand Azure deny assignments](https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments)
- [List deny assignments in the Azure portal](https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments-portal)
- [Troubleshoot Azure RBAC](https://learn.microsoft.com/en-us/azure/role-based-access-control/troubleshooting)
- [Network Watcher IP flow verify](https://learn.microsoft.com/en-us/azure/network-watcher/ip-flow-verify-overview)
- [Network security groups](https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview)
- [Azure Load Balancer health probes](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-custom-probe-overview)
- [Traffic Analytics schema](https://learn.microsoft.com/en-us/azure/network-watcher/traffic-analytics-schema)
- [Virtual network service endpoints](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-network-service-endpoints-overview)

---

*Lab 4 Complete*
