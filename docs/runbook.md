# Deployment runbook

Three phases, each an independent Argo CD Application. Phase 1 needs
nothing but a Git push.

| Phase | Argo source path | Prerequisites |
|---|---|---|
| 1 — operator | repo root (or `acm/01-operator`) | none |
| 2 — credentials | `acm/02-credentials` | Terraform, AWS, ESO on hub |
| 3 — sensors | `acm/03-sensors` | phase 2 Compliant |

---

## 0. Prerequisites

Phase 1 only needs:

- **RHACM 2.11+** on the hub (2.17 targeted). The floor is set by
  `OperatorPolicy` reaching GA; `.ManagedClusterLabels`,
  `spec.dependencies` and the propagator's hub-template watches all predate
  it.
- OpenShift GitOps (Argo CD) on the hub, with rights over ACM governance
  objects — check with the one-liner in [prereqs/README.md](../prereqs/README.md).
- The `global` ManagedClusterSet (default in MCE/ACM).
- Target clusters on **OpenShift 4.12+**. The certified bundle declares
  `com.redhat.openshift.versions: "v4.12"` with no upper bound, so 4.22 is
  in scope.

Phases 2 and 3 additionally need:

- External Secrets Operator on the hub, controller SA
  `external-secrets/external-secrets`.
- The hub's OIDC issuer registered as an IAM OIDC provider in AWS (ROSA and
  most OCP-on-AWS installs already have one).
- Outbound connectivity to the CrowdStrike cloud from every cluster running
  a sensor. A fully air-gapped cluster is out of scope.

Managed clusters need **no** ESO, no IAM role and no route to AWS — they
receive the credential from the hub through an ACM policy template.

---

# PHASE 1 — get the operator running

Nothing to configure. Push the repo into your app-of-apps `sources/` tree,
add your gate file, and point the generated Application at the **repo
root**. That renders phase 1 and only phase 1.

Confirm what will be applied before you push:

```bash
./scripts/validate.sh
kustomize build .        # 6 hub-side objects, no placeholders
```

Then verify it landed:

```bash
# hub
oc get policy falcon-operator -n falcon-governance
oc get placementdecision -n falcon-governance -o yaml | grep -A 20 'decisions:'

# any target cluster
oc get csv -n falcon-operator          # falcon-operator.v1.15.0 -> Succeeded
oc get sub,ip,og -n falcon-operator    # all created by OperatorPolicy
```

The operator is now installed and idle on every cluster. It does nothing
until a Falcon custom resource exists, which is phase 3.

Stop here for as long as you like. Everything below is phase 2 and 3.

---

# PHASE 2 — credentials

Terraform creates the secret; you type the value in by hand. No Falcon
credential ever touches Terraform, GitHub Actions, or this repository.

## 2a. Find your ESO role

The `aws-secrets-manager` ClusterSecretStore already exists, created by
other automation. Terraform does not create a role or touch ESO — it only
grants the role you already have read access to the new secret:

```bash
oc get clustersecretstore aws-secrets-manager                                  # READY must be True
oc get clustersecretstore aws-secrets-manager -o jsonpath='{.spec.provider.aws.role}{"\n"}'
```

If that prints nothing, ESO is using its ServiceAccount's own identity —
take the role from the SA annotation instead:

```bash
oc get sa -n <eso-namespace> <eso-sa> \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}'
```

## 2b. Create the secret

Set these under **Settings → Secrets and variables → Actions → Variables**.
None are secret — they are variables rather than committed values only so
the public tree names no real infrastructure:

| Variable | Example |
|---|---|
| `AWS_ROLE_ARN` | role the workflow assumes via OIDC |
| `AWS_REGION` | `eu-west-1` |
| `TF_STATE_BUCKET` | your existing state bucket |
| `TF_STATE_REGION` | region of that bucket — **not** necessarily `AWS_REGION` |
| `ESO_ROLE_ARNS` | `["arn:aws:iam::123456789012:role/external-secrets"]` |

`ESO_ROLE_ARNS` must be valid JSON — it is a list variable, and the
workflow passes it through as `TF_VAR_eso_role_arns`.

Then push to `main`, or run the **terraform** workflow manually. It plans on
PRs (commenting the plan) and applies only on `main`.

Locally instead:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars    # gitignored
$EDITOR terraform.tfvars                        # set eso_role_arns
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="key=crowdstrike-falcon/terraform.tfstate" \
  -backend-config="region=$TF_STATE_REGION"
