# CrowdStrike Falcon Platform Operator v1.15.0 — ACM + GitOps

Deploys the **Red Hat certified** CrowdStrike Falcon Platform Operator
`v1.15.0` to the ACM hub (`local-cluster`) and every managed OpenShift
cluster, as RHACM policies delivered by OpenShift GitOps.

- API credentials come from **AWS Secrets Manager** via External Secrets
  Operator **on the hub only**. Managed clusters never touch AWS. Nothing
  sensitive is in Git or in Terraform state.
- **No provisioning tokens**, per security team standard.
- Sensor **grouping tags** are rendered per-cluster from ACM `ManagedCluster`
  labels.

Everything here was checked against the `v1.15.0` tag of
`CrowdStrike/falcon-operator` and the certified bundle in
`redhat-openshift-ecosystem/certified-operators`.

---

## Start here

| If you want to | Read |
|---|---|
| Understand tagging — the security team's question | **[docs/sensor-tags.md](docs/sensor-tags.md)** |
| Deploy it | [docs/runbook.md](docs/runbook.md) |
| Understand the credential path | [docs/credentials.md](docs/credentials.md) |

---

## Layout

```
kustomization.yaml       root entrypoint -- renders PHASE 1 ONLY
acm/
  01-operator/           the operator. Zero-touch, no prerequisites
  02-credentials/        Falcon API credentials via ESO + AWS. Needs Terraform first
  03-sensors/            FalconNodeSensor + tags. Needs phase 2
    optional/            KAC and Image Analyzer, off by default
prereqs/                 hub RBAC that must exist before the first sync -- NOT synced
terraform/               Secrets Manager secret, CMK, one IRSA role for the hub's ESO
scripts/                 bw-to-aws.sh (Bitwarden -> AWS), validate.sh (pre-commit checks)
docs/
```

## Deploying in phases

There is no `Application` manifest here — your app-of-apps generator makes
it. Each phase is a separate, independently syncable directory, so the
operator is up and running before you deal with credentials.

| Phase | Argo source path | Prerequisites | Result |
|---|---|---|---|
| **1** | repo root (or `acm/01-operator`) | **none** | operator v1.15.0 installed fleet-wide |
| 2 | `acm/02-credentials` | Terraform + AWS + ESO on hub | Falcon API credentials on every cluster |
| 3 | `acm/03-sensors` | phase 2 | sensor DaemonSet with per-cluster tags |

**Phase 1 is the drop-in.** Add your gate file, point the Application at the
repo root, and the operator installs on `local-cluster` and every managed
OpenShift cluster. Nothing to fill in — no AWS, no credentials, no `oc`
commands. The operator sits idle but running, ready for phase 2.

Add phases 2 and 3 later as their own Applications pointing at their own
directories. Each declares an ACM `spec.dependencies` on the phase before
it, so applying one early makes it report `Pending` rather than fail.

The root `kustomization.yaml` deliberately renders *only* phase 1. Without a
kustomization at the path root Argo falls back to directory mode, and
`recurse: true` would sweep up every phase at once — including credential
manifests still holding placeholder values.

**One real prerequisite.** Argo CD cannot create ACM `Policy` objects
without an RBAC grant, and an Application cannot grant itself the
permissions it needs to sync. The default `openshift-gitops` instance is
*not* cluster-admin, so this is not automatic — though most established
app-of-apps setups already have it. One command tells you:

```bash
oc auth can-i create policies.policy.open-cluster-management.io -A \
  --as system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
```

`yes` means you are done. `no` means apply
[prereqs/openshift-gitops-acm-rbac.yaml](prereqs/openshift-gitops-acm-rbac.yaml).

Argo CD only ever talks to the hub. It writes `Policy` objects; ACM does the
fan-out. Argo needs no credentials for the spokes.

---

## What gets installed

| Object | Value | Verified from |
|---|---|---|
| Package | `falcon-operator` | certified bundle `annotations.yaml` |
| Channel | `certified-1.0` | same (also the default channel) |
| CSV | `falcon-operator.v1.15.0` | bundle CSV `metadata.name` |
| Catalog | `certified-operators` / `openshift-marketplace` | — |
| Min OpenShift | `v4.12`, no upper bound → **4.22 supported** | `com.redhat.openshift.versions` |
| Install mode | **`AllNamespaces` only** | CSV `installModes` |
| Operator namespace | `falcon-operator` | this repo |
| Sensor namespace | `falcon-system` | `spec.installNamespace` |

Because `AllNamespaces` is the only supported mode, the OperatorGroup has an
empty `spec` (no `targetNamespaces`). Adding `targetNamespaces` makes OLM
refuse the CSV.

Version pinning is real, and enforced by `OperatorPolicy`:

| Setting | Effect |
|---|---|
| `versions: [falcon-operator.v1.15.0]` | only this CSV's InstallPlan is ever approved |
| `upgradeApproval: None` | upgrade InstallPlans are never approved; the *initial* install still is, so day one needs no human |
| `subscription.startingCSV` | the first InstallPlan targets 1.15.0 rather than the channel head |

