# Azure Demo Environment — "OrderFlow on Azure"

The Azure half of the instructor demo set. It **mirrors the AWS demo stack fault for fault**, so
the same five investigations run in both clouds — different tooling, identical reasoning.

Chapters 6–10 teach Azure but have no labs. Lecturing a hundred-odd slides is a weak substitute
for showing a student the fault they diagnosed in AWS an hour ago, now in Azure. The claim the
whole course rests on is *the method transfers*. This is what makes that demonstrable instead of
asserted.

| | |
|---|---|
| **Deploys** | ~30 resources into one resource group |
| **Cost** | ~**$2.20/day** at defaults |
| **Region** | eastus (override with `-var="location=..."`) |
| **VNet CIDR** | `10.90.0.0/16` — distinct from the AWS demo (`10.80`) and the AWS labs (`10.60`) |

---

## The mapping — this is the teaching device

| Ch | The question | AWS answer | Azure answer |
|----|--------------|-----------|--------------|
| 6 | Is the service degraded? | ALB `UnHealthyHostCount` | LB `DipAvailability` |
| 7 | Host fault or guest fault? | EC2 status checks | Resource Health + boot diagnostics |
| 8 | Why is this identity refused? | Policy Simulator, `implicitDeny` | RBAC scope + control vs data plane |
| 9 | Why is the probe not arriving? | Security group has no ingress | NSG Deny rule outranks the platform default |
| 9 | Why can't this host reach out? | Route table has no `0.0.0.0/0` | Route table sends `0.0.0.0/0` to `None` |
| 10 | Why can it list but not read? | `s3:ListBucket` yes, `s3:GetObject` no | Reader yes, Storage Blob Data Reader no |

**The Chapter 8/10 pair is the sharpest teaching moment of the day**, and it is better in Azure
than in AWS. In AWS the missing permission is visibly absent from the policy document. In Azure
the identity holds **Reader** — a role whose name sounds entirely sufficient — the assignment
list looks generous, and the blob read still fails with `403 AuthorizationPermissionMismatch`.

An identity with **Contributor** on a storage account can delete the entire account and still not
read one blob. Say that out loud and watch the room.

---

## Deploy

```bash
az login                                    # interactive - MFA required
az account set --subscription "<name-or-id>"
SUB=$(az account show --query id -o tsv)

cd demo_environment_azure
terraform init
terraform apply -var="subscription_id=${SUB}"
terraform output -raw demo_handout
```

### Give it 20–30 minutes before demoing

| Signal | Ready after |
|--------|-------------|
| VMs boot and cloud-init installs nginx | ~4 min |
| LB backend settles to 1 healthy / 1 never joining | ~5 min |
| Resource Health reports | ~10 min |
| **Traffic Analytics populates `AzureNetworkAnalytics_CL`** | **20–30 min** |

Traffic Analytics is the one that catches people out. It aggregates on a 10-minute interval, and
the KQL table simply does not exist until the first batch lands. Deploy at the start of the day.

### Options

```bash
# NAT gateway, so the Ch9 routing fix can be applied live (~$1.10/day)
terraform apply -var="subscription_id=${SUB}" -var="create_nat_gateway=true"

# Skip flow logs. Note this breaks the Ch9 evidence step.
terraform apply -var="subscription_id=${SUB}" -var="create_flow_logs=false"
```

> **Network Watcher must exist in the region.** Azure normally auto-creates it in a resource
> group called `NetworkWatcherRG`; some subscriptions have it disabled. The config *references*
> it rather than creating it, so a missing one fails the apply rather than duplicating anything.
> Check first:
>
> ```bash
> az network watcher list --query "[?location=='eastus'].name" -o tsv
> ```

---

# Demo runbook

```bash
RG=$(terraform output -raw resource_group)
SA=$(terraform output -raw storage_account)
PRINCIPAL=$(terraform output -raw identity_principal_id)
LBIP=$(terraform output -raw lb_public_ip)
```

