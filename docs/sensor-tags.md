# Sensor grouping tags with the Falcon operator

> "tagging is done when the sensor is first initialized — both the linux and
> powershell scripts require the tags as an input parameter and handle setting
> it when it initializes the sensor"

That description is accurate, and it is also exactly what the operator does.
The operator is not a different tagging mechanism; it is a different way of
delivering the same `--tags` input to the same sensor initialization step.

This page traces the full path, documents the constraints, and explains how to
make tags cluster-specific across an ACM fleet.

---

## 1. The path a tag takes

| Step | Where | What happens |
|---|---|---|
| 1 | `FalconNodeSensor` CR | `spec.falcon.tags` — a **list of strings** |
| 2 | Operator | joins the list with commas into `FALCONCTL_OPT_TAGS` |
| 3 | ConfigMap `falcon-node-sensor-config` in `falcon-system` | holds `FALCONCTL_OPT_TAGS=a,b,c` |
| 4 | DaemonSet | consumes the ConfigMap via `envFrom` |
| 5 | Sensor container entrypoint | applies the `FALCONCTL_OPT_*` variables through `falconctl` at init |

Step 2 is this, in the v1.15.0 operator source
(`pkg/common/sensor_environment.go:40`):

```go
if len(falconSensor.Tags) > 0 {
    sensorConfig["FALCONCTL_OPT_TAGS"] = strings.Join(falconSensor.Tags, ",")
}
```

So `--tags "env/prod,cluster/foo"` in your Linux installer script and

```yaml
spec:
  falcon:
    tags:
      - env/prod
      - cluster/foo
```

in the CR land in the same place. The operator's job is to assemble the
`falconctl` option set and hand it to the sensor at the moment it initializes
— the same contract your scripts implement.

---

## 2. What is different from the script-based install

Your security team's model — "tags are set at first initialization" — carries
an implication on a bare-metal or VM host: changing tags later means running
`falconctl -s -f --tags=...` again and restarting the sensor. Someone has to
go do that.

With the DaemonSet, the sensor container initializes **every time the pod
starts**, and the operator restarts the pods for you when the tag set changes:

1. You change `spec.falcon.tags`.
2. The operator rewrites the ConfigMap and sets its internal `updated` flag
   (`falconnodesensor_controller.go:608`).
3. That flag reaches the DaemonSet reconcile branch at line 351, which calls
   `k8s_utils.RestartDaemonSet` (line 363).
4. Pods roll with `maxUnavailable: 1`. Each restarting sensor re-initializes
   and picks up the new tags.

The practical consequence: **tags are declarative here.** Edit one file, merge,
and the fleet converges. You do not need a separate re-tagging runbook.

Two caveats worth knowing:

- `/opt/CrowdStrike` is a hostPath mount, so the host's AID survives pod
  restarts. You are re-tagging an existing host identity, not registering a
  new one — which is what you want, but it does mean the host's history in
  the console follows it across a tag change.
- The roll is a real rolling restart of a privileged DaemonSet. Changing tags
  on a 500-node cluster is a 500-pod roll. Batch tag changes rather than
  trickling them in.

---

## 3. Constraints

**`tags` is an array, not a comma-separated string.** This trips people up
because the Helm chart and the installer scripts both take a single
comma-joined string. In the CRD:

```yaml
tags:
  items:
    type: string
  type: array
```

Writing `tags: "a,b"` fails CRD validation. Write:

```yaml
tags:
  - a
  - b
```

**Allowed characters: alphanumerics, `/`, `-`, `_`.** Straight from the CRD
description. In particular there are **no dots and no spaces**. This matters
more than it sounds, because several things you would naturally want to tag
with contain dots:

| Source | Raw value | Legal? |
|---|---|---|
| ManagedCluster name | `prod-use1` | yes |
| `region` label | `us-east-1` | yes |
| `openshiftVersion-major-minor` label | `4.22` | **no** — dot |
| `openshiftVersion` label | `4.22.3` | **no** — dots |
| A team name with a space | `platform security` | **no** — space |

An illegal tag does not produce a loud error. The sensor comes up *untagged*,
and you find out when a host group that should have matched is empty. The
policies in this repo pipe every label-derived value through
`replace "." "-"` for that reason, and `scripts/validate.sh` checks literal
tags for illegal characters before you commit.

**`/` is conventional, not special.** Falcon treats `env/prod` as an opaque
string; the slash is a convention that makes tags read hierarchically in the
console and in host group rules. This repo uses `prefix/value` throughout.

---

## 4. Per-cluster tags across an ACM fleet

The useful trick: ACM resolves `{{hub ... hub}}` templates separately for each
target cluster, so one policy produces a different tag set per cluster.

From `acm/03-sensors/policy-falcon-node-sensor.yaml`:

