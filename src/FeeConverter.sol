// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
// Modified by DAMM Capital in 2026 to add manager-fee settlement and fee-exempt dust accounting.
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

  /// @dev Accumulator rounding residue has already passed through the fee split. Tracking it prevents the next
  ///      idle conversion from charging that same value again.
  mapping(address relay => uint256 amount) private _feeExemptDust;

  error TrackedDustExceedsIdleBalance(address relay, uint256 trackedDust, uint256 idleBalance);

  constructor(
    IFactoryRegistry registry,
    address tokenOut,
    address feeRecipient,
    uint256 feeBps
  ) FeeEntrypointBase(registry, feeRecipient, feeBps) {
    if (tokenOut == address(0)) revert ZeroAddress();
    TARGET_TOKEN = tokenOut;
  }

  /// @notice Skims the management fee from newly arrived target tokens, then notifies all fee-paid idle rewards.
  function convertIdleBalance(address relay) external override nonReentrant {
    _requireKeeper(relay);

    uint256 gross = _requireIdleBalance(relay, TARGET_TOKEN);
    uint256 trackedDust = _trackedDust(relay, gross);
    uint256 fee = _takeFeeFromRelay(relay, TARGET_TOKEN, gross - trackedDust);
    IRelayEntrypoint(relay).notifyReward(TARGET_TOKEN, gross - fee);
    _feeExemptDust[relay] = _idleBalance(relay, TARGET_TOKEN);

    emit ManagementFeeTaken(relay, TARGET_TOKEN, gross, fee);
  }

  /// @notice Swaps a Relay reward token into the target token, skims the fee from the measured output, and notifies net.
  function swapAndConvert(IBaseEntrypoint.SwapParams calldata params) external override nonReentrant {
    uint256 gross = _pullSwapAndValidate(params, TARGET_TOKEN);

    // `_pullSwapAndValidate` has already transferred `gross` to the Relay. Subtracting it recovers the target-token
    // idle balance that predated this swap, so unrelated direct rewards remain fee-bearing for the idle path.
    uint256 idleBeforeSwap = _idleBalance(params.relay, TARGET_TOKEN) - gross;
    uint256 trackedDust = _trackedDust(params.relay, idleBeforeSwap);
    uint256 fee = _takeFeeFromRelay(params.relay, TARGET_TOKEN, gross);
    IRelayEntrypoint(params.relay).notifyReward(TARGET_TOKEN, gross - fee);

    uint256 idleAfterSwap = _idleBalance(params.relay, TARGET_TOKEN);
    _feeExemptDust[params.relay] = trackedDust + (idleAfterSwap - idleBeforeSwap);

    emit ManagementFeeTaken(params.relay, TARGET_TOKEN, gross, fee);
  }

  function _trackedDust(address relay, uint256 idleBalance) private view returns (uint256 trackedDust) {
    trackedDust = _feeExemptDust[relay];
    if (trackedDust > idleBalance) {
      revert TrackedDustExceedsIdleBalance(relay, trackedDust, idleBalance);
    }
  }
}
