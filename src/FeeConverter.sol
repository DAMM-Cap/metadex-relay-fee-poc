// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
// Modified by DAMM Capital in 2026 to add manager-fee settlement.
pragma solidity 0.8.36;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {ISingleConverter} from 'V3/interfaces/relay/entrypoints/ISingleConverter.sol';

import {FeeEntrypointBase} from './FeeEntrypointBase.sol';

/// @notice A Relay converter that pays a bounded cash management fee before accounting rewards to holders.
/// @dev Modified from Dromos SingleConverter for private evaluation; it does not modify any Dromos contract.
contract FeeConverter is FeeEntrypointBase, ISingleConverter {
  address public immutable override TARGET_TOKEN;

  constructor(
    IFactoryRegistry registry,
    address tokenOut,
    address feeOwner,
    address initialFeeRecipient,
    uint256 feeBps
  ) FeeEntrypointBase(registry, feeOwner, initialFeeRecipient, feeBps) {
    if (tokenOut == address(0)) revert ZeroAddress();
    TARGET_TOKEN = tokenOut;
  }

  /// @notice Skims the management fee from the Relay's whole unaccounted target-token balance, then notifies net.
  /// @dev Mirrors Dromos `SingleConverter.convertIdleBalance`, inserting only the fee split before `notifyReward`.
  function convertIdleBalance(address relay) external override nonReentrant {
    _requireKeeper(relay);
    uint256 gross = _requireIdleBalance(relay, TARGET_TOKEN);
    uint256 fee = _takeFeeFromRelay(relay, TARGET_TOKEN, gross);
    IRelayEntrypoint(relay).notifyReward(TARGET_TOKEN, gross - fee);
    emit ManagementFeeTaken(relay, TARGET_TOKEN, gross, fee);
  }

  /// @notice Swaps a Relay reward token into the target token, skims the fee from the measured output, and notifies net.
  /// @dev Mirrors Dromos `SingleConverter.swapAndConvert`, inserting only the fee split before `notifyReward`.
  function swapAndConvert(IBaseEntrypoint.SwapParams calldata params) external override nonReentrant {
    uint256 gross = _pullSwapAndValidate(params, TARGET_TOKEN);
    uint256 fee = _takeFeeFromRelay(params.relay, TARGET_TOKEN, gross);
    IRelayEntrypoint(params.relay).notifyReward(TARGET_TOKEN, gross - fee);
    emit ManagementFeeTaken(params.relay, TARGET_TOKEN, gross, fee);
  }
}
