// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {ICompounder} from 'V3/interfaces/relay/entrypoints/ICompounder.sol';

/// @notice A Relay compounder that pays a bounded management fee in the Relay's TOKEN, then compounds the net into
///         backing so every share appreciates. The fee-in-cash sibling is `FeeConverter`; a manager picks one.
/// @dev This contract is only for private evaluation with Dromos; it does not modify any Dromos contract.
contract FeeCompounder is ICompounder, ReentrancyGuardTransient {
  using SafeTransferLib for address;

  uint256 public constant MAX_FEE_BPS = 5_000;
  uint256 internal constant BPS_DENOMINATOR = 10_000;

  IFactoryRegistry public immutable override FACTORY_REGISTRY;
  address public immutable FEE_RECIPIENT;
  uint256 public immutable FEE_BPS;

  error FeeTooHigh(uint256 feeBps);

  event ManagementFeeTaken(address indexed relay, address indexed token, uint256 gross, uint256 fee);

  constructor(IFactoryRegistry registry, address feeRecipient, uint256 feeBps) {
    if (address(registry) == address(0) || feeRecipient == address(0)) revert ZeroAddress();
    if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps);

    FACTORY_REGISTRY = registry;
    FEE_RECIPIENT = feeRecipient;
    FEE_BPS = feeBps;
  }

  /// @notice Skims the management fee from the Relay's unaccounted TOKEN balance, then compounds the net into backing.
  function compoundIdleBalance(address relay) external override nonReentrant {
    _requireKeeper(relay);

    address token = IRelayEntrypoint(relay).TOKEN();
    uint256 gross = _idleBalance(relay, token);
    if (gross == 0) revert NoIdleBalance();

    uint256 fee = _takeFeeFromRelay(relay, token, gross);
    IRelayEntrypoint(relay).compound(gross - fee);

    emit ManagementFeeTaken(relay, token, gross, fee);
  }

  /// @notice Swaps a Relay reward token into TOKEN, skims the fee from the measured output, then compounds the net.
  function swapAndCompound(IBaseEntrypoint.SwapParams calldata params) external override nonReentrant {
    _requireKeeper(params.relay);
    if (params.minAmountOut == 0) revert ZeroMinOut();
    if (!FACTORY_REGISTRY.isMetaRouterApproved(params.router)) revert RouterNotApproved();

    address token = IRelayEntrypoint(params.relay).TOKEN();
    if (params.tokenIn == token) revert SameToken();

    uint256 balanceBefore = IERC20(token).balanceOf(address(this));
    IRelayEntrypoint(params.relay).pull(params.tokenIn, params.amountIn);
    params.tokenIn.safeApproveWithRetry(params.router, params.amountIn);
    IMetarouter(params.router).execute(params.commands, params.inputs, params.deadline);
    params.tokenIn.safeApproveWithRetry(params.router, 0);

    uint256 gross = IERC20(token).balanceOf(address(this)) - balanceBefore;
    if (gross < params.minAmountOut) revert InsufficientOutput();

    uint256 fee = _feeFor(gross);
    if (fee != 0) token.safeTransfer(FEE_RECIPIENT, fee);
    uint256 net = gross - fee;
    token.safeTransfer(params.relay, net);
    IRelayEntrypoint(params.relay).compound(net);

    uint256 leftover = IERC20(params.tokenIn).balanceOf(address(this));
    if (leftover != 0) params.tokenIn.safeTransfer(params.relay, leftover);

    emit ManagementFeeTaken(params.relay, token, gross, fee);
  }

  function _requireKeeper(address relay) private view {
    IRelayEntrypoint relayContract = IRelayEntrypoint(relay);
    if (!relayContract.hasAnyRole(msg.sender, relayContract.KEEPER())) revert NotKeeper();
  }

  function _idleBalance(address relay, address token) private view returns (uint256) {
    return IERC20(token).balanceOf(relay) - IRelayEntrypoint(relay).accountedBalance(token);
  }

  function _takeFeeFromRelay(address relay, address token, uint256 gross) private returns (uint256 fee) {
    fee = _feeFor(gross);
    if (fee != 0) {
      IRelayEntrypoint(relay).pull(token, fee);
      token.safeTransfer(FEE_RECIPIENT, fee);
    }
  }

  function _feeFor(uint256 gross) private view returns (uint256) {
    return gross * FEE_BPS / BPS_DENOMINATOR;
  }
}