terraform apply
```

Or keep those three lines in a gitignored `terraform/backend.hcl` and run
`terraform init -backend-config=backend.hcl`.

The state bucket's region is independent of `aws_region` — state can live
in one region while the secret is created in another. Do not "fix" a
mismatch by changing `aws_region`; that would move the secret away from the
region your ClusterSecretStore reads.

## 2c. Set the credential by hand

The workflow summary prints a direct console link. In **Secrets Manager →
your secret → Retrieve secret value → Edit**, replace both
`REPLACE_IN_CONSOLE` placeholders, keeping the JSON keys exactly:

```json
{
  "client_id":     "...",
  "client_secret": "..."
}
```

Terraform ignores changes to this value, so a later apply will not
overwrite it.

> `scripts/bw-to-aws.sh` does the same thing from a Bitwarden entry if you
> would rather not paste into a browser. Optional — the console is the
> supported path here.

---

## 2b. Deploy phase 2

Commit, then add a second gate file pointing an Application at
`acm/02-credentials`.

```bash
./scripts/validate.sh    # cross-checks the manifest against terraform state
git add -A && git commit -m "Falcon phase 2: credentials" && git push
```

Verify ESO populated the source Secret on the hub — everything downstream
reads from it:

```bash
oc get externalsecret falcon-api-credentials -n falcon-governance   # SecretSynced
oc get secret falcon-api-credentials -n falcon-operator             # on a spoke
```

---

# PHASE 3 — sensors

Label your ManagedClusters **first**, or every sensor tags as
`env/unlabeled`:

```bash
oc label managedcluster <name> env=prod region=eu-west-1 --overwrite
```

Review the tag list in `acm/03-sensors/policy-falcon-node-sensor.yaml`
against [sensor-tags.md](sensor-tags.md), decide the control-plane
tolerations question for ROSA Classic / ARO / OSD, then add a third gate
file pointing an Application at `acm/03-sensors`.

To pilot before going fleet-wide, narrow the Placement in
`acm/03-sensors/placement.yaml` — phases 1 and 2 can stay everywhere.

---

## 4. Watch it land

Hub:

```bash
oc get application falcon-governance -n openshift-gitops
oc get policies,placement,placementbinding,policyset -n falcon-governance

# Which clusters did the Placement actually select? If local-cluster is
# missing here, nothing downstream will reach the hub.
oc get placementdecision -n falcon-governance -o yaml | grep -A 20 'decisions:'
```

Confirm ESO populated the source Secret on the hub — everything downstream
reads from it:

```bash
oc get externalsecret falcon-api-credentials -n falcon-governance   # SecretSynced
oc get secret falcon-api-credentials -n falcon-governance \
  -o jsonpath='{.data.falcon-client-id}' | base64 -d | head -c 6; echo
```

Expect compliance to arrive in dependency order: `falcon-operator` →
`falcon-credentials` → `falcon-node-sensor`. Policies gated behind an unmet
`spec.dependencies` show as `Pending`, not `NonCompliant` — that is normal
while the stack comes up.

On a managed cluster:

```bash
oc get csv -n falcon-operator                     # falcon-operator.v1.15.0 Succeeded
oc get sub,ip,og -n falcon-operator               # all created by OperatorPolicy
oc get secret falcon-api-credentials -n falcon-operator   # copied by the policy
oc get falconnodesensor falcon-node-sensor -o yaml
oc get ds -n falcon-system                        # DESIRED == READY
oc get configmap falcon-node-sensor-config -n falcon-system \
  -o jsonpath='{.data.FALCONCTL_OPT_TAGS}{"\n"}'  # the resolved tags
```

Finally, confirm in the Falcon console that hosts appear with the expected
grouping tags.

---

## 5. Troubleshooting

**Placement selects nothing.**
Check the `ManagedClusterSetBinding` exists in `falcon-governance` and that
your clusters carry `vendor=OpenShift`:
`oc get managedcluster --show-labels`.

**`local-cluster` is missing from the decisions.**
It must be a real ManagedCluster (`oc get managedcluster local-cluster`) and
be a member of the `global` set. Self-managed hubs sometimes have
local-cluster import disabled entirely.

**CSV stuck in `Pending` / `InstallPlan` not approved.**
By design only the InstallPlan for `falcon-operator.v1.15.0` is approved. A
pending plan for a newer CSV is the pin working, not a fault. The
OperatorPolicy status spells out which it is:

```bash
oc get operatorpolicy falcon-operator -n <managed-cluster-name> \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
oc get installplan -n falcon-operator \
  -o custom-columns=NAME:.metadata.name,CSV:.spec.clusterServiceVersionNames,APPROVED:.spec.approved
