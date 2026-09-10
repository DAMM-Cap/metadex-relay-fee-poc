// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
// Modified by DAMM Capital in 2026 to centralize fee configuration and Relay settlement.
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {BaseEntrypoint} from 'V3/relay/entrypoints/BaseEntrypoint.sol';

/// @notice Shared fee configuration and transfer logic for DAMM's modified Dromos Relay entrypoints.
/// @dev Modified from Dromos BaseEntrypoint-based entrypoints to add a bounded manager-fee split.
abstract contract FeeEntrypointBase is BaseEntrypoint {
  using SafeTransferLib for address;

  uint256 public constant MAX_FEE_BPS = 5000;
  uint256 internal constant BPS_DENOMINATOR = 10_000;

  address public immutable FEE_RECIPIENT;
  uint256 public immutable FEE_BPS;

  error FeeTooHigh(uint256 feeBps);

  event ManagementFeeTaken(address indexed relay, address indexed token, uint256 gross, uint256 fee);

  constructor(IFactoryRegistry registry, address feeRecipient, uint256 feeBps) BaseEntrypoint(registry) {
    if (feeRecipient == address(0)) revert ZeroAddress();
    if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps);

    FEE_RECIPIENT = feeRecipient;
    FEE_BPS = feeBps;
  }

  function _idleBalance(address relay, address token) internal view returns (uint256) {
    return IERC20(token).balanceOf(relay) - IRelayEntrypoint(relay).accountedBalance(token);
  }

  function _takeFeeFromRelay(address relay, address token, uint256 feeBase) internal returns (uint256 fee) {
    fee = Math.mulDiv(feeBase, FEE_BPS, BPS_DENOMINATOR);
    if (fee != 0) {
      IRelayEntrypoint(relay).pull(token, fee);
      token.safeTransfer(FEE_RECIPIENT, fee);
    }
  }
}
