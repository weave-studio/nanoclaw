#!/usr/bin/env bash
# NanoClaw Container Run Script
# Runs the NanoClaw container with maximum security flags
#
# Usage: ./deploy/container-run.sh
#
# This is a reference for the Podman flags used. In production,
# NanoClaw spawns containers itself via container-runner.ts.
# These flags should be applied there.

set -euo pipefail

CONTAINER_NAME="nanoclaw-agent"
IMAGE="nanoclaw-agent:latest"
NANOCLAW_HOME="$HOME/nanoclaw"

podman run -d \
  --name "$CONTAINER_NAME" \
  --read-only \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  --memory=512m \
  --cpus=1 \
  --pids-limit=256 \
  --tmpfs /tmp:rw,noexec,nosuid,size=100m \
  -e TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)" \
  -v "$NANOCLAW_HOME/groups:/workspace/groups:Z" \
  "$IMAGE"

echo "Container started: $CONTAINER_NAME"
echo ""
echo "Security flags applied:"
echo "  --read-only          Immutable container filesystem"
echo "  --no-new-privileges  No privilege escalation"
echo "  --cap-drop=ALL       No Linux capabilities"
echo "  --memory=512m        Memory limit"
echo "  --cpus=1             CPU limit"
echo "  --pids-limit=256     Process count limit"
echo "  --tmpfs /tmp         Writable tmp (noexec, 100MB)"
echo ""
echo "Verify: podman inspect $CONTAINER_NAME | grep -i 'readonly\|privilege\|cap'"