```

If the *initial* install never gets approved, check that `startingCSV` and
`versions` name the same CSV. If they disagree, OLM builds a plan the policy
will never approve and the install wedges.

**CSV reports no OperatorGroup.**
The bundle supports `AllNamespaces` only, so the OperatorGroup must have an
empty `spec`. If `targetNamespaces` was added under
`spec.policy-templates[].objectDefinition.spec.operatorGroup`, OLM refuses
the CSV. Leave it out.

**Whole stack goes `Pending` after an operator hiccup.**
`falcon-credentials` and `falcon-node-sensor` declare `spec.dependencies` on
`falcon-operator` being Compliant. When it is not, ACM withdraws their
templates and they report Pending. Objects already created are kept —
every ConfigurationPolicy sets `pruneObjectBehavior: None`, so the sensor
keeps running — but enforcement pauses until the operator policy clears.
Check `complianceConfig` in the operator policy before tightening any of its
conditions; that is the mechanism that decides when this happens.

**`ExternalSecret` in `SecretSyncedError` (hub).**
Almost always IAM. In order:
`oc describe externalsecret falcon-api-credentials -n falcon-governance`,
then `oc logs -n external-secrets deploy/external-secrets`.
- `AccessDeniedException` on `GetSecretValue` — the ESO role is not in the
  secret's resource policy. Check `terraform output access_granted_to`
  against the store's actual role:
  `oc get clustersecretstore aws-secrets-manager -o jsonpath='{.spec.provider.aws.role}'`.
  If they differ, fix `eso_role_arns` and re-apply.
- `AccessDeniedException` mentioning **kms** — the CMK key policy does not
  grant that role. Same cause, same fix.
- `ResourceNotFoundException` — `remoteRef.key` does not match
  `var.secret_name`, or the secret is in a different region from the one
  the store points at. `./scripts/validate.sh` catches the name mismatch.
- `InvalidIdentityToken` on `AssumeRoleWithWebIdentity` — a problem in the
  pre-existing ClusterSecretStore, not in anything this repo owns. Other
  ExternalSecrets on the hub will be failing too; check with
  `oc get externalsecret -A`.

**Secret present on the hub but not on managed clusters.**
The hub template is failing. `oc describe policy falcon-credentials -n
falcon-governance` and check the propagator:
`oc logs -n open-cluster-management deploy/governance-policy-propagator`.
The usual cause is the Secret not being in the same namespace as the Policy —
ACM resolves hub templates only within the Policy's own namespace, which is
why ESO targets `falcon-governance` and not `falcon-operator`.

**Rotated the credential but managed clusters still have the old one.**
The propagator should re-propagate on its own via its dynamic watch. Force
it, then confirm whether the watch is working on your RHACM version:

```bash
oc annotate policy falcon-credentials -n falcon-governance \
  policy.open-cluster-management.io/trigger-update="$(date +%s)" --overwrite
```

If the forced update is the only thing that works, schedule it as a CronJob
on the hub.

**Operator logs `missing Falcon API credentials in secret`.**
The Secret exists but the keys are wrong. They must be literally
`falcon-client-id` and `falcon-client-secret`.

**Sensor pods `CrashLoopBackOff`.**
Check the `falcon-system` namespace still has
`pod-security.kubernetes.io/enforce: privileged` and
`security.openshift.io/scc.podSecurityLabelSync: "false"`. Something that
re-created the namespace without them will break the privileged DaemonSet.

**Hosts appear in the console untagged.**
An illegal character in a tag — see
[sensor-tags.md §3](sensor-tags.md#3-constraints). Compare the CR against the
rendered ConfigMap; if the ConfigMap has the tags but the console does not,
the sensor rejected them.

**Argo permanently `OutOfSync` on a Policy.**
ACM writes `status` back. The Application already ignores `/status` on
Policy, PolicySet and Placement; add any further noisy path to
`spec.ignoreDifferences`.

---

## 6. Changing things

| Change | Do this |
|---|---|
| Tags for one cluster | `oc label managedcluster <name> env=prod --overwrite` — no commit needed |
| Tags for the whole fleet | edit `spec.falcon.tags` in the node sensor policy; the DaemonSet rolls automatically |
| Add a cluster | import it into ACM with `vendor=OpenShift` — nothing else. No Terraform, no AWS, no commit |
| Operator version | in `policy-falcon-operator.yaml`, change `versions[0]` **and** `subscription.startingCSV` in one commit; `./scripts/validate.sh` fails if they disagree |
| Add KAC / IAR | uncomment in `acm/03-sensors/placement.yaml` (PolicySet) and `acm/03-sensors/kustomization.yaml`; widen API scopes first for IAR |
| Pause enforcement | set `spec.remediationAction: inform` on the Policy — it reports drift without correcting it |

**Removing a policy does not uninstall the sensor.** Every
`ConfigurationPolicy` sets `pruneObjectBehavior: None` deliberately, so an
accidental PolicySet edit cannot strip EDR off the fleet. Uninstalling is an
explicit act: delete the `FalconNodeSensor` CR on the target clusters first,
let the operator's cleanup DaemonSet run, then remove the policies.
