# MetaDEX Relay manager-fee PoC

Private evaluation artifact for Dromos Labs and DAMM Capital. The vendored MetaDEX source and DAMM's derivative fee entrypoints are governed by the [Dromos Restricted Use License 1.0](LICENSE.md). This repository is not a production deployment; vendored Dromos contracts remain unmodified.

## Claims proved

A manager selects one fee path per Relay. Both are custom Relay entrypoints that skim a bounded manager fee and leave every Dromos contract unmodified; on a real Base fork:

**`FeeConverter`** (fee in cash) implements Dromos `ISingleConverter` and holds the `MaxiRelay`'s `CONVERTER` role. It:

1. measures USDC that is on the Relay but not yet accounted;
2. pulls a bounded manager fee from the Relay and transfers that fee as USDC to `FEE_RECIPIENT`;
3. calls `notifyReward` with the remainder; and
4. lets Relay holders claim the net reward pro rata.

**`FeeCompounder`** (fee in TOKEN, net compounded) implements Dromos `ICompounder` and holds the `COMPOUNDER` role on a sibling Relay. It:

1. measures unaccounted TOKEN on the Relay;
2. pulls the manager fee and transfers it as TOKEN to `FEE_RECIPIENT`;
3. calls `compound` with the remainder, growing `totalBacking`; and
4. mints no new shares, so every existing share appreciates.

The core proof forks Base at block `50,718,500`, deploys a fresh root-only MetaDEX stack, VPM, Relay factory, real `FactoryRegistry`, real `MaxiRelay`, and both entrypoints; no VE/Voter/VPM mocks are used. It includes the full protocol call topology: NFT deposit → keeper calls the configured entrypoint → entrypoint calls Relay `pull`/`notifyReward` (converter) or `pull`/`compound` (compounder) → holders claim the net reward or hold appreciated shares. MetaDEX deliberately has no Relay callback that dispatches into an entrypoint.

## Setup

Install the pinned JavaScript dependencies and provide an archive-capable Base RPC:

```sh
git submodule update --init --recursive
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

The eighteen tests cover both paths: the complete NFT-deposit → configured-entrypoint → Relay flow; cash-fee settlement with net pro-rata claims; fee-in-TOKEN with net compounding; parity with Dromos `SingleConverter`/`Compounder` at 0 bps; keeper, empty-balance, fee-cap, and cross-Relay role guards; repeated reward rounds without charging accumulator dust twice; and both swap lanes through an approved deterministic router, including fee bases, input refunds, and allowance cleanup.

Observed on the pinned fork:

- converter: `11,000 USDC` gross → `1,100 USDC` manager cash fee (10%) → `9,900 USDC` to holders (`9,000` treasury + `900` Alice);
- compounder: `11,000 TOKEN` gross → `1,100 TOKEN` manager fee (10%) → `9,900 TOKEN` compounded into backing, no new shares;
- `FeeConverter` charges accumulator rounding residue at most once, including across mixed direct-reward and swap rounds.

## Narrated local demo

```sh
./scripts/dev.sh
```

The wrapper starts a dedicated Anvil fork of Base at block `50,718,500` on port `18545` (override with `ANVIL_PORT`), verifies its `chainId` is `8453`, then runs a narrated end-to-end test through deployment, stake, reward, and both fee paths: cash-out conversion with holder claims, and fee-in-TOKEN compounding into backing.

This is intentionally **not a broadcast deployment**: `DeployRelayPoc` exposes only the test harness entrypoint, not a `run()` function. MetaDEX TOKEN sets `TRANSFERS_ENABLED_AT` to one week after a future `migrationOpen`; the Relay factory routes its seed through the non-exempt factory, so an atomic live deployment plus seed necessarily reverts before that gate opens. The local fork test advances time precisely to demonstrate the same real-contract path. A live demo requires a separately designed two-phase deployment: deploy, wait past the gate, then seed the Relay.

## Post-deployment checks with Cast

After a real two-phase deployment, set the printed deployment addresses and query the live node:

```sh
export RPC_URL=http://127.0.0.1:18545
export RELAY=0x...
export COMPOUNDER_RELAY=0x...
export FEE_CONVERTER=0x...
export FEE_COMPOUNDER=0x...
export USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913

cast call "$FEE_CONVERTER" 'FEE_BPS()(uint256)' --rpc-url "$RPC_URL"
cast call "$FEE_CONVERTER" 'FEE_RECIPIENT()(address)' --rpc-url "$RPC_URL"
cast call "$RELAY" 'accountedBalance(address)(uint256)' "$USDC" --rpc-url "$RPC_URL"
cast call "$RELAY" 'hasAnyRole(address,uint256)(bool)' "$FEE_CONVERTER" 8 --rpc-url "$RPC_URL"
cast call "$COMPOUNDER_RELAY" 'hasAnyRole(address,uint256)(bool)' "$FEE_COMPOUNDER" 4 --rpc-url "$RPC_URL"
cast call "$COMPOUNDER_RELAY" 'totalBacking()(uint256)' --rpc-url "$RPC_URL"
```

`8` is the `CONVERTER` bit (`1 << 3`); `4` is the `COMPOUNDER` bit (`1 << 2`).

## Boundaries

- The approved-router tests prove entrypoint integration, output measurement, fee settlement, input refunds, and allowance cleanup with a deterministic router. Production MetaRouter command encoding and route selection remain outside this PoC.
- Entry tokens must be governance-vetted standard ERC-20s. Fee-on-transfer, rebasing, and callback-bearing tokens are unsupported because MetaDEX's entrypoint accounting assumes exact balance deltas.
- Out of scope: allocation/voting, cross-chain claims, withdrawals, protocol tiers, governance, and production deployment.
- The real proof is the fork suite; the Anvil command is a reproducible walkthrough.

## License

The project includes Dromos-derived work and is distributed under the [Dromos Restricted Use License 1.0](LICENSE.md). Production use is prohibited by that license. Modified source files carry the required SPDX identifier and modification notice.
