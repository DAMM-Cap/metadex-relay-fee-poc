// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {ISingleConverter} from 'V3/interfaces/relay/entrypoints/ISingleConverter.sol';

/// @notice A Relay converter that pays a bounded cash management fee before accounting rewards to holders.
/// @dev This contract is only for private evaluation with Dromos; it does not modify any Dromos contract.
contract FeeConverter is ISingleConverter, ReentrancyGuardTransient {
  using SafeTransferLib for address;

  uint256 public constant MAX_FEE_BPS = 5_000;
  uint256 internal constant BPS_DENOMINATOR = 10_000;

  IFactoryRegistry public immutable override FACTORY_REGISTRY;
  address public immutable override TARGET_TOKEN;
  address public immutable FEE_RECIPIENT;
  uint256 public immutable FEE_BPS;

  error FeeTooHigh(uint256 feeBps);

  event ManagementFeeTaken(address indexed relay, address indexed token, uint256 gross, uint256 fee);

  constructor(IFactoryRegistry registry, address tokenOut, address feeRecipient, uint256 feeBps) {
    if (address(registry) == address(0) || tokenOut == address(0) || feeRecipient == address(0)) revert ZeroAddress();
    if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps);

    FACTORY_REGISTRY = registry;
    TARGET_TOKEN = tokenOut;
    FEE_RECIPIENT = feeRecipient;
    FEE_BPS = feeBps;
  }

  /// @notice Skims the management fee from the Relay's unaccounted target-token balance, then notifies net rewards.
  function convertIdleBalance(address relay) external override nonReentrant {
    _requireKeeper(relay);

    uint256 gross = _idleBalance(relay, TARGET_TOKEN);
    if (gross == 0) revert NoIdleBalance();

    uint256 fee = _takeFeeFromRelay(relay, gross);
    IRelayEntrypoint(relay).notifyReward(TARGET_TOKEN, gross - fee);

    emit ManagementFeeTaken(relay, TARGET_TOKEN, gross, fee);
  }

  /// @notice Swaps a Relay reward token into the target token, skims the fee from the measured output, and notifies net.
  function swapAndConvert(IBaseEntrypoint.SwapParams calldata params) external override nonReentrant {
    _requireKeeper(params.relay);
    if (params.minAmountOut == 0) revert ZeroMinOut();
    if (!FACTORY_REGISTRY.isMetaRouterApproved(params.router)) revert RouterNotApproved();
    if (params.tokenIn == TARGET_TOKEN) revert SameToken();

    uint256 balanceBefore = IERC20(TARGET_TOKEN).balanceOf(address(this));
    IRelayEntrypoint(params.relay).pull(params.tokenIn, params.amountIn);
    params.tokenIn.safeApproveWithRetry(params.router, params.amountIn);
    IMetarouter(params.router).execute(params.commands, params.inputs, params.deadline);
    params.tokenIn.safeApproveWithRetry(params.router, 0);

    uint256 gross = IERC20(TARGET_TOKEN).balanceOf(address(this)) - balanceBefore;
    if (gross < params.minAmountOut) revert InsufficientOutput();

    uint256 fee = _takeFeeFromConverter(gross);
    TARGET_TOKEN.safeTransfer(params.relay, gross - fee);
    IRelayEntrypoint(params.relay).notifyReward(TARGET_TOKEN, gross - fee);

    uint256 leftover = IERC20(params.tokenIn).balanceOf(address(this));
    if (leftover != 0) params.tokenIn.safeTransfer(params.relay, leftover);

    emit ManagementFeeTaken(params.relay, TARGET_TOKEN, gross, fee);
  }

  function _requireKeeper(address relay) private view {
    IRelayEntrypoint relayContract = IRelayEntrypoint(relay);
    if (!relayContract.hasAnyRole(msg.sender, relayContract.KEEPER())) revert NotKeeper();
  }

  function _idleBalance(address relay, address token) private view returns (uint256) {
    return IERC20(token).balanceOf(relay) - IRelayEntrypoint(relay).accountedBalance(token);
  }

  function _takeFeeFromRelay(address relay, uint256 gross) private returns (uint256 fee) {
    fee = _feeFor(gross);
    if (fee != 0) {
      IRelayEntrypoint(relay).pull(TARGET_TOKEN, fee);
      TARGET_TOKEN.safeTransfer(FEE_RECIPIENT, fee);
    }
  }

  function _takeFeeFromConverter(uint256 gross) private returns (uint256 fee) {
    fee = _feeFor(gross);
    if (fee != 0) TARGET_TOKEN.safeTransfer(FEE_RECIPIENT, fee);
  }

  function _feeFor(uint256 gross) private view returns (uint256) {
    return gross * FEE_BPS / BPS_DENOMINATOR;
  }
}
