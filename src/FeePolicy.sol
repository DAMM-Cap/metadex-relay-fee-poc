// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
// Modified by DAMM Capital in 2026 to centralize fee configuration and Relay settlement.
pragma solidity 0.8.36;

import {Ownable, Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';

/// @notice Shared bounded-fee policy for DAMM's modified Dromos Relay entrypoints.
/// @dev Fee ownership is independent from Relay strategy ownership. The fee rate is immutable.
abstract contract FeePolicy is Ownable2Step {
  using SafeTransferLib for address;

  uint256 public constant MAX_FEE_BPS = 5000;
  uint256 internal constant BPS_DENOMINATOR = 10_000;

  address public feeRecipient;
  uint256 public immutable FEE_BPS;

  error FeeTooHigh(uint256 feeBps);

  event FeeRecipientSet(address indexed previousRecipient, address indexed newRecipient);
  event ManagementFeeTaken(address indexed relay, address indexed token, uint256 gross, uint256 fee);

  constructor(address feeOwner, address initialFeeRecipient, uint256 feeBps) Ownable(feeOwner) {
    if (initialFeeRecipient == address(0)) revert IBaseEntrypoint.ZeroAddress();
    if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps);

    feeRecipient = initialFeeRecipient;
    FEE_BPS = feeBps;
  }

  /// @notice Updates the address that receives fees from future conversions and compounds.
  function setFeeRecipient(address newFeeRecipient) external onlyOwner {
    if (newFeeRecipient == address(0)) revert IBaseEntrypoint.ZeroAddress();
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