---

## Demo 6 — the method, in a second cloud

**Story:** "Same ticket as this morning. OrderFlow is degraded. Work the same five phases."

```bash
curl -s "http://${LBIP}/" | grep node        # it serves - so not down, maybe degraded

az network lb show -g "$RG" -n coo110-demo-lb \
  --query "backendAddressPools[].loadBalancerBackendAddresses[].name" -o tsv
```

Then in the portal: **Load balancer → Backend pools**, and **Insights** for `DipAvailability`.

**Expect:** two backends configured, one never reaching a healthy state; `DipAvailability` below
100.

> **Teaching point.** Identical logic to the AWS demo, different metric name. `UnHealthyHostCount`
> counts backends that failed; `DipAvailability` reports the percentage of probes that succeeded.
> Ask the room which they would rather alert on and why — it is a genuinely good argument.

---

## Demo 7 — host fault or guest fault, the Azure way

```bash
az vm get-instance-view -g "$RG" -n coo110-demo-web-b \
  --query "instanceView.statuses[].{code:code,status:displayStatus}" -o table
```

Then **Virtual machine → Resource health** in the portal, and **Boot diagnostics → Serial log**.

**Expect:** power state `VM running`, Resource Health **Available**, a clean boot log.

> **Teaching point — this is the rule-out again.** Azure splits what AWS calls the system status
> check into **Resource Health** (is the platform underneath healthy?) and what AWS calls the
> instance status check into **boot diagnostics and guest metrics**. Both report healthy here, so
> both layers are excluded — and that exclusion is a *result*, exactly as it was in Lab 1 Task 1.
>
> One genuine difference worth naming: Azure has no single "stop and start to move to new
> hardware" remedy. The equivalent is **Redeploy**, which moves the VM to a different host.

---

## Demo 8 — the role that sounds sufficient

```bash
az role assignment list --assignee "$PRINCIPAL" --all \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

**Expect:** `Reader` at the storage account, `Reader` at the resource group. Generous-looking.

Now try to actually read:

```bash
az storage blob download --account-name "$SA" --container-name orders \
  --name README.txt --file /tmp/out.txt --auth-mode login
```

**Expect:** `403` — `AuthorizationPermissionMismatch`.

> **Teaching point.** **Reader** is a *control-plane* role. It governs managing the resource
> through ARM: reading its settings, listing containers, seeing that it exists. It grants **no
> access to the data inside**. Blob reads with Entra ID need a *data-plane* role —
> `Storage Blob Data Reader` or `Storage Blob Data Contributor`.
>
> Map it back explicitly: this is the same shape as Lab 1 Task 3, where the role could
> `ListBucket` but not `GetObject`. The difference is that AWS showed you the gap in the policy
> document, and Azure hides it behind a role name that reads as adequate.
>
> Then read the two scopes. Azure RBAC inherits **downward only** — management group, then
> subscription, then resource group, then resource. A role granted on one resource group does
> nothing in a sibling.

The fix, scoped as narrowly as the workload allows:

```bash
az role assignment create --assignee "$PRINCIPAL" \
  --role "Storage Blob Data Reader" \
  --scope "$(az storage account show -g "$RG" -n "$SA" --query id -o tsv)"
```

> **Note.** Role assignments are eventually consistent. A workload that still fails immediately
> after this is not necessarily still misconfigured — wait a few minutes before changing anything
> else, or you will stack a second change on top of one that was already correct.

---

## Demo 9 — two faults, one loud and one silent

Run both halves together. The contrast is the lesson, exactly as in Lab 2.

### The loud one — probes denied

```bash
az network nsg rule list -g "$RG" --nsg-name coo110-demo-web-b-nsg \
  --query "sort_by([].{priority:priority,name:name,access:access,dir:direction,src:sourceAddressPrefix,port:destinationPortRange}, &priority)" -o table
