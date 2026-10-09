# Hub prerequisites

Things that must exist on the ACM hub **before** the Argo CD Application
syncs. They are not part of the synced tree on purpose — an Application
cannot grant itself the permissions it needs to sync.

If your app-of-apps platform already handles these, skip them. Check first;
both are the kind of thing a platform team usually sets up once.

---

## 1. Argo CD RBAC for ACM governance objects — required

`openshift-gitops-acm-rbac.yaml`

Out of the box the Argo CD application controller cannot create `Policy`,
`PolicySet`, `PlacementBinding`, `Placement` or `ManagedClusterSetBinding`.
Without this the sync fails with:

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

| Setting | Value | Why |
|---|---|---|
| `path` | the repo root, or `acm` | both carry a `kustomization.yaml` and render identically |
| `destination.server` | the hub (`https://kubernetes.default.svc`) | Argo only ever writes to the hub; ACM fans out to the spokes |
| `destination.namespace` | `falcon-governance` | |
| `syncPolicy.automated.prune` | safe to enable | removing a Policy from Git removes it from the hub, but never uninstalls the sensor — every ConfigurationPolicy sets `pruneObjectBehavior: None` |

Argo needs no credentials for managed clusters. It writes `Policy` objects to
the hub and ACM does the distribution.

The namespace `falcon-governance` is created by `acm/base/namespace.yaml`, so
`CreateNamespace=true` is not required.
