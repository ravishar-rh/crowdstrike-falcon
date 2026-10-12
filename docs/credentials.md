# Credentials: AWS Secrets Manager → clusters

External Secrets Operator runs on the **ACM hub only**. Managed clusters never
talk to AWS, hold no IAM identity, and do not need ESO installed.

```
        GitHub Actions ──terraform (OIDC, no AWS keys)──▶ secret + CMK, empty
                                                                  │
         YOU, by hand in the console ──client_id/client_secret──▶  │
                                                                  ▼
                                                        AWS Secrets Manager
                                                                  │
                            existing "aws-secrets-manager" ClusterSecretStore
                                      (owned by other automation)
                                                                  ▼
                                                   ESO on the ACM hub
                                                                  │
                                                                  ▼
                              Secret falcon-api-credentials in falcon-governance
                                                                  │
                              ACM Policy, {{hub fromSecret ... hub}}
                              (value auto-encrypted in transit)
                                                                  │
               ┌──────────────────────────────┼──────────────────────────────┐
               ▼                              ▼                              ▼
         local-cluster                 managed cluster A              managed cluster B
   Secret in falcon-operator     Secret in falcon-operator     Secret in falcon-operator
               │                              │                              │
               ▼                              ▼                              ▼
                       FalconNodeSensor spec.falconSecret.enabled: true
```

Two properties worth stating plainly, because they are what let this
repository be public:

- **The credential only ever exists in two places** — the Falcon console and
  AWS Secrets Manager. It is typed in by hand. It is not in Git, not in
  Terraform state, not in a plan output, not in a CI log.
- **No AWS identifier appears in this repo.** The ClusterSecretStore already
  exists and carries the region, role and account, so the ExternalSecret
  names none of them. `scripts/validate.sh` fails the build if a real ARN
  ever lands under `acm/`.

Adding a managed cluster later needs no AWS change at all.

---

## 1. The Falcon API client

Create the API client at **Support and resources → API clients and keys** in
the Falcon console.

Scopes, per the operator's own OpenShift documentation:

| Component | Scope | Level |
|---|---|---|
| FalconNodeSensor | Falcon Images Download | Read |
| FalconNodeSensor | Sensor Download | Read |
| FalconAdmission (KAC) | *same two as above* | — |
| FalconImageAnalyzer (IAR) | Falcon Images Download | Read |
| FalconImageAnalyzer (IAR) | Falcon Container Image | Read/Write |
| FalconImageAnalyzer (IAR) | Falcon Container CLI | Write |

If you are not enabling IAR, grant only the first two. The IAR scopes include
write access to your Falcon container image registry, which is not something
to hand out pre-emptively.