```yaml
tags:
  - platform/openshift
  - managed-by/falcon-operator
  - cluster/{{hub .ManagedClusterName hub}}
  - env/{{hub (index .ManagedClusterLabels "env" | default "unlabeled" | replace "." "-") hub}}
  - region/{{hub (index .ManagedClusterLabels "region" | default "unknown" | replace "." "-") hub}}
  - ocp/{{hub (index .ManagedClusterLabels "openshiftVersion-major-minor" | default "unknown" | replace "." "-") hub}}
```

On the hub this renders to:

```yaml
tags: [platform/openshift, managed-by/falcon-operator, cluster/local-cluster,
       env/hub, region/us-east-1, ocp/4-22]
```

and on a spoke labelled `env=prod,region=eu-west-1`:

```yaml
tags: [platform/openshift, managed-by/falcon-operator, cluster/prod-euw1,
       env/prod, region/eu-west-1, ocp/4-22]
```

Notes on the template functions:

- `.ManagedClusterName` — the ACM cluster name. The hub is `local-cluster`.
- `.ManagedClusterLabels` — the ManagedCluster's labels, available since
  ACM 2.8. Use `index` rather than dot access, because label keys contain
  characters Go templates will not accept as field names.
- `default "unlabeled"` — without it, a cluster missing the label yields an
  empty string and therefore a dangling `env/` tag.
- `replace "." "-"` — the sanitizer from §3.

**Tagging becomes a labelling exercise.** To move a cluster from
`env/staging` to `env/prod`, relabel the ManagedCluster:

```bash
oc label managedcluster prod-euw1 env=prod --overwrite
```

ACM re-renders the policy, the operator rewrites the ConfigMap, the DaemonSet
rolls, and the hosts re-register with the new tag. No Git commit, no CrowdStrike
console work. That is also the argument for keeping the authoritative mapping
in ManagedCluster labels rather than hardcoding tags per cluster in Git.

---

## 5. Coverage across the Falcon CRs

| CR | `spec.falcon.tags` | Notes |
|---|---|---|
| `FalconNodeSensor` | yes | the host sensors — the main case |
| `FalconAdmission` (KAC) | yes | also has `spec.clusterName` |
| `FalconContainer` | yes | sidecar sensor; not used in this repo |
| `FalconImageAnalyzer` (IAR) | **no** | no `falcon` block in the v1.15.0 CRD at all |

For IAR, identity comes from `spec.imageAnalyzerConfig.clusterName` instead.
Do not try to add a `tags` field to a FalconImageAnalyzer — the API server
rejects it.

---

## 6. Verifying

On a managed cluster, confirm what the operator actually generated:

```bash
oc get configmap falcon-node-sensor-config -n falcon-system \
  -o jsonpath='{.data.FALCONCTL_OPT_TAGS}{"\n"}'
```

Confirm the sensor container received them. Note the operator labels its pods
with `crowdstrike.com/*` keys, not `app=`:

```bash
POD=$(oc get pod -n falcon-system \
  -l crowdstrike.com/component=kernel_sensor -o name | head -1)
oc exec -n falcon-system "$POD" -- printenv FALCONCTL_OPT_TAGS
```

To ask the sensor itself rather than the environment, use `falconctl` from
inside the container (the path has moved between sensor releases, so locate
it rather than assuming):

```bash
oc exec -n falcon-system "$POD" -- sh -c \
  '$(command -v falconctl || echo /opt/CrowdStrike/falconctl) -g --tags'
```

Confirm ACM rendered per-cluster values as intended — the resolved policy
lives in each cluster's namespace on the hub:

```bash
oc get policy falcon-governance.falcon-node-sensor -n <managed-cluster-name> \
  -o yaml | grep -A 8 'tags:'
```

And in the Falcon console the tags appear under **Host setup and management →
Host management** as *Grouping Tags*, where you can build host groups with
dynamic assignment rules matching them.

---

## 7. Why there is no provisioning token anywhere

Per the security team's standard, no provisioning token is used. The operator
supports one at `spec.falcon.provisioning_token` (and as a
`falcon-provisioning-token` key in the credentials Secret); both are simply
omitted in this repo. The operator only reads them when present, so omission
is sufficient — there is nothing to disable.

Sensor installation is authorized by the Falcon API client credentials, which
is also what the operator uses to pull the sensor image and resolve the CID.

---

## 8. Source references

Checked against `CrowdStrike/falcon-operator` tag `v1.15.0`:

- `pkg/common/sensor_environment.go:40` — tag join into `FALCONCTL_OPT_TAGS`
- `internal/controller/assets/daemonset.go:226` — ConfigMap naming
- `internal/controller/assets/daemonset.go:330` — `envFrom` wiring
- `internal/controller/falcon_node/falconnodesensor_controller.go:351,363` — restart on config change
- `config/crd/bases/falcon.crowdstrike.com_falconnodesensors.yaml:98` — `tags` schema and allowed characters
