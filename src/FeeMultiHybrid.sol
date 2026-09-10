// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
// Modified by DAMM Capital in 2026 to add manager-fee settlement to MultiHybrid behavior.
pragma solidity 0.8.36;

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {ICompounder} from 'V3/interfaces/relay/entrypoints/ICompounder.sol';
import {IMultiConverter} from 'V3/interfaces/relay/entrypoints/IMultiConverter.sol';
import {IMultiHybrid} from 'V3/interfaces/relay/entrypoints/IMultiHybrid.sol';
import {MultiEntrypoint} from 'V3/relay/entrypoints/MultiEntrypoint.sol';

import {FeePolicy} from './FeePolicy.sol';

/// @notice A fee-charging, API-compatible variant of Dromos MultiHybrid for Protocol L2 Relays.
/// @dev Stock MultiHybrid has no virtual settlement hooks, so this contract extends its MultiEntrypoint config layer
///      and preserves the stock public behavior while inserting the shared fee split before settlement.
contract FeeMultiHybrid is MultiEntrypoint, IMultiHybrid, FeePolicy {
  /// @inheritdoc IMultiHybrid
  uint256 public override compoundWeight;

  constructor(
    IFactoryRegistry registry,
    IRelayEntrypoint relay,
    address[] memory initialTargets,
    address[] memory initialExcluded,
    uint256 initialCompoundWeight,
    address feeOwner,
    address initialFeeRecipient,
    uint256 feeBps
  ) MultiEntrypoint(registry, relay, initialTargets, initialExcluded) FeePolicy(feeOwner, initialFeeRecipient, feeBps) {
    if (initialCompoundWeight > MAX_PIPS) revert InvalidCompoundWeight();
    compoundWeight = initialCompoundWeight;
  }

  /// @inheritdoc IMultiHybrid
  function setCompoundWeight(uint256 newCompoundWeight) external override onlyRelayOwner {
    if (newCompoundWeight > MAX_PIPS) revert InvalidCompoundWeight();
    if (compoundWeight == newCompoundWeight) return;
    compoundWeight = newCompoundWeight;
    emit CompoundWeightSet(newCompoundWeight);
  }

  /// @inheritdoc ICompounder
  function swapAndCompound(IBaseEntrypoint.SwapParams calldata params) external override nonReentrant {
    _requireBoundRelay(params.relay);
    _requireNotExcluded(params.tokenIn);
    address token = IRelayEntrypoint(params.relay).TOKEN();
    uint256 gross = _pullSwapAndValidate(params, token);
    _compoundAfterFee(params.relay, token, gross);
  }

  /// @inheritdoc IMultiConverter
  function swapAndConvert(
    IBaseEntrypoint.SwapParams calldata params,
    address targetToken
  ) external override nonReentrant {
    _requireBoundRelay(params.relay);
    _requireConvertible(params.tokenIn, targetToken);
    uint256 gross = _pullSwapAndValidate(params, targetToken);
    _convertAfterFee(params.relay, targetToken, gross);
  }

  /// @inheritdoc ICompounder
  function compoundIdleBalance(address relay) external override nonReentrant {
    _requireBoundRelay(relay);
    _requireKeeper(relay);
    address token = IRelayEntrypoint(relay).TOKEN();
    uint256 gross = _requireIdleBalance(relay, token);
    _compoundAfterFee(relay, token, gross);
  }

  /// @inheritdoc IMultiConverter
  function convertIdleBalance(address relay, address targetToken) external override nonReentrant {
    _requireBoundRelay(relay);
    _requireTarget(targetToken);
    _requireKeeper(relay);
    uint256 gross = _requireIdleBalance(relay, targetToken);
    _convertAfterFee(relay, targetToken, gross);
  }

  function _compoundAfterFee(address relay, address token, uint256 gross) internal {
    uint256 fee = _takeFeeFromRelay(relay, token, gross);
    IRelayEntrypoint(relay).compound(gross - fee);
    emit ManagementFeeTaken(relay, token, gross, fee);
  }

  function _convertAfterFee(address relay, address targetToken, uint256 gross) internal {
    uint256 fee = _takeFeeFromRelay(relay, targetToken, gross);
    IRelayEntrypoint(relay).notifyReward(targetToken, gross - fee);
    emit ManagementFeeTaken(relay, targetToken, gross, fee);
  }
}
