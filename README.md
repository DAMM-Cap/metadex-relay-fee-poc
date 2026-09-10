# MetaDEX Relay manager-fee PoC

Private evaluation artifact for Dromos Labs and DAMM Capital. The vendored MetaDEX source and DAMM's derivative fee entrypoints are governed by the [Dromos Restricted Use License 1.0](LICENSE.md). This repository is not a production deployment; vendored Dromos contracts remain unmodified.

## Claims proved

Three custom Relay entrypoints skim a bounded manager fee while leaving every vendored Dromos contract unmodified; on a real Base fork:

**`FeeConverter`** (fee in cash) implements Dromos `ISingleConverter` and holds the `MaxiRelay`'s `CONVERTER` role. It:

1. measures USDC that is on the Relay but not yet accounted;
2. pulls a bounded manager fee from the Relay and transfers that fee as USDC to `feeRecipient`;
3. calls `notifyReward` with the remainder; and
4. lets Relay holders claim the net reward pro rata.

**`FeeCompounder`** (fee in TOKEN, net compounded) implements Dromos `ICompounder` and holds the `COMPOUNDER` role on a sibling Relay. It:

1. measures unaccounted TOKEN on the Relay;
2. pulls the manager fee and transfers it as TOKEN to `feeRecipient`;
3. calls `compound` with the remainder, growing `totalBacking`; and
4. mints no new shares, so every existing share appreciates.

**`FeeMultiHybrid`** implements Dromos `IMultiHybrid` behavior on a bound `ProtocolRelay` initialized as L2, where it holds both `CONVERTER` and `COMPOUNDER`. Stock `MultiHybrid` exposes no virtual settlement hooks, so this API-compatible variant extends the stock `MultiEntrypoint` configuration layer and preserves its four public execution paths. On each call the keeper chooses either conversion or compounding; the contract charges the same fee on the measured swap output or whole unaccounted idle balance before notifying or compounding the net.

Every entrypoint has a separate OpenZeppelin `Ownable2Step` fee owner, initialized to the deployment admin. The current fee owner can call `setFeeRecipient` with a non-zero address; the new recipient receives only future fees. The fee rate is immutable, as is `FeeConverter`'s target. `FeeMultiHybrid` instead preserves stock multi-entrypoint governance: its target/exclusion sets and informational `compoundWeight` are mutable only by the bound Relay owner.

The core proof forks Base at block `50,718,500` and deploys a fresh root-only MetaDEX stack, VPM, Relay factory, real `FactoryRegistry`, two real `MaxiRelay` instances, one real `ProtocolRelay` initialized as L2, and all three entrypoints; no VE/Voter/VPM mocks are used. The Protocol L2 Relay is deterministically predicted before `FeeMultiHybrid` deployment so the bound entrypoint can be attached to both roles during Relay initialization. MetaDEX deliberately has no Relay callback that dispatches into an entrypoint.

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

The twenty-five tests cover all three entrypoints: the complete NFT-deposit → configured-entrypoint → Relay flow; cash-fee settlement with net pro-rata claims; fee-in-TOKEN with net compounding; all four hybrid idle/swap settlement paths; owner-controlled recipient rotation; unauthorized, zero-recipient, keeper, empty-balance, fee-cap, wrong-bound-Relay, and cross-Relay role guards; parity with Dromos `SingleConverter`/`Compounder` at 0 bps; repeated reward rounds with consistent cross-round accounting; and approved-router output measurement, input refunds, and allowance cleanup.

Observed on the pinned fork:

- converter: `11,000 USDC` gross → `1,100 USDC` manager cash fee (10%) → `9,900 USDC` to holders (`9,000` treasury + `900` Alice);
- compounder: `11,000 TOKEN` gross → `1,100 TOKEN` manager fee (10%) → `9,900 TOKEN` compounded into backing, no new shares;
- all three entrypoints follow the stock Dromos idle/swap shapes: idle calls fee the Relay's whole unaccounted balance (so recycled accumulator residue is fee-bearing), while swap calls fee only measured output;
- hybrid: the same bound Protocol L2 entrypoint charges `1,100 USDC` before notifying `9,900 USDC`, or charges `1,100 TOKEN` before compounding `9,900 TOKEN`, according to the keeper-selected method.

