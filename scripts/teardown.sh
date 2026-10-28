#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "======================================"
echo " CONCERTPASS - TEARDOWN"
echo "======================================"

if [[ "${CONCERTPASS_TEARDOWN_READY:-NO}" != "YES" ]]; then
  echo "STOP: Teardown is not approved yet."
  echo "Review the deletion steps before removing AWS resources."
  exit 1
fi

echo "Deletion steps have not been implemented yet."
echo "No resources were deleted."
