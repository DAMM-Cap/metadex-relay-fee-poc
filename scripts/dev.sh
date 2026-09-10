#!/usr/bin/env bash
# End-to-end walkthrough of both MetaDEX relay fee paths (cash-out FeeConverter + compounding FeeCompounder)
# against a pinned Base-fork Anvil.
# It runs the real root stack + unmodified MaxiRelay in Foundry's fork-test EVM, which is required because
# TOKEN's post-migration transfer gate prevents an atomic live deployment and seed transaction.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

: "${BASE_RPC:?BASE_RPC must be set (copy .env.example to .env and fill in a Base archive RPC)}"

port="${ANVIL_PORT:-18545}"
rpc_url="http://127.0.0.1:${port}"
anvil_log="$(mktemp)"

cleanup() {
  kill "$anvil_pid" 2>/dev/null || true
  wait "$anvil_pid" 2>/dev/null || true
  rm -f "$anvil_log"
}

anvil --fork-url "$BASE_RPC" --fork-block-number 50718500 --chain-id 8453 --port "$port" >"$anvil_log" 2>&1 &
anvil_pid=$!
trap cleanup EXIT INT TERM

for _ in {1..50}; do
  if ! kill -0 "$anvil_pid" 2>/dev/null; then
    cat "$anvil_log" >&2
    exit 1
  fi
  if cast block-number --rpc-url "$rpc_url" >/dev/null 2>&1 \
    && [[ "$(cast chain-id --rpc-url "$rpc_url")" == "8453" ]]; then
    DEMO_RPC_URL="$rpc_url" forge test --match-contract DemoRelayFeeTest -vv
    exit 0
  fi
  sleep 0.1
done

cat "$anvil_log" >&2
echo "Anvil did not become ready at $rpc_url" >&2
exit 1