## Narrated local demo

```sh
./scripts/dev.sh
```

The wrapper starts a dedicated Anvil fork of Base at block `50,718,500` on port `18545` (override with `ANVIL_PORT`), verifies its `chainId` is `8453`, then runs a narrated end-to-end test through deployment, stake, reward, and all three fee entrypoints: cash-out conversion with holder claims, fee-in-TOKEN compounding, and the bound Protocol L2 hybrid's keeper-selected conversion and compounding paths.

This is intentionally **not a broadcast deployment**: `DeployRelayPoc` exposes only the test harness entrypoint, not a `run()` function. MetaDEX TOKEN sets `TRANSFERS_ENABLED_AT` to one week after a future `migrationOpen`; the Relay factory routes its seed through the non-exempt factory, so an atomic live deployment plus seed necessarily reverts before that gate opens. The local fork test advances time precisely to demonstrate the same real-contract path. A live demo requires a separately designed two-phase deployment: deploy, wait past the gate, then seed the Relay.

## Post-deployment checks with Cast

After a real two-phase deployment, set the printed deployment addresses and query the live node:

```sh
export RPC_URL=http://127.0.0.1:18545
export RELAY=0x...
export COMPOUNDER_RELAY=0x...
export FEE_CONVERTER=0x...
export FEE_COMPOUNDER=0x...
export HYBRID_RELAY=0x...
export FEE_MULTI_HYBRID=0x...
export USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913

cast call "$FEE_CONVERTER" 'FEE_BPS()(uint256)' --rpc-url "$RPC_URL"
cast call "$FEE_CONVERTER" 'feeRecipient()(address)' --rpc-url "$RPC_URL"
cast call "$RELAY" 'accountedBalance(address)(uint256)' "$USDC" --rpc-url "$RPC_URL"
cast call "$RELAY" 'hasAnyRole(address,uint256)(bool)' "$FEE_CONVERTER" 8 --rpc-url "$RPC_URL"
cast call "$COMPOUNDER_RELAY" 'hasAnyRole(address,uint256)(bool)' "$FEE_COMPOUNDER" 4 --rpc-url "$RPC_URL"
cast call "$COMPOUNDER_RELAY" 'totalBacking()(uint256)' --rpc-url "$RPC_URL"
cast call "$FEE_MULTI_HYBRID" 'RELAY()(address)' --rpc-url "$RPC_URL"
cast call "$FEE_MULTI_HYBRID" 'feeRecipient()(address)' --rpc-url "$RPC_URL"
cast call "$FEE_MULTI_HYBRID" 'targetTokens()(address[])' --rpc-url "$RPC_URL"
cast call "$FEE_MULTI_HYBRID" 'compoundWeight()(uint256)' --rpc-url "$RPC_URL"
cast call "$HYBRID_RELAY" 'hasAnyRole(address,uint256)(bool)' "$FEE_MULTI_HYBRID" 8 --rpc-url "$RPC_URL"
cast call "$HYBRID_RELAY" 'hasAnyRole(address,uint256)(bool)' "$FEE_MULTI_HYBRID" 4 --rpc-url "$RPC_URL"
```

`8` is the `CONVERTER` bit (`1 << 3`); `4` is the `COMPOUNDER` bit (`1 << 2`).

## Boundaries

- The approved-router tests prove entrypoint integration, output measurement, fee settlement, input refunds, and allowance cleanup with a deterministic router. Production MetaRouter command encoding and route selection remain outside this PoC.
- Entry tokens must be governance-vetted standard ERC-20s. Fee-on-transfer, rebasing, and callback-bearing tokens are unsupported because MetaDEX's entrypoint accounting assumes exact balance deltas.
- Out of scope: allocation/voting, cross-chain claims, withdrawals, Protocol L1-to-L2 promotion, governance operations beyond the fixture's direct L2 initialization, and production deployment.
- The real proof is the fork suite; the Anvil command is a reproducible walkthrough.

## License

The project includes Dromos-derived work and is distributed under the [Dromos Restricted Use License 1.0](LICENSE.md). Production use is prohibited by that license. Modified source files carry the required SPDX identifier and modification notice.
