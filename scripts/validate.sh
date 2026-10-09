#!/usr/bin/env bash
#
# Pre-commit sanity checks. Catches the mistakes that are otherwise only
# visible as a NonCompliant policy twenty minutes after a merge.
#
# Requires: kustomize (or oc/kubectl), python3. terraform is optional.
set -euo pipefail

cd "$(dirname "$0")/.."
fail=0

note() { printf '\n== %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }
ok()   { printf '  ok    %s\n' "$*"; }

note "kustomize entrypoints"
# Either path can be the Argo CD source, so both must build and both must
# produce the same thing. A drifted root kustomization would silently change
# what gets applied depending on which path the app-of-apps generator picked.
if command -v kustomize >/dev/null; then
  kb() { kustomize build "$1" 2>&1; }
elif command -v oc >/dev/null; then
  kb() { oc kustomize "$1" 2>&1; }
else
  kb() { return 1; }
fi

build=""
if root_out="$(kb .)" && acm_out="$(kb acm/)"; then
  ok "root builds ($(grep -c '^kind:' <<<"$root_out") objects)"
  ok "acm/ builds ($(grep -c '^kind:' <<<"$acm_out") objects)"
  if [[ "$root_out" == "$acm_out" ]]; then
    ok "root and acm/ render identically"
  else
    bad "root and acm/ render DIFFERENT output -- Argo result would depend on the configured path"
  fi
  build="$root_out"
elif command -v kustomize >/dev/null || command -v oc >/dev/null; then
  bad "kustomize build failed:"; printf '%s\n' "${root_out:-}" "${acm_out:-}"
else
  echo "  skip  no kustomize or oc on PATH"
fi

note "PolicySet membership matches the rendered policies"
# The quiet failure mode when enabling an add-on: add it to
# kustomization.yaml but not to the PolicySet and it is created on the hub
# and placed nowhere, or add it to the PolicySet but not kustomization.yaml
# and the set references a policy that does not exist. Neither errors --
# the policy just never reaches a cluster.
if [[ -n "$build" ]] && command -v ruby >/dev/null; then
  printf '%s' "$build" | ruby -ryaml -e '
    docs = YAML.load_stream(STDIN.read).compact
    rendered = docs.select { |d| d["kind"] == "Policy" }.map { |d| d["metadata"]["name"] }.sort
    set = docs.find { |d| d["kind"] == "PolicySet" }
    abort("  FAIL  no PolicySet rendered") unless set
    members = (set["spec"]["policies"] || []).sort
    missing = members - rendered
    orphan  = rendered - members
    bad = false
    missing.each { |n| puts "  FAIL  PolicySet lists #{n}, but no such Policy is rendered"; bad = true }
    orphan.each  { |n| puts "  FAIL  Policy #{n} is rendered but not in the PolicySet -- it will be placed nowhere"; bad = true }
    puts "  ok    #{members.size} policies, set and render agree" unless bad
    exit(bad ? 1 : 0)
  ' || fail=1
else
  echo "  skip  nothing rendered, or ruby not on PATH"
fi

note "YAML parses"
python3 -I - <<'PY' || fail=1
import pathlib, sys
try:
    import yaml
except ImportError:
    print("  skip  pyyaml not installed")
    sys.exit(0)
bad = 0
for p in sorted(pathlib.Path(".").rglob("*.yaml")):
    if ".terraform" in p.parts:
        continue
    try:
        list(yaml.safe_load_all(p.read_text()))
    except Exception as e:
        print(f"  FAIL  {p}: {e}")
        bad = 1
if not bad:
    print("  ok    all YAML parses")
sys.exit(bad)
PY

note "Falcon sensor tag characters"
# Falcon allows only alphanumerics, '/', '-', '_' in a grouping tag. Anything
# else is rejected at sensor init, which surfaces as a sensor that comes up
# untagged rather than as an obvious error -- hence this check.
python3 -I - <<'PY' || fail=1
import pathlib, re, sys
# Strip ACM template expressions first; what they resolve to is checked by the
# `| replace "." "-"` filters in the policies themselves.
tmpl = re.compile(r"\{\{hub.*?hub\}\}")
allowed = re.compile(r"^[A-Za-z0-9/_-]*$")
bad = 0
for p in sorted(pathlib.Path("acm").rglob("*.yaml")):
    intags = False
    for n, line in enumerate(p.read_text().splitlines(), 1):
        s = line.strip()
        if s.startswith("tags:"):
            intags = True
            indent = len(line) - len(line.lstrip())
            continue
        if intags:
            if not s.startswith("- "):
                if s and not s.startswith("#"):
                    intags = False
                continue
            val = tmpl.sub("", s[2:].strip().strip("'\""))
            if not allowed.match(val):
                print(f"  FAIL  {p}:{n}: illegal character in tag {s[2:]!r}")
                bad = 1
if not bad:
    print("  ok    all literal tag characters are legal")
sys.exit(bad)
PY

note "no credential material committed"
if grep -rnE "(client_secret|falcon-client-secret)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9]{20,}" \
     --include='*.yaml' --include='*.tf' --include='*.tfvars' --include='*.sh' . 2>/dev/null; then
  bad "something that looks like a real secret is committed"
else
  ok "no literal secrets found"
fi

note "version pin is consistent"
# OperatorPolicy pins in two places -- spec.versions[] and
# spec.subscription.startingCSV. If they disagree, OLM builds an InstallPlan
# the policy will never approve and the install wedges with no obvious cause.
pins="$(grep -rhoE 'falcon-operator\.v[0-9]+\.[0-9]+\.[0-9]+' acm/ | sort -u)"
if [[ "$(wc -l <<<"$pins")" -eq 1 ]]; then
  ok "versions[] and startingCSV both pin ${pins}"
else
  bad "mixed operator versions referenced (versions[] vs startingCSV?):"
  printf '        %s\n' $pins
fi

note "terraform"
if command -v terraform >/dev/null; then
  (cd terraform && terraform fmt -check -recursive >/dev/null) && ok "fmt clean" || bad "terraform fmt -recursive needed"
else
  echo "  skip  terraform not on PATH"
fi

note "acm/hub/external-secrets.yaml matches AWS"
# The manifest is hand-written so its comments survive review; this is what
# stops it drifting from what Terraform actually built. Silent no-op when
# there is no state yet (fresh clone, or CI without AWS credentials).
if command -v terraform >/dev/null \
   && tf_json="$(terraform -chdir=terraform output -json hub_secret_store_values 2>/dev/null)" \
   && [[ -n "$tf_json" && "$tf_json" != "null" ]]; then
  if command -v jq >/dev/null; then
    manifest="acm/hub/external-secrets.yaml"
    drift=0
    check() { # key, expected, grep-pattern
      local want; want="$(jq -r ".$1" <<<"$tf_json")"
      grep -qF "$want" "$manifest" || { bad "$1: manifest does not contain '${want}'"; drift=1; }
    }
    check region
    check role
    check secretName
    check esoNamespace
    check esoServiceAccount
    [[ $drift -eq 0 ]] && ok "manifest agrees with terraform state"
  else
    echo "  skip  jq not on PATH"
  fi
else
  echo "  skip  no terraform state (run terraform apply first)"
fi

echo
[[ $fail -eq 0 ]] && echo "All checks passed." || echo "Checks failed."
exit $fail