```

**Expect:** a custom `DenyHttpInbound` at **priority 100**.

```bash
az network watcher test-ip-flow -g "$RG" --vm coo110-demo-web-b \
  --direction Inbound --protocol TCP --local 10.90.0.5:80 --remote 168.63.129.16:60000 -o table
```

**Expect:** `Deny`, naming the rule.

> **Teaching point, and it is not the same as AWS.** In AWS the target security group had *no
> rule*, so nothing permitted the probe. In Azure the platform **already permits** probe traffic
> by default — `AllowAzureLoadBalancerInBound` at priority **65001**. So a broken probe in Azure
> almost always means a custom rule at a **lower priority number** is overriding that default.
> Priority is the first thing to read, not the rule list.
>
> `168.63.129.16` is the fixed platform address Azure probes from. It is not in your VNet and not
> the load balancer's frontend IP, which is why a rule permitting your address space does not
> admit probes. Use the `AzureLoadBalancer` service tag.

Evidence, once Traffic Analytics has populated:

```
AzureNetworkAnalytics_CL
| where FlowStatus_s == "D" and DestPort_d == 80
| project TimeGenerated, SrcIP_s, DestIP_s, NSGRules_s
| take 20
```

> **Common Pitfall.** Run it **without** the `FlowStatus_s` filter first and confirm any rows
> exist. If the table is empty, Traffic Analytics has not aggregated yet — an empty result means
> "no matching records", which is equally consistent with a healthy network and with a table that
> was never populated. Same trap, both clouds.

### The silent one — a route to nowhere

```bash
az network nic show-effective-route-table \
  --ids "$(az vm show -g "$RG" -n coo110-demo-batch-worker --query 'networkProfile.networkInterfaces[0].id' -o tsv)" \
  -o table
```

**Expect:** `0.0.0.0/0` with next hop type **None**.

> **Teaching point.** Nothing logs. No NSG denies it, no flow log records it, no alarm fires —
> the packet has nowhere to go and is discarded. It is found by reading the **effective** routes,
> never by looking harder at the VM.
>
> Note *effective*: Azure merges system routes, custom route tables and any BGP routes. Reading
> the route table resource alone can mislead you; the effective view is the authoritative one.
> AWS has no direct equivalent — worth flagging as a genuine Azure advantage.

---

## Demo 10 — storage access, decided in the right order

```bash
az storage account show -g "$RG" -n "$SA" \
  --query "{name:name, sharedKey:allowSharedKeyAccess, publicNetwork:publicNetworkAccess, defaultAction:networkRuleSet.defaultAction}" -o table
```

**Expect:** shared keys **disabled**, `defaultAction` **Allow**.

> **Teaching point — read the error code, then eliminate in order.** Three things refuse a blob
> read in Azure and they produce different errors:
>
> | Error | Cause | Fix |
> |---|---|---|
> | `403 AuthorizationPermissionMismatch` | Missing data-plane RBAC role | Add Storage Blob Data Reader |
> | `403 AuthorizationFailure` | Storage firewall blocked the origin | Add the VNet rule + service endpoint |
> | `KeyBasedAuthenticationNotPermitted` | Shared keys disabled, tool used a key | Use `--auth-mode login` |
>
> Here the firewall is open and shared keys are off, so RBAC is the only control in play — which
> is what makes Demo 8's finding conclusive rather than merely plausible.
>
> The AWS parallel: listing succeeded while reading failed, ruling out every bucket-level control
> before a single policy was read. Same elimination, different vocabulary.

---

## Cost

| Component | Per day |
|-----------|---------|
| 3 × `Standard_B1s` | ~$0.75 |
| Standard Load Balancer + public IP | ~$0.70 |
| Log Analytics ingestion (demo volume) | ~$0.30 |
| Storage, flow logs, dashboard | ~$0.45 |
| **Default total** | **~$2.20** |
| NAT gateway, if enabled | +$1.10 |

```bash
terraform destroy -var="subscription_id=${SUB}"
```

Tear down the same day. The load balancer and its public IP bill continuously.
