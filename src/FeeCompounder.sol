// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
// Modified by DAMM Capital in 2026 to add manager-fee settlement before compounding.
pragma solidity 0.8.36;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {ICompounder} from 'V3/interfaces/relay/entrypoints/ICompounder.sol';

import {FeeEntrypointBase} from './FeeEntrypointBase.sol';

/// @notice A Relay compounder that pays a bounded management fee in the Relay's TOKEN, then compounds the net into
///         backing so every share appreciates. The fee-in-cash sibling is `FeeConverter`; a manager picks one.
/// @dev Modified from Dromos Compounder for private evaluation; it does not modify any Dromos contract.
contract FeeCompounder is FeeEntrypointBase, ICompounder {
  constructor(
    IFactoryRegistry registry,
    address feeRecipient,
    uint256 feeBps
  ) FeeEntrypointBase(registry, feeRecipient, feeBps) {}

  /// @notice Skims the management fee from the Relay's unaccounted TOKEN balance, then compounds the net into backing.
  function compoundIdleBalance(address relay) external override nonReentrant {
    _requireKeeper(relay);

    address token = IRelayEntrypoint(relay).TOKEN();
    uint256 gross = _requireIdleBalance(relay, token);
    uint256 fee = _takeFeeFromRelay(relay, token, gross);
    IRelayEntrypoint(relay).compound(gross - fee);

    emit ManagementFeeTaken(relay, token, gross, fee);
  }

  /// @notice Swaps a Relay reward token into TOKEN, skims the fee from the measured output, then compounds the net.
  function swapAndCompound(IBaseEntrypoint.SwapParams calldata params) external override nonReentrant {
    address token = IRelayEntrypoint(params.relay).TOKEN();
    uint256 gross = _pullSwapAndValidate(params, token);
    uint256 fee = _takeFeeFromRelay(params.relay, token, gross);
    IRelayEntrypoint(params.relay).compound(gross - fee);

    emit ManagementFeeTaken(params.relay, token, gross, fee);
  }
}
