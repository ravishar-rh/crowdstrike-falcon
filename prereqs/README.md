# Hub prerequisites

Things that must exist on the ACM hub **before** the Argo CD Application
syncs. They are not part of the synced tree on purpose — an Application
cannot grant itself the permissions it needs to sync.

If your app-of-apps platform already handles these, skip them. Check first;
both are the kind of thing a platform team usually sets up once.

---

## 1. Argo CD RBAC for ACM governance objects — required

`openshift-gitops-acm-rbac.yaml`

**Check first — many app-of-apps setups already have this:**

```bash
oc auth can-i create policies.policy.open-cluster-management.io -A \
  --as system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
```

`yes` → skip this section. `no` → read on.

The default `openshift-gitops` instance is **not** cluster-admin. The
operator grants it a fixed set of cluster-scoped permissions that does not
include ACM governance CRDs, so unless someone has already widened it (with
`oc adm policy add-cluster-role-to-user cluster-admin -z ...`, an
`ARGOCD_CLUSTER_CONFIG_NAMESPACES` setup, or a custom role), the application
controller cannot create `Policy`, `PolicySet`, `PlacementBinding`,
`Placement` or `ManagedClusterSetBinding`.

Without it the sync fails with:

```
policies.policy.open-cluster-management.io is forbidden:
  User "system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller"
  cannot create resource "policies"
```

```bash
oc apply -f prereqs/openshift-gitops-acm-rbac.yaml
```

Note the `managedclustersets/bind` rule. Creating a `ManagedClusterSetBinding`
needs the `bind` verb on the target `ManagedClusterSet` as well as create on
the binding itself — a virtual subresource that is easy to miss, and the
resulting denial names the binding rather than the set.

Adjust the ServiceAccount subject if your Argo CD instance is not the default
`openshift-gitops` one.

---

## 2. Ignoring ACM status churn — only if you see it

Not applied by default, and not in a file, because it is probably
unnecessary: Argo diffs only the fields you declare, and nothing here
declares `status`.

If the Falcon Application does sit permanently `OutOfSync` on `Policy` or
`Placement`, the fix belongs at the Argo CD instance level rather than on the
Application — you do not control the generated Application spec in an
app-of-apps setup. Patch the `ArgoCD` CR:

```yaml
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: openshift-gitops
  namespace: openshift-gitops
spec:
  resourceIgnoreDifferences:
    resourceIdentifiers:
      - group: policy.open-cluster-management.io
        kind: Policy
        customization:
          jsonPointers:
            - /status
      - group: policy.open-cluster-management.io
        kind: PolicySet
        customization:
          jsonPointers:
            - /status
      - group: cluster.open-cluster-management.io
        kind: Placement
        customization:
          jsonPointers:
            - /status
```

This is instance-wide and affects every Application on that Argo CD, so raise
it with whoever owns the instance rather than applying it unilaterally.

---

## 3. What the Application itself needs

Whatever your app-of-apps generator produces, these are the only settings
that matter for this repo:

One Application per phase, each pointing at its own path:

| Phase | `path` |
|---|---|
| 1 — operator | repo root, or `acm/01-operator` |
| 2 — credentials | `acm/02-credentials` |
| 3 — sensors | `acm/03-sensors` |

Settings that matter, the same for all three:

| Setting | Value | Why |
|---|---|---|
| `destination.server` | the hub (`https://kubernetes.default.svc`) | Argo only ever writes to the hub; ACM fans out to the spokes |
| `destination.namespace` | `falcon-governance` | |
| `syncPolicy.automated.prune` | safe to enable | removing a Policy from Git removes it from the hub, but never uninstalls the sensor — every ConfigurationPolicy sets `pruneObjectBehavior: None` |

Do **not** point an Application at a parent directory with `recurse: true`.
That bypasses the per-phase kustomizations and applies every phase at once,
including credential manifests that still hold placeholder values.

Argo needs no credentials for managed clusters. It writes `Policy` objects to
the hub and ACM does the distribution.

The namespace `falcon-governance` is created by phase 1
(`acm/01-operator/governance.yaml`), so `CreateNamespace=true` is not
required. Phases 2 and 3 rely on phase 1 having created it, and on the
`global` ManagedClusterSetBinding from the same file — deploy phase 1 first.
