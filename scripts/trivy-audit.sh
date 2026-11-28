#!/usr/bin/env bash
# CIATTO Trivy gate. Only approved, checksum-pinned scanner binaries.
set -euo pipefail
umask 077
fail() { printf '[trivy] %s\n' "$*" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)" || fail "repository required"
cd "$root"
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) expected=d89bcc6510a267f11b773398cbf1be5520ce39f9e8b6633178c4487f05b7d791 ;;
  Linux/aarch64|Linux/arm64) expected=fed2c9ca7d27191ada34524b5eaf5216a845c6d6f3246143c3b475552ffe5358 ;;
  Darwin/x86_64) expected=43ae1fd02532315b44a9d0496ae06326d5a1f3496cae26499be624807813fa8c ;;
  Darwin/arm64) expected=0ed07c205ca9ecc1065dc57b9f77adc79393bb469d9d1de9ec90c8c94ffc2f ;;
  *) fail "unsupported platform" ;;
esac
bin="${SECURITY_GATE_TOOLS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ciatto-security-gate/bin}/trivy"
if [ ! -x "$bin" ]; then bin="$(command -v trivy)" || fail "install pinned Trivy 0.74.0 via Ciatto Ops security gate"; fi
if command -v sha256sum >/dev/null; then actual="$(sha256sum "$bin" | awk '{print $1}')"
else actual="$(shasum -a 256 "$bin" | awk '{print $1}')"; fi
[ "$actual" = "$expected" ] || fail "unapproved Trivy binary"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
report_dir="$(git rev-parse --absolute-git-dir)/trivy-audit"
mkdir -p "$report_dir"
report="$(mktemp "$report_dir/report.XXXXXXXX")"
cat >"$tmp/template" <<'TPL'
{{- range . }}{{ $target := .Target }}
{{- range .Vulnerabilities }}
{{ .Severity }} {{ .VulnerabilityID }} {{ .PkgName }} {{ .InstalledVersion }} {{ .FixedVersion }}
{{- end }}
{{- range .Misconfigurations }}
{{ .Severity }} {{ .ID }}
{{- end }}
{{- range .Secrets }}
{{ .Severity }} secret {{ .RuleID }} line={{ .StartLine }}
{{- end }}
{{- end }}
TPL
mode="${1:-fs}"
case "$mode" in
  fs)
    sha="$(git rev-parse --verify "${2:-HEAD}^{commit}")"
    mkdir "$tmp/tree"
    GIT_INDEX_FILE="$tmp/index" git read-tree "$sha"
    GIT_INDEX_FILE="$tmp/index" git checkout-index -a -f --prefix="$tmp/tree/"
    target="$tmp/tree"
    ;;
  image)
    target="${2:-}"
    [[ "$target" =~ ^[a-zA-Z0-9._:/-]+@sha256:[0-9a-f]{64}$ ]] || fail "immutable OCI digest required"
    ;;
  *) fail "usage: bash scripts/trivy-audit.sh fs [commit] | image repository@sha256:digest" ;;
esac
# Do not honor repository or environment-supplied Trivy configuration/ignore rules.
# Exceptions must be handled separately by reviewed security policy.
printf '{}\n' >"$tmp/config.yaml"
: >"$tmp/empty.ignore"
printf 'mode=%s\ncommit_or_image=%s\nscanner=0.74.0\n' "$mode" "${sha:-$target}" >"$report"
set +e
# Explicit options and a clean environment prevent silent scanner suppression.
# Preserve HOME for the official cache and registry authentication; no secret values in output.
(
  while IFS='=' read -r name _; do case "$name" in TRIVY_*) unset "$name";; esac; done < <(env)
  cd "$tmp"
  "$bin" --config "$tmp/config.yaml" "$mode" --quiet --disable-telemetry --skip-version-check \
    --scanners vuln,secret,misconfig --severity HIGH,CRITICAL --exit-code 1 \
    --ignorefile "$tmp/empty.ignore" --format template --template "@$tmp/template" \
    --output "$tmp/findings" "$target" >"$tmp/scanner.log" 2>&1
)
rc=$?
set -e
if [ -f "$tmp/findings" ]; then cat "$tmp/findings" >>"$report"; fi
printf '\nexit=%s\n' "$rc" >>"$report"
printf '[trivy] %s: exit=%s report=%s\n' "$mode" "$rc" "$report" >&2
[ "$rc" -eq 0 ] || exit 1
