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

if command -v kustomize >/dev/null; then
  kb() { kustomize build "$1" 2>&1; }
elif command -v oc >/dev/null; then
  kb() { oc kustomize "$1" 2>&1; }
else
  kb() { return 1; }
fi

PHASES=(acm/01-operator acm/02-credentials acm/03-sensors)

note "each phase builds independently"
# Every phase is deployed as its own Argo CD Application, so each must
# render on its own -- a phase that only builds as part of a larger tree
# would fail the moment it is pointed at directly.
build=""
if command -v kustomize >/dev/null || command -v oc >/dev/null; then
  for p in "${PHASES[@]}"; do
    if out="$(kb "$p")"; then
      ok "$p ($(grep -c '^kind:' <<<"$out") objects)"
      build+="$out"$'\n---\n'
    else
      bad "$p failed to build:"; printf '%s\n' "$out"
    fi
  done
else
  echo "  skip  no kustomize or oc on PATH"
fi

note "root entrypoint is phase 1 only"
# The whole point of the drop-in: pointing Argo at the repo root must
# install the operator and nothing that needs a credential first.
if root_out="$(kb .)" && p1_out="$(kb acm/01-operator)"; then
  if [[ "$root_out" == "$p1_out" ]]; then
    ok "root renders exactly acm/01-operator"
  else
    bad "root does NOT match acm/01-operator -- the zero-touch drop-in is broken"
  fi
else
  echo "  skip  could not build"
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
    sets = docs.select { |d| d["kind"] == "PolicySet" }
    abort("  FAIL  no PolicySet rendered") if sets.empty?
    members = sets.flat_map { |s| s["spec"]["policies"] || [] }.sort
    bad = false
    (members - rendered).each { |n| puts "  FAIL  a PolicySet lists #{n}, but no such Policy is rendered"; bad = true }
    (rendered - members).each { |n| puts "  FAIL  Policy #{n} is rendered but in no PolicySet -- it will be placed nowhere"; bad = true }
    puts "  ok    #{members.size} policies across #{sets.size} sets, all accounted for" unless bad
    exit(bad ? 1 : 0)
  ' || fail=1
else
  echo "  skip  nothing rendered, or ruby not on PATH"
fi

note "OperatorPolicy subscription fields are legal"
# The controller decodes spec.subscription into an OLM SubscriptionSpec with
# DisallowUnknownFields, then explicitly rejects installPlanApproval because
# it derives that itself from upgradeApproval + versions. Both failures show
# up only as a NonCompliant policy on the hub, so catch them here.
if [[ -n "$build" ]] && command -v ruby >/dev/null; then
  printf '%s' "$build" | ruby -ryaml -e '
    # Valid SubscriptionSpec JSON tags, plus namespace which the controller
    # strips before decoding. installPlanApproval is valid OLM but banned
    # here, so it is listed to keep the dedicated message unduplicated.
    allowed = %w[name namespace channel source sourceNamespace startingCSV config installPlanApproval]
    bad = false
    YAML.load_stream(STDIN.read).compact
      .select { |d| d["kind"] == "Policy" }
      .flat_map { |d| d["spec"]["policy-templates"].map { |t| t["objectDefinition"] } }
      .select { |o| o["kind"] == "OperatorPolicy" }
      .each do |op|
        n   = op["metadata"]["name"]
        sub = op["spec"]["subscription"] || {}
        if sub.key?("installPlanApproval")
          puts "  FAIL  #{n}: installPlanApproval is prohibited in spec.subscription"; bad = true
        end
        (sub.keys - allowed).each do |k|
          puts "  FAIL  #{n}: unknown field spec.subscription.#{k}"; bad = true
        end
        %w[name namespace].each do |k|
          unless sub[k].to_s != "" then puts "  FAIL  #{n}: #{k} is required in spec.subscription"; bad = true end
        end
        unless (op["spec"]["operatorGroup"] || {})["name"].to_s != ""
          puts "  FAIL  #{n}: name is required in spec.operatorGroup"; bad = true
        end
        puts "  ok    #{n}: subscription and operatorGroup fields accepted" unless bad
      end
    exit(bad ? 1 : 0)
  ' || fail=1
else
  echo "  skip  nothing rendered, or ruby not on PATH"
fi

note "PlacementBinding subjects resolve"
# A binding naming a PolicySet that does not exist places nothing, silently.
if [[ -n "$build" ]] && command -v ruby >/dev/null; then
  printf '%s' "$build" | ruby -ryaml -e '
    docs = YAML.load_stream(STDIN.read).compact
    sets       = docs.select { |d| d["kind"] == "PolicySet" }.map { |d| d["metadata"]["name"] }
    placements = docs.select { |d| d["kind"] == "Placement"  }.map { |d| d["metadata"]["name"] }
    bad = false
    docs.select { |d| d["kind"] == "PlacementBinding" }.each do |b|
      ref = b["placementRef"]["name"]
      unless placements.include?(ref)
        puts "  FAIL  binding #{b["metadata"]["name"]} references missing Placement #{ref}"; bad = true
      end
      (b["subjects"] || []).each do |s|
        next unless s["kind"] == "PolicySet"
        unless sets.include?(s["name"])
          puts "  FAIL  binding #{b["metadata"]["name"]} references missing PolicySet #{s["name"]}"; bad = true
        end
      end
    end
    puts "  ok    all bindings resolve" unless bad
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

note "acm/02-credentials/external-secrets.yaml matches AWS"
# The manifest is hand-written so its comments survive review; this is what
# stops it drifting from what Terraform actually built. Silent no-op when
# there is no state yet (fresh clone, or CI without AWS credentials).
if command -v terraform >/dev/null \
   && tf_json="$(terraform -chdir=terraform output -json hub_secret_store_values 2>/dev/null)" \
   && [[ -n "$tf_json" && "$tf_json" != "null" ]]; then
  if command -v jq >/dev/null; then
    manifest="acm/02-credentials/external-secrets.yaml"
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
