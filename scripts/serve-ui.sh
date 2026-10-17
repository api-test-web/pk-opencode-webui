#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: scripts/serve-ui.sh [uptime_minutes] [opencode_version]

Dispatches the Serve Web UI workflow and prints its Cloudflare quick-tunnel URL.
The GitHub CLI must be installed and authenticated (gh auth login).
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

uptime_minutes=${1:-300}
opencode_version=${2:-1.19.3}
workflow=.github/workflows/serve-ui.yml
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
started_at=$(date -u +%s)

case "$uptime_minutes" in
  ''|*[!0-9]*)
    echo "uptime_minutes must be a positive integer" >&2
    exit 2
    ;;
esac

echo "Dispatching $workflow in $repo..." >&2
gh workflow run "$workflow" \
  --repo "$repo" \
  --ref main \
  -f "uptime_minutes=$uptime_minutes" \
  -f "opencode_version=$opencode_version"

run_id=""
for _ in $(seq 1 30); do
  run_id=$(gh run list \
    --repo "$repo" \
    --workflow "$workflow" \
    --event workflow_dispatch \
    --limit 10 \
    --json databaseId,createdAt \
    --jq '.[] | select((.createdAt | fromdateiso8601) >= '"$started_at"') | .databaseId' \
    | head -1 || true)
  [ -n "$run_id" ] && break
  sleep 2
done

if [ -z "$run_id" ]; then
  echo "Could not find the dispatched workflow run." >&2
  exit 1
fi

echo "Watching workflow run $run_id..." >&2
artifact_dir=$(mktemp -d ".serve-ui.XXXXXX")
trap 'rm -rf "$artifact_dir"' EXIT
for _ in $(seq 1 180); do
  artifact_url=$(gh api \
    "repos/$repo/actions/runs/$run_id/artifacts" \
    --jq '.artifacts[] | select(.name == "tunnel-url" and .expired == false) | .archive_download_url' \
    | head -1 || true)
  if [ -n "$artifact_url" ]; then
    gh api "$artifact_url" > "$artifact_dir/tunnel.zip" 2>/dev/null || true
    url=$(unzip -p "$artifact_dir/tunnel.zip" tunnel-url.txt 2>/dev/null \
      | grep -oE 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' \
      | head -1 || true)
    if [ -n "$url" ]; then
      printf '%s\n' "$url"
      exit 0
    fi
  fi

  url=$(gh run view "$run_id" --repo "$repo" --log 2>/dev/null \
    | grep -oE 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' \
    | head -1 || true)
  if [ -n "$url" ]; then
    printf '%s\n' "$url"
    exit 0
  fi

  status=$(gh run view "$run_id" --repo "$repo" --json status --jq .status 2>/dev/null || true)
  case "$status" in
    completed|cancelled|failure|timed_out|startup_failure)
      echo "Workflow run $run_id ended with status: $status" >&2
      gh run view "$run_id" --repo "$repo" --log-failed >&2 || true
      exit 1
      ;;
  esac
  sleep 2
done

echo "Timed out waiting for a Cloudflare tunnel URL from run $run_id." >&2
echo "View it with: gh run view $run_id --repo $repo --log" >&2
exit 1
