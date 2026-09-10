# MetaDEX Relay cash-fee PoC

Private evaluation artifact for Dromos Labs and DAMM Capital. The vendored MetaDEX source remains subject to its `LicenseRef-Dromos-Restricted-Use-1.0` license. This repository is not a production deployment and changes no Dromos contract.

## Claim proved

`FeeConverter` is a custom Relay entrypoint that holds the unmodified `MaxiRelay`'s `CONVERTER` role. On a real Base fork it:

1. measures USDC that is on the Relay but not yet accounted;
2. pulls a bounded manager fee from the Relay and transfers that fee as USDC to `FEE_RECIPIENT`;
3. calls `notifyReward` with the remainder; and
4. lets Relay holders claim the net reward pro rata.

The core proof forks Base at block `50,718,500`, deploys a fresh root-only MetaDEX stack, VPM, factory, real `MaxiRelay`, and `FeeConverter`; no VE/Voter/VPM mocks are used.

## Setup

Install the pinned JavaScript dependencies and provide an archive-capable Base RPC:

```sh
yarn install
printf 'BASE_RPC=https://your-archive-base-rpc\n' > .env
```

The compiler is pinned to Solidity `0.8.36`; Foundry downloads it if needed.

## Proof

```sh
set -a && . ./.env && set +a
forge test --match-path test/RelayFeePoc.t.sol -vv
forge test --match-path test/RelayFeePoc.t.sol --gas-report
```

The seven tests cover cash-fee settlement, net pro-rata claims, parity with Dromos `SingleConverter` at 0 bps, keeper and empty-balance guards, the 50% fee cap, and repeated reward rounds after a partial claim.

Observed on the pinned fork:

- `11,000 USDC` gross reward;
- `1,100 USDC` manager cash fee (10%);
- `9,900 USDC` accounted to holders;
- `9,000 USDC` treasury claim + `900 USDC` Alice claim; and
- `FeeConverter.convertIdleBalance` gas range: `115,404–164,706` across the proof calls.

## Narrated local demo

```sh
./scripts/dev.sh
```

The wrapper starts a dedicated Anvil fork of Base at block `50,718,500` on port `18545` (override with `ANVIL_PORT`), verifies its `chainId` is `8453`, then runs a narrated end-to-end test through deployment, stake, reward, fee conversion, and holder claims.

This is intentionally **not a broadcast deployment**. MetaDEX TOKEN sets `TRANSFERS_ENABLED_AT` to one week after a future `migrationOpen`; the Relay factory routes its seed through the non-exempt factory, so an atomic live deployment plus seed necessarily reverts before that gate opens. The local fork test advances time precisely to demonstrate the same real-contract path. A live demo requires two separately mined phases: deploy, wait/advance past the gate, then seed the Relay.

## Post-deployment checks with Cast

After a real two-phase deployment, set the printed deployment addresses and query the live node:

```sh
export RPC_URL=http://127.0.0.1:18545
export RELAY=0x... 
export FEE_CONVERTER=0x...
export USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913

cast call "$FEE_CONVERTER" 'FEE_BPS()(uint256)' --rpc-url "$RPC_URL"
cast call "$FEE_CONVERTER" 'FEE_RECIPIENT()(address)' --rpc-url "$RPC_URL"
cast call "$RELAY" 'accountedBalance(address)(uint256)' "$USDC" --rpc-url "$RPC_URL"
cast call "$RELAY" 'hasAnyRole(address,uint256)(bool)' "$FEE_CONVERTER" 8 --rpc-url "$RPC_URL"
```

`8` is the `CONVERTER` bit (`1 << 3`).

## Boundaries

- The idle-balance fee lane is the claim under evaluation. `swapAndConvert` is included with the same safety rails but has no router integration test here.
- Out of scope: allocation/voting, cross-chain claims, withdrawals, protocol tiers, governance, and production deployment.
- The real proof is the fork suite; the Anvil command is a reproducible walkthrough.