No provisioning token is created or used — see
[sensor-tags.md §7](sensor-tags.md#7-why-there-is-no-provisioning-token-anywhere).

---

## 2. Secret payload shape

A single JSON document in Secrets Manager:

```json
{
  "client_id":     "...",
  "client_secret": "..."
}
```

Three names have to agree, and nothing will tell you if they do not:

| Name | Set in | Must match |
|---|---|---|
| `client_id` / `client_secret` | the JSON above | `remoteRef.property` in `acm/02-credentials/external-secrets.yaml` |
| secret name | Terraform `var.secret_name` | `remoteRef.key` in the same file |
| `falcon-client-id` / `falcon-client-secret` | `ExternalSecret.spec.data[].secretKey` | **fixed by the operator — do not change** |

That last row is not a convention. falcon-operator v1.15.0 reads exactly these
keys from the Secret when `spec.falconSecret.enabled` is true
(`pkg/falcon_secret/falcon_secret.go`):

```
falcon-client-id
falcon-client-secret
falcon-cid                 (optional; derived from the API key when absent)
falcon-provisioning-token  (unused here)
```

Rename them and the operator reports missing credentials. The same two key
names are what the ACM policy templates read on the hub, so they appear in
both `acm/02-credentials/external-secrets.yaml` and
`acm/02-credentials/policy-falcon-credentials.yaml`.

`scripts/validate.sh` compares the ExternalSecret's `remoteRef.key` against
the `secret_name` default in `terraform/variables.tf`, so a rename on one
side fails locally rather than as an ESO `ResourceNotFoundException`.

---

## 3. Setting the credential

By hand, once, in the AWS console. Terraform created the secret with
placeholders; you replace them.

**Secrets Manager → your secret → Retrieve secret value → Edit**, then
replace both `REPLACE_IN_CONSOLE` values, keeping the JSON keys exactly as
they are — they are what the ExternalSecret reads:

```json
{
  "client_id":     "...",
  "client_secret": "..."
}
```

The terraform workflow prints a direct link to the secret in its run
summary.

Terraform ignores changes to this value (`lifecycle.ignore_changes`), so a
later apply will not overwrite it.

> Optional alternative: `scripts/bw-to-aws.sh` writes the same payload
> straight from a Bitwarden entry, if you would rather not paste a
> credential into a browser. It passes the value to the AWS CLI through a
> mode-0600 temp file on a cleaned-up trap, so it is never visible in `ps`.
> Use `--dry-run` first — it prints lengths and a six-character prefix,
> never values.

---

## 4. How the credential reaches managed clusters

`acm/02-credentials/policy-falcon-credentials.yaml` carries:

```yaml
data:
  falcon-client-id: '{{hub fromSecret "falcon-governance" "falcon-api-credentials" "falcon-client-id" hub}}'
  falcon-client-secret: '{{hub fromSecret "falcon-governance" "falcon-api-credentials" "falcon-client-secret" hub}}'
```

**The value is encrypted in transit.** ACM automatically passes `fromSecret`
output through its `protect` function, so what lands in the replicated Policy
is AES ciphertext, not the key. ACM holds a distinct encryption key per
managed cluster and rotates it every 30 days; the value is decrypted on the
managed cluster immediately before the Secret is written.

Do not rewrite these as `stringData` with a plain `lookup`. That would place
the Falcon API key in cleartext in a Policy object in hub etcd and in every
managed cluster namespace on the hub — and Policy objects are not covered by
OpenShift's etcd encryption.

**The Secret has to live in `falcon-governance`.** ACM resolves hub templates
only against objects in the Policy's own namespace. That is the only reason
the ESO target namespace is the governance namespace rather than something
more intuitive like `falcon-operator` on the hub.

RHACM also offers `spec.hubTemplateOptions.serviceAccountName`, which
resolves templates as a named ServiceAccount and can relax the same-namespace
rule. It is deliberately not used here — same-namespace is the smaller blast
radius.

---

## 5. Rotation

There is no manual propagation step. The ACM policy propagator registers a
**dynamic watch** on every object referenced by a hub template and
re-propagates affected policies when that object changes
(`governance-policy-propagator`, `replicatedpolicy_controller.go` — the
watcher it maintains is logged as "dynamic watches for the hub policy
templates"). So:

1. Rotate the API client in the Falcon console; update the Bitwarden entry.
2. Re-run `scripts/bw-to-aws.sh` — this creates a new `AWSCURRENT` version.
3. Within ESO's `refreshInterval` (1h) the hub Secret updates.
4. ACM notices and re-renders the credentials policy to every cluster on its
   own.

To force step 3 on the hub:

```bash
oc annotate externalsecret falcon-api-credentials -n falcon-governance \
  force-sync="$(date +%s)" --overwrite
```

To force step 4:

```bash
oc annotate policy falcon-credentials -n falcon-governance \
  policy.open-cluster-management.io/trigger-update="$(date +%s)" --overwrite
```

> Older documentation — including some ZTP/PolicyGenerator pages that are
> still live — states that hub templates resolve only at policy creation or
> update and must be refreshed with `trigger-update`. That described OCM
> 0.9.x and earlier, not a 2.17 hub. The annotation remains useful as a
> manual lever; it is no longer a requirement. Worth confirming once with a
> test rotation anyway, since it is cheap and this is the credential path.

The sensor DaemonSet does **not** need to roll on a credential change. These
credentials are used by the operator to talk to the CrowdStrike API and pull
images; the running sensor authenticates with its own CID and AID.

---

## 6. ESO prerequisite (hub only)

The `aws-secrets-manager` ClusterSecretStore already exists on the hub,
created by other automation and already syncing secrets for other
workloads. This repo only consumes it — it ships no store of its own.

That is deliberate and it is what keeps a public repo clean: the region,
the IAM role ARN and the AWS account ID all live in that store, so
`acm/02-credentials/external-secrets.yaml` contains no AWS identifier at
all. `scripts/validate.sh` enforces this — it fails if any real ARN appears
under `acm/`.

Before deploying phase 2:

```bash
oc get clustersecretstore aws-secrets-manager      # READY must be True
```

If yours is named differently, change `secretStoreRef.name` in
`acm/02-credentials/external-secrets.yaml`.

One thing to check on an older install: the manifest uses
`external-secrets.io/v1`, the current stable version. On ESO older than
v0.14 change it to `external-secrets.io/v1beta1`. Confirm with
`oc get crd externalsecrets.external-secrets.io -o jsonpath='{.spec.versions[*].name}'`.

---

## 7. AWS side

Terraform (`terraform/`) creates only two things:

- the Secrets Manager secret, optionally replicated to other regions;
- a customer-managed KMS key — chosen over `aws/secretsmanager` because an
  AWS-managed key cannot carry a key policy, so you cannot demonstrate in an
  audit which principals may decrypt the credential.

It grants your existing ESO role read access through the secret's
**resource policy** and the KMS key policy. It creates no IAM role, no OIDC
provider, and attaches nothing — the role stays wholly owned by whichever
automation set up ESO. Within one account a request is authorised if either
the identity policy or the resource policy allows it, so naming the role on
the resource side is sufficient and avoids two Terraform stacks fighting
over the same object.

**The credential never passes through Terraform.** It writes
`REPLACE_IN_CONSOLE` once and then ignores the value forever
(`lifecycle.ignore_changes`). You type the real client ID and secret into
the Secrets Manager console by hand. Nothing sensitive reaches Terraform
state, a plan output, a tfvars file, or the GitHub Actions log — which is
what makes the public repo and the CI pipeline safe.

Terraform runs in GitHub Actions via OIDC, so there are no AWS keys in
GitHub either. See [terraform/README.md](../terraform/README.md).

---

## 8. If a managed cluster ever does need direct AWS access

The alternative topology — ESO on every cluster, each with its own IAM role,
reading AWS directly — removes hub templates from the credential path
entirely. It costs one IAM role and one OIDC trust per cluster, and requires
ESO everywhere.

It is not used here and the manifests for it are not in this repo. If you
adopt it later for a subset of clusters, the change is: a `ClusterSecretStore`
plus `ExternalSecret` shipped by policy to those clusters, a per-cluster role
map in Terraform, and dropping those clusters from the Placement that binds
`falcon-credentials`.
