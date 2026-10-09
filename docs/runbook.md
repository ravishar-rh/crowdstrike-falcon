# Deployment runbook

Order matters: AWS first, then hub prerequisites, then Git, then Argo.

---

## 0. Prerequisites

On the ACM hub **only**:

- RHACM 2.17 is what this repo targets. The hard floor is **2.11**, set by
  `OperatorPolicy` reaching GA (tech preview in 2.10). Other features in use
  — `.ManagedClusterLabels`, `spec.dependencies`, the propagator's
  hub-template watches — all predate that.
- OpenShift GitOps (Argo CD) installed.
- The `global` ManagedClusterSet exists (default in MCE/ACM).
- External Secrets Operator, controller SA `external-secrets/external-secrets`.
- An OIDC issuer registered as an IAM OIDC provider in AWS (ROSA and most
  OCP-on-AWS installs already have one).

On every targeted cluster, including `local-cluster`:

- OpenShift 4.12+ — the certified bundle declares
  `com.redhat.openshift.versions: "v4.12"` with no upper bound, so 4.22 is in
  scope.
- Outbound connectivity to the CrowdStrike cloud. The sensor requires it; a
  fully air-gapped cluster is out of scope.

Managed clusters need **no** ESO, no IAM role and no route to AWS — they
receive the credential from the hub through an ACM policy template.

Collect the one input Terraform needs, from the hub:

```bash
oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}{"\n"}'
```

---

## 1. AWS

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars          # hub_oidc_issuer_url is the only required value
terraform init
terraform plan
terraform apply
```

Then write the real credential — this is the step that keeps it out of state:

```bash
export BW_SESSION="$(bw unlock --raw)"
cd ..
./scripts/bw-to-aws.sh \
  --bw-item 'CrowdStrike Falcon API' \
  --secret-id "$(terraform -chdir=terraform output -raw secret_name)" \
  --region us-east-1
```

Wire the hub manifest to what Terraform built:

```bash
terraform -chdir=terraform output hub_secret_store_values
$EDITOR acm/hub/external-secrets.yaml   # region, role, remoteRef.key
./scripts/validate.sh                   # confirms the two now agree
```

Those values are a role ARN, a region and a secret *name* — identities and
names, no credential material. Safe to commit.

---

## 2. Hub RBAC

Argo CD cannot manage ACM governance objects out of the box. This is a
prerequisite for the Application, so it cannot be managed by the Application:

```bash
oc apply -f prereqs/openshift-gitops-acm-rbac.yaml
```

Skip it if your platform already grants Argo CD rights over ACM governance
objects. See [prereqs/README.md](../prereqs/README.md) for what it covers and
for the `managedclustersets/bind` gotcha.

---

## 3. Commit into the app-of-apps repo

```bash
./scripts/validate.sh          # catches tag/pin/schema mistakes before the push
git add -A && git commit -m "CrowdStrike Falcon operator v1.15.0 via ACM" && git push
```

Drop the tree under your app-of-apps `sources/` directory and add whatever
gate file your generator expects. Point the resulting Application at the
**repo root or `acm/`** — both carry a `kustomization.yaml` and render the
same ten objects.

Do not point it at a parent directory with `recurse: true`. Kustomize mode is
what keeps `acm/policies/optional/` (KAC, Image Analyzer) from being applied
before you have widened the Falcon API scopes for them.

Sanity check what will be applied, from the path you are about to configure:

```bash
kustomize build .      # or: kustomize build acm/
```

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
- `InvalidIdentityToken` / `AccessDenied` on `AssumeRoleWithWebIdentity` —
  the role's `:sub` condition does not match the hub's ESO ServiceAccount, or
  the hub's OIDC provider is not registered in IAM. Check `eso_namespace` and
  `eso_service_account` against the real SA.
- `AccessDeniedException` on `GetSecretValue` — the role is not in the
  secret's resource policy, or the CMK policy denies it.
- `ResourceNotFoundException` — `remoteRef.key` does not match
  `var.secret_name`. `./scripts/validate.sh` catches this.

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
| Add KAC / IAR | uncomment in `acm/base/policyset.yaml` and `acm/kustomization.yaml`; widen API scopes first for IAR |
| Pause enforcement | set `spec.remediationAction: inform` on the Policy — it reports drift without correcting it |

**Removing a policy does not uninstall the sensor.** Every
`ConfigurationPolicy` sets `pruneObjectBehavior: None` deliberately, so an
accidental PolicySet edit cannot strip EDR off the fleet. Uninstalling is an
explicit act: delete the `FalconNodeSensor` CR on the target clusters first,
let the operator's cleanup DaemonSet run, then remove the policies.