Note there is deliberately **no** `installPlanApproval` in `spec.subscription`
— the controller rejects it (`installPlanApproval is prohibited in
spec.subscription`) because it owns that field, deriving `Manual` from the
two settings above.

A newer CSV sits unapproved and visible in the ACM console. Moving version is
a one-commit change to all three fields.

---

## Design decisions worth knowing

**Targets RHACM 2.17.** API versions in use: `Policy` and `PlacementBinding`
`policy.open-cluster-management.io/v1`; `PolicySet` and `OperatorPolicy`
`policy.open-cluster-management.io/v1beta1`; `Placement`
`cluster.open-cluster-management.io/v1beta1`; `ManagedClusterSetBinding`
`cluster.open-cluster-management.io/v1beta2`. All are the current served and
storage versions. No deprecated `PlacementRule` anywhere.

**`OperatorPolicy` for the operator install, not raw ConfigurationPolicy.**
It is the purpose-built kind for OLM operators — tech preview in RHACM 2.10,
GA in 2.11 — and owns the Subscription, OperatorGroup and InstallPlan
approval as one object, with native reporting of operator health, available
upgrades and deprecations. The ConfigurationPolicy equivalent needs a
hand-written `lookup`/`range` template to approve the right InstallPlan: more
YAML for strictly less behaviour. Requires a hub at 2.11 or newer.

**Plain Policy manifests, not ACM PolicyGenerator.** The generator is the
other common choice, but it requires kustomize alpha plugins in the
openshift-gitops repo-server, and it means the YAML in Git is not the YAML
that runs. For a control that auditors read, what-you-see-is-what-runs wins
over brevity.

**ESO on the hub only; ACM fans the credential out.** The hub's ESO writes
the Secret into `falcon-governance`, and a policy copies it to each cluster
with `{{hub fromSecret ... hub}}`. ACM automatically encrypts `fromSecret`
output with its `protect` function — the replicated Policy carries AES
ciphertext, with a distinct key per managed cluster rotated every 30 days,
decrypted on arrival. Exactly one IAM principal in the AWS account can read
the secret, and onboarding a managed cluster needs no AWS change at all.

**Rotation needs no manual step.** The policy propagator registers a dynamic
watch on every object referenced by a hub template and re-propagates when it
changes (`governance-policy-propagator`, `replicatedpolicy_controller.go`).
ESO updates the hub Secret, ACM pushes it out. Older material describing hub
templates as resolve-once, refreshed only by a `trigger-update` annotation,
describes OCM 0.9.x and earlier — not a 2.17 hub. The annotation still works
as a manual lever.

**This repo is public and contains no AWS identifiers.** The
`aws-secrets-manager` ClusterSecretStore already exists, created by other
automation, and carries the region, IAM role and account — so the
ExternalSecret here names none of them. `scripts/validate.sh` fails if a
real ARN ever appears under `acm/`.

**Terraform never holds the credential.** It creates the secret with
`REPLACE_IN_CONSOLE` placeholders and then ignores the value forever
(`lifecycle.ignore_changes`). The client ID and secret are typed into the
AWS console by hand, so nothing sensitive reaches Terraform state, a plan
output, or a GitHub Actions log. Terraform runs in CI via OIDC, so there
are no AWS keys in GitHub either.

**Terraform creates no IAM role.** It grants your existing ESO role read
access through the secret's resource policy and the KMS key policy, and
never modifies the role. Within one account either side may authorise, so
this is sufficient — and it keeps two automations from fighting over the
same object.

**`pruneObjectBehavior: None` everywhere.** Deleting a policy must not strip
EDR off the fleet. Argo prunes hub-side Policy objects; the objects those
policies created on managed clusters stay. The two settings do different
jobs — do not "align" them.

**Tags live in ManagedCluster labels, not in Git.** Retagging a cluster is
`oc label managedcluster ...`, which re-renders the policy and rolls the
DaemonSet. See [docs/sensor-tags.md](docs/sensor-tags.md).

---

## Before you deploy

Two things to decide, both covered in the runbook:

1. **Control-plane and infra nodes.** The default tolerations cover all node
   types, matching the operator's defaults. On **ROSA Classic, ARO, OSD and
   RHOIC** Red Hat does not support customer workloads there and this may
   affect your availability SLA — either accept an EDR gap with
   `node.tolerations: []`, or file a support exception. Not applicable to
   self-managed OpenShift or ROSA HCP.
2. **API scopes.** The node sensor needs only *Falcon Images Download: Read*
   and *Sensor Download: Read*. The optional Image Analyzer needs write
   access to your Falcon container registry — do not grant it pre-emptively.

---

## Checks

```bash
./scripts/validate.sh
```

Renders the kustomization, parses every YAML, checks literal sensor tags for
characters Falcon rejects, looks for committed secrets, and confirms every
reference pins the same operator version.
