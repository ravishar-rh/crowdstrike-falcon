# Credentials: Bitwarden → AWS Secrets Manager → clusters

External Secrets Operator runs on the **ACM hub only**. Managed clusters never
talk to AWS, hold no IAM identity, and do not need ESO installed.

```
Bitwarden entry  ──(scripts/bw-to-aws.sh, once + on rotation)──▶  AWS Secrets Manager
                                                                         │
                       Terraform: secret, CMK, ONE IAM role,             │
                       resource policy naming only that role             │
                                                                         ▼
                                              ESO on the ACM hub (IRSA, no static keys)
                                                                         │
                                                                         ▼
                                        Secret falcon-api-credentials in falcon-governance
                                                                         │
                                        ACM Policy, {{hub fromSecret ... hub}}
                                        (value auto-encrypted in transit)
                                                                         │
                        ┌────────────────────────────┼────────────────────────────┐
                        ▼                            ▼                            ▼
                  local-cluster               managed cluster A            managed cluster B
            Secret in falcon-operator   Secret in falcon-operator   Secret in falcon-operator
                        │                            │                            │
                        ▼                            ▼                            ▼
                            FalconNodeSensor spec.falconSecret.enabled: true
```

Exactly one principal in the AWS account can read the credential. Adding a
managed cluster later needs no Terraform change at all.

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
| `client_id` / `client_secret` | the JSON above | `remoteRef.property` in `acm/hub/external-secrets.yaml` |
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
both `acm/hub/external-secrets.yaml` and
`acm/policies/policy-falcon-credentials.yaml`.

`scripts/validate.sh` compares the manifest against Terraform state when
state is reachable, so a renamed secret or a rebuilt role fails locally
rather than during an Argo sync.

---

## 3. Getting the credential out of Bitwarden

```bash
export BW_SESSION="$(bw unlock --raw)"

./scripts/bw-to-aws.sh \
  --bw-item 'CrowdStrike Falcon API' \
  --secret-id 'crowdstrike/falcon/api-credentials' \
  --region us-east-1
```

The script reads custom fields named `Client ID` and `Client Secret`, falling
back to `login.username` / `login.password`. Override with `--id-field` and
`--secret-field`. Use `--dry-run` to confirm it is finding the right fields
before writing — it prints lengths and a six-character prefix, never values.

The payload goes to the AWS CLI through a mode-0600 temp file on a cleaned-up
trap, so it is never an argv element visible in `ps`.

---

## 4. How the credential reaches managed clusters

`acm/policies/policy-falcon-credentials.yaml` carries:

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

The hub needs External Secrets Operator with its controller ServiceAccount at
`external-secrets/external-secrets`. Change `eso_namespace` /
`eso_service_account` in `terraform.tfvars` and the `serviceAccountRef` in
`acm/hub/external-secrets.yaml` if yours differs — the IAM trust policy pins
that exact ServiceAccount, so the two must agree or
`AssumeRoleWithWebIdentity` fails with `InvalidIdentityToken`.

Two things to check on an existing install:

- **API version.** The manifests use `external-secrets.io/v1`, the current
  stable version. On ESO older than v0.14, change the `apiVersion` on the
  `ClusterSecretStore` and `ExternalSecret` to `external-secrets.io/v1beta1`.
  Confirm with
  `oc get crd externalsecrets.external-secrets.io -o jsonpath='{.spec.versions[*].name}'`.
- **Token permission.** ESO's controller needs `create` on
  `serviceaccounts/token` for the referenced ServiceAccount to mint the
  projected token for `AssumeRoleWithWebIdentity`. The Helm chart and the
  operator bundle both grant this by default.

---

## 7. AWS side

Terraform (`terraform/`) creates:

- the Secrets Manager secret, optionally replicated to other regions;
- a customer-managed KMS key — chosen over `aws/secretsmanager` because an
  AWS-managed key cannot carry a key policy, so you cannot demonstrate in an
  audit which principals may decrypt the credential;
- **one IAM role**, for the hub's ESO ServiceAccount, trusting only the hub's
  OIDC issuer and only that exact subject;
- an identity policy scoped to this one secret ARN (not `secretsmanager:*` on
  `*`);
- a resource policy on the secret naming only that role, so account-level IAM
  reach alone is not enough to read it.

By default `manage_secret_value = false`: Terraform writes a `REPLACE_ME`
placeholder once and then ignores the value forever
(`lifecycle.ignore_changes`), so a later `terraform apply` cannot clobber the
live credential and the real value never enters state.

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
