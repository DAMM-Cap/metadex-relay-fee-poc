// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
// Modified by DAMM Capital in 2026 to centralize fee configuration and Relay settlement.
pragma solidity 0.8.36;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {BaseEntrypoint} from 'V3/relay/entrypoints/BaseEntrypoint.sol';

import {FeePolicy} from './FeePolicy.sol';

/// @notice Shared fee configuration and transfer logic for DAMM's modified Dromos Relay entrypoints.
/// @dev Combines the stock single-entrypoint base with DAMM's reusable fee policy.
abstract contract FeeEntrypointBase is BaseEntrypoint, FeePolicy {
  constructor(
    IFactoryRegistry registry,
    address feeOwner,
    address initialFeeRecipient,
    uint256 feeBps
  ) BaseEntrypoint(registry) FeePolicy(feeOwner, initialFeeRecipient, feeBps) {}
}
