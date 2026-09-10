// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
// Modified by DAMM Capital in 2026 to centralize fee configuration and Relay settlement.
pragma solidity 0.8.36;

import {Ownable, Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {BaseEntrypoint} from 'V3/relay/entrypoints/BaseEntrypoint.sol';

/// @notice Shared fee configuration and transfer logic for DAMM's modified Dromos Relay entrypoints.
/// @dev The two-step owner may rotate the payout address but cannot change the bounded fee rate.
abstract contract FeeEntrypointBase is BaseEntrypoint, Ownable2Step {
  using SafeTransferLib for address;

  uint256 public constant MAX_FEE_BPS = 5000;
  uint256 internal constant BPS_DENOMINATOR = 10_000;

  address public feeRecipient;
  uint256 public immutable FEE_BPS;

  error FeeTooHigh(uint256 feeBps);
  event FeeRecipientSet(address indexed previousRecipient, address indexed newRecipient);

  event ManagementFeeTaken(address indexed relay, address indexed token, uint256 gross, uint256 fee);

  constructor(
    IFactoryRegistry registry,
    address feeOwner,
    address initialFeeRecipient,
    uint256 feeBps
  ) BaseEntrypoint(registry) Ownable(feeOwner) {
    if (initialFeeRecipient == address(0)) revert ZeroAddress();
    if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps);

    feeRecipient = initialFeeRecipient;
    FEE_BPS = feeBps;
  }

  /// @notice Updates the address that receives fees from future conversions and compounds.
  function setFeeRecipient(address newFeeRecipient) external onlyOwner {
    if (newFeeRecipient == address(0)) revert ZeroAddress();
    address previousRecipient = feeRecipient;
    if (newFeeRecipient == previousRecipient) return;

    feeRecipient = newFeeRecipient;
    emit FeeRecipientSet(previousRecipient, newFeeRecipient);
  }

  function _takeFeeFromRelay(address relay, address token, uint256 feeBase) internal returns (uint256 fee) {
    fee = Math.mulDiv(feeBase, FEE_BPS, BPS_DENOMINATOR);
    if (fee != 0) {
      IRelayEntrypoint(relay).pull(token, fee);
      token.safeTransfer(feeRecipient, fee);
    }
  }
}
