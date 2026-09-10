// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Test} from 'forge-std/Test.sol';

import {DeployRelayPoc} from '../script/DeployRelayPoc.s.sol';
import {FeeCompounder} from '../src/FeeCompounder.sol';
import {FeeConverter} from '../src/FeeConverter.sol';
import {FeeEntrypointBase} from '../src/FeeEntrypointBase.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FactoryRegistry} from 'V3/factories/FactoryRegistry.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {ICompounder} from 'V3/interfaces/relay/entrypoints/ICompounder.sol';
import {ISingleConverter} from 'V3/interfaces/relay/entrypoints/ISingleConverter.sol';
import {Compounder} from 'V3/relay/entrypoints/Compounder.sol';
import {SingleConverter} from 'V3/relay/entrypoints/SingleConverter.sol';

contract SwapRouterStub {
  address internal immutable INPUT_TOKEN;
  address internal immutable OUTPUT_TOKEN;
  uint256 internal immutable SPEND_AMOUNT;
  uint256 internal immutable OUTPUT_AMOUNT;

  error DeadlineExpired();
  error TransferFailed();

  constructor(address inputToken, address outputToken, uint256 spendAmount, uint256 outputAmount) {
    INPUT_TOKEN = inputToken;
    OUTPUT_TOKEN = outputToken;
    SPEND_AMOUNT = spendAmount;
    OUTPUT_AMOUNT = outputAmount;
  }

  function execute(bytes calldata, bytes[] calldata, uint256 deadline) external {
    if (block.timestamp > deadline) revert DeadlineExpired();
    if (!IERC20(INPUT_TOKEN).transferFrom(msg.sender, address(this), SPEND_AMOUNT)) revert TransferFailed();
    if (!IERC20(OUTPUT_TOKEN).transfer(msg.sender, OUTPUT_AMOUNT)) revert TransferFailed();
  }
}

contract RelayFeePocTest is Test {
  address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address internal constant WETH = 0x4200000000000000000000000000000000000006;
  uint256 internal constant COMPOUNDER_ROLE = 1 << 2;
  uint256 internal constant CONVERTER_ROLE = 1 << 3;
  uint256 internal constant FORK_BLOCK = 50_718_500;
  uint256 internal constant GROSS_REWARD = 11_000e6;
  uint256 internal constant NET_REWARD = 9900e6;
  uint256 internal constant FEE = 1100e6;

  DeployRelayPoc internal deploymentScript;
  DeployRelayPoc.Deployment internal deployment;
  FeeConverter internal converter;
  IRelay internal relay;
  IRelay internal compounderRelay;
  FeeCompounder internal compounder;
  address internal manager;
  address internal keeper;
  address internal strategist;
  address internal treasury;
  address internal alice;

  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('base'), FORK_BLOCK);

    manager = makeAddr('manager');
    keeper = makeAddr('keeper');
    strategist = makeAddr('strategist');
    treasury = makeAddr('treasury');
    alice = makeAddr('alice');
    deploymentScript = new DeployRelayPoc();
    deployment = deploymentScript.deployForTest(
      DeployRelayPoc.Actors({
        deployer: address(deploymentScript),
        manager: manager,
        keeper: keeper,
        strategist: strategist,
        treasury: treasury
      })
    );
    converter = FeeConverter(deployment.feeConverter);
    compounder = FeeCompounder(deployment.feeCompounder);
    relay = IRelay(deployment.relay);
    compounderRelay = IRelay(deployment.compounderRelay);

    vm.warp(deployment.transfersEnabledAt);
    _depositAlice(relay, 1000e18);
    _depositAlice(compounderRelay, 1000e18);
  }

  /// @dev Alice stakes a fresh veNFT and deposits it into `r`, so she becomes a real Relay share holder.
  function _depositAlice(IRelay r, uint128 amount) private {
    vm.prank(address(deploymentScript));
    assertTrue(IERC20(deployment.token).transfer(alice, amount), 'TOKEN funding transfer failed');
    vm.startPrank(alice);
    IERC20(deployment.token).approve(deployment.votingEscrow, amount);
    uint256 tokenId = r.VOTING_ESCROW().createStake(amount, 0, true);
    r.VOTING_ESCROW().setApprovalForAll(address(r), true);
    r.VOTING_ESCROW().setApprovalForAll(deployment.vpm, true);
    r.requestDeposit(tokenId, amount, alice);
    vm.stopPrank();
    vm.prank(keeper);
    r.processPending(1);
  }

  /// @notice NFT deposit (setUp) -> configured converter -> Relay accumulator -> holder claims.
  /// @dev MetaDEX's keeper invokes its configured converter; the converter then enters the Relay through
  ///      CONVERTER-gated `pull` and `notifyReward`. Relay has no callback that dispatches into a converter.
  function test_nftDepositToHolderClaimThroughConfiguredConverter() public {
    ISingleConverter configuredConverter = converter;
    assertTrue(
      IRelayEntrypoint(address(relay)).hasAnyRole(address(configuredConverter), CONVERTER_ROLE),
      'factory must attach converter with CONVERTER role'
    );
    assertGt(IERC20(address(relay.yieldToken())).balanceOf(alice), 0, 'NFT deposit must mint Alice yield shares');

    deal(USDC, address(relay), GROSS_REWARD);
    vm.expectEmit(true, false, false, false, address(relay));
    emit IRelay.RewardNotified(USDC, 0, 0);
    vm.prank(keeper);
    configuredConverter.convertIdleBalance(address(relay));

    assertEq(IERC20(USDC).balanceOf(manager), FEE, 'configured converter pays manager in cash');
    assertEq(relay.accountedBalance(USDC), NET_REWARD, 'Relay records only the notified net reward');

    vm.prank(treasury);
    uint256 treasuryClaim = relay.claim(USDC, treasury);
    vm.prank(alice);
    uint256 aliceClaim = relay.claim(USDC, alice);
    assertGt(aliceClaim, 0, 'NFT depositor claims a non-zero net reward');
    assertApproxEqAbs(treasuryClaim + aliceClaim, NET_REWARD, 1, 'holders claim the Relay-notified net reward');
  }

  function test_feeIsCashOutAndNetIsAccounted() public {
    deal(USDC, address(relay), GROSS_REWARD);

    vm.expectEmit(true, true, false, true, address(converter));
    emit FeeEntrypointBase.ManagementFeeTaken(address(relay), USDC, GROSS_REWARD, FEE);
    vm.prank(keeper);
    converter.convertIdleBalance(address(relay));

    assertEq(IERC20(USDC).balanceOf(manager), FEE, 'manager receives cash fee');
    assertEq(relay.accountedBalance(USDC), NET_REWARD, 'only net reward is accounted');
    assertEq(IERC20(address(relay.yieldToken())).balanceOf(manager), 0, 'manager receives no yield tokens');
    assertEq(IERC20(address(relay.principalToken())).balanceOf(manager), 0, 'manager receives no principal tokens');
  }

  function test_feeOwnerCanUpdateRecipientForBothEntrypoints() public {
    address newRecipient = makeAddr('newFeeRecipient');
    vm.startPrank(address(deploymentScript));
    converter.setFeeRecipient(newRecipient);
    compounder.setFeeRecipient(newRecipient);
    vm.stopPrank();

    deal(USDC, address(relay), GROSS_REWARD);
    uint256 tokenGross = 11_000e18;
    vm.prank(address(deploymentScript));
    assertTrue(
      IERC20(deployment.token).transfer(address(compounderRelay), tokenGross), 'compounder TOKEN transfer failed'
    );

    vm.startPrank(keeper);
    converter.convertIdleBalance(address(relay));
    compounder.compoundIdleBalance(address(compounderRelay));
    vm.stopPrank();

    assertEq(IERC20(USDC).balanceOf(newRecipient), FEE, 'new recipient receives converter fee');
    assertEq(IERC20(deployment.token).balanceOf(newRecipient), tokenGross / 10, 'new recipient receives compounder fee');
    assertEq(IERC20(USDC).balanceOf(manager), 0, 'old recipient receives no converter fee');
    assertEq(IERC20(deployment.token).balanceOf(manager), 0, 'old recipient receives no compounder fee');
  }

  function test_nonOwnerCannotUpdateFeeRecipient() public {
    address unauthorized = makeAddr('unauthorized');
    vm.startPrank(unauthorized);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
    converter.setFeeRecipient(makeAddr('newFeeRecipient'));
    vm.stopPrank();
  }

  function test_feeOwnerCannotSetZeroRecipient() public {
    vm.startPrank(address(deploymentScript));
    vm.expectRevert(IBaseEntrypoint.ZeroAddress.selector);
    converter.setFeeRecipient(address(0));
    vm.stopPrank();
  }

  function test_holdersClaimExactlyNetProRata() public {
    deal(USDC, address(relay), GROSS_REWARD);
    vm.prank(keeper);
    converter.convertIdleBalance(address(relay));

    uint256 treasuryYt = IERC20(address(relay.yieldToken())).balanceOf(treasury);
    uint256 aliceYt = IERC20(address(relay.yieldToken())).balanceOf(alice);
    uint256 totalYt = IERC20(address(relay.yieldToken())).totalSupply();
    uint256 expectedTreasury = NET_REWARD * treasuryYt / totalYt;
    uint256 expectedAlice = NET_REWARD * aliceYt / totalYt;

    vm.prank(treasury);
    uint256 treasuryClaim = relay.claim(USDC, treasury);
    vm.prank(alice);
    uint256 aliceClaim = relay.claim(USDC, alice);

    assertApproxEqAbs(treasuryClaim, expectedTreasury, 1, 'treasury claim is pro rata');
    assertApproxEqAbs(aliceClaim, expectedAlice, 1, 'alice claim is pro rata');
    assertApproxEqAbs(treasuryClaim + aliceClaim, NET_REWARD, 1, 'holders claim exactly net');
  }

  function test_parityWithStockConverterAtZeroFee() public {
    FeeConverter zeroFeeConverter = new FeeConverter(converter.FACTORY_REGISTRY(), USDC, address(this), manager, 0);
    SingleConverter stockConverter = new SingleConverter(converter.FACTORY_REGISTRY(), USDC);
    IRelayFactory factory = IRelayFactory(deployment.relayFactory);

    vm.startPrank(address(deploymentScript));
    IERC20(deployment.token).approve(address(factory), 20_000e18);
    (address zeroFeeRelay,) = factory.createMaxiRelay(_createParams(address(zeroFeeConverter), keccak256('zero-fee')));
    (address stockRelay,) = factory.createMaxiRelay(_createParams(address(stockConverter), keccak256('stock')));
    vm.stopPrank();

    deal(USDC, zeroFeeRelay, GROSS_REWARD);
    deal(USDC, stockRelay, GROSS_REWARD);
    vm.prank(keeper);
    zeroFeeConverter.convertIdleBalance(zeroFeeRelay);
    vm.prank(keeper);
    stockConverter.convertIdleBalance(stockRelay);

    vm.prank(treasury);
    uint256 zeroFeePayout = IRelay(zeroFeeRelay).claim(USDC, treasury);
    vm.prank(treasury);
    uint256 stockPayout = IRelay(stockRelay).claim(USDC, treasury);

    assertEq(zeroFeePayout, stockPayout, 'zero-fee custom converter matches stock converter');
    assertEq(zeroFeePayout, GROSS_REWARD, 'all rewards reach the sole holder');
  }

  function test_revertsWhenNotKeeper() public {
    deal(USDC, address(relay), GROSS_REWARD);

    vm.expectRevert(IBaseEntrypoint.NotKeeper.selector);
    converter.convertIdleBalance(address(relay));
  }

  function test_revertsWhenNoIdleBalance() public {
    vm.expectRevert(IBaseEntrypoint.NoIdleBalance.selector);
    vm.prank(keeper);
    converter.convertIdleBalance(address(relay));
  }

  function test_constructorRejectsFeeAboveCap() public {
    IFactoryRegistry registry = converter.FACTORY_REGISTRY();
    vm.expectRevert(abi.encodeWithSelector(FeeEntrypointBase.FeeTooHigh.selector, 5001));
    new FeeConverter(registry, USDC, address(this), manager, 5001);
  }

  function test_secondRoundAfterPartialClaim() public {
    deal(USDC, address(relay), GROSS_REWARD);
    vm.prank(keeper);
    converter.convertIdleBalance(address(relay));
    vm.prank(alice);
    uint256 aliceFirst = relay.claim(USDC, alice);

    // Fresh second-round reward stacked on top of the still-unclaimed first round plus its accumulator residue.
    uint256 secondGross = 1000e6;
    deal(USDC, address(relay), IERC20(USDC).balanceOf(address(relay)) + secondGross);
    uint256 secondIdleBalance = IERC20(USDC).balanceOf(address(relay)) - relay.accountedBalance(USDC);
    vm.prank(keeper);
    converter.convertIdleBalance(address(relay));

    // Like the stock converters, each round fees the whole unaccounted idle balance.
    assertEq(IERC20(USDC).balanceOf(manager), FEE + secondIdleBalance / 10, 'fee is banked across rounds');

    vm.prank(treasury);
    uint256 treasuryClaim = relay.claim(USDC, treasury);
    vm.prank(alice);
    uint256 aliceSecond = relay.claim(USDC, alice);

    // Holders draw everything that ever arrived, minus the fees taken and the sub-unit accumulator residue that
    // notifyReward strands each round. Two rounds over an ~11e18 YT supply leave well under a cent of 6-decimal USDC.
    uint256 netTotal = (GROSS_REWARD + secondGross) - IERC20(USDC).balanceOf(manager);
    uint256 dust = 10_000; // 0.01 USDC
    assertApproxEqAbs(
      aliceFirst + aliceSecond + treasuryClaim, netTotal, dust, 'holders draw both rounds net minus dust'
    );
    assertApproxEqAbs(relay.accountedBalance(USDC), 0, dust, 'accounting clears to dust after claims');
  }

  function test_converterFeesWholeIdleBalanceIncludingPriorRoundResidue() public {
    uint256 firstGross = GROSS_REWARD + 1000;
    deal(USDC, address(relay), firstGross);
    vm.prank(keeper);
    converter.convertIdleBalance(address(relay));

    uint256 firstFee = IERC20(USDC).balanceOf(manager);
    uint256 priorResidue = IERC20(USDC).balanceOf(address(relay)) - relay.accountedBalance(USDC);
    assertGe(priorResidue, 10, 'fixture must leave fee-relevant prior-round residue');

    uint256 secondGross = 1000e6;
    deal(USDC, address(relay), IERC20(USDC).balanceOf(address(relay)) + secondGross);
    uint256 secondIdleBalance = IERC20(USDC).balanceOf(address(relay)) - relay.accountedBalance(USDC);
    vm.prank(keeper);
    converter.convertIdleBalance(address(relay));

    assertEq(
      IERC20(USDC).balanceOf(manager) - firstFee,
      secondIdleBalance / 10,
      'fee must cover the whole idle balance like stock converters'
    );
  }

  function test_swapAndConvertChargesOnlySwapOutputAndPreservesInputLeftover() public {
    uint256 amountIn = 10e18;
    uint256 amountSpent = 7e18;
    uint256 swapGross = GROSS_REWARD + 1000;
    uint256 directGross = 1000e6;
    SwapRouterStub router = new SwapRouterStub(WETH, USDC, amountSpent, swapGross);

    vm.prank(address(deploymentScript));
    FactoryRegistry(deployment.factoryRegistry).registerMetaRouter(address(router));
    deal(WETH, address(relay), amountIn);
    deal(USDC, address(relay), directGross);
    deal(USDC, address(router), swapGross);

    vm.prank(keeper);
    converter.swapAndConvert(_swapParams(address(relay), address(router), amountIn, swapGross));

    uint256 swapFee = swapGross / 10;
    assertEq(IERC20(USDC).balanceOf(manager), swapFee, 'manager fee is based only on measured swap output');
    assertEq(IERC20(WETH).balanceOf(address(relay)), amountIn - amountSpent, 'unspent input returns to Relay');
    assertEq(IERC20(WETH).allowance(address(converter), address(router)), 0, 'router allowance is cleared');

    uint256 idleBalance = IERC20(USDC).balanceOf(address(relay)) - relay.accountedBalance(USDC);
    vm.prank(keeper);
    converter.convertIdleBalance(address(relay));
    assertEq(
      IERC20(USDC).balanceOf(manager) - swapFee,
      idleBalance / 10,
      'later idle conversion fees the whole unaccounted balance, including swap-round residue'
    );
  }

  function test_entrypointsCannotProcessSiblingRelay() public {
    assertFalse(
      IRelayEntrypoint(address(relay)).hasAnyRole(address(compounder), COMPOUNDER_ROLE),
      'converter Relay must not grant COMPOUNDER to FeeCompounder'
    );
    assertFalse(
      IRelayEntrypoint(address(compounderRelay)).hasAnyRole(address(converter), CONVERTER_ROLE),
      'compounder Relay must not grant CONVERTER to FeeConverter'
    );

    deal(USDC, address(compounderRelay), GROSS_REWARD);
    vm.expectRevert(IRelay.NotAuthorized.selector);
    vm.prank(keeper);
    converter.convertIdleBalance(address(compounderRelay));

    vm.prank(address(deploymentScript));
    assertTrue(IERC20(deployment.token).transfer(address(relay), 11_000e18), 'cross-entrypoint TOKEN transfer failed');
    vm.expectRevert(IRelay.NotAuthorized.selector);
    vm.prank(keeper);
    compounder.compoundIdleBalance(address(relay));

    assertEq(IERC20(USDC).balanceOf(manager), 0, 'failed cross-entrypoint calls pay no fee');
    assertEq(IERC20(deployment.token).balanceOf(manager), 0, 'failed cross-entrypoint calls move no TOKEN');
  }

  /// @notice NFT deposit (setUp) -> configured compounder -> Relay backing grows -> every share appreciates.
  /// @dev The fee-in-cash sibling routes value to holder claims; the compounder instead takes its fee in TOKEN and
  ///      compounds the net into `totalBacking`, so no new shares are minted and each existing share is worth more.
  function test_nftDepositBackingGrowsThroughConfiguredCompounder() public {
    ICompounder configuredCompounder = compounder;
    assertTrue(
      IRelayEntrypoint(address(compounderRelay)).hasAnyRole(address(configuredCompounder), COMPOUNDER_ROLE),
      'factory must attach compounder with COMPOUNDER role'
    );
    uint256 aliceShares = IERC20(address(compounderRelay.yieldToken())).balanceOf(alice);
    assertGt(aliceShares, 0, 'NFT deposit must mint Alice yield shares');

    address token = deployment.token;
    uint256 gross = 11_000e18;
    uint256 fee = gross / 10;
    uint256 net = gross - fee;

    uint256 backingBefore = compounderRelay.totalBacking();
    vm.prank(address(deploymentScript));
    assertTrue(IERC20(token).transfer(address(compounderRelay), gross), 'compounder TOKEN transfer failed');

    vm.expectEmit(true, true, false, true, address(configuredCompounder));
    emit FeeEntrypointBase.ManagementFeeTaken(address(compounderRelay), token, gross, fee);
    vm.prank(keeper);
    configuredCompounder.compoundIdleBalance(address(compounderRelay));

    assertEq(IERC20(token).balanceOf(manager), fee, 'configured compounder pays manager in TOKEN');
    assertEq(compounderRelay.totalBacking(), backingBefore + net, 'net compounds into backing');
    assertEq(
      IERC20(address(compounderRelay.yieldToken())).balanceOf(alice), aliceShares, 'compounding mints no new shares'
    );
  }

  function test_compounderFeeInTokenAndNetCompounded() public {
    address token = deployment.token;
    uint256 gross = 11_000e18;
    uint256 fee = gross / 10;
    uint256 net = gross - fee;
    uint256 idleUsdc = 123e6;

    uint256 backingBefore = compounderRelay.totalBacking();
    vm.prank(address(deploymentScript));
    assertTrue(IERC20(token).transfer(address(compounderRelay), gross), 'compounder TOKEN transfer failed');
    deal(USDC, address(compounderRelay), idleUsdc);

    vm.prank(keeper);
    compounder.compoundIdleBalance(address(compounderRelay));

    assertEq(IERC20(token).balanceOf(manager), fee, 'manager receives the fee in TOKEN');
    assertEq(compounderRelay.totalBacking() - backingBefore, net, 'only the net is compounded into backing');
    assertEq(IERC20(token).balanceOf(address(compounderRelay)), 0, 'no idle TOKEN is stranded on the Relay');
    assertEq(IERC20(USDC).balanceOf(address(compounderRelay)), idleUsdc, 'registered reward remains idle');
    assertEq(IERC20(USDC).balanceOf(manager), 0, 'the compounder never pays the manager in the reward token');
  }

  function test_swapAndCompoundChargesTokenFeeAndReturnsInputLeftover() public {
    address token = deployment.token;
    uint256 amountIn = 10e18;
    uint256 amountSpent = 7e18;
    uint256 gross = 11_000e18;
    uint256 fee = gross / 10;
    SwapRouterStub router = new SwapRouterStub(WETH, token, amountSpent, gross);

    vm.prank(address(deploymentScript));
    FactoryRegistry(deployment.factoryRegistry).registerMetaRouter(address(router));
    deal(WETH, address(compounderRelay), amountIn);
    vm.prank(address(deploymentScript));
    assertTrue(IERC20(token).transfer(address(router), gross), 'router TOKEN funding failed');
    uint256 backingBefore = compounderRelay.totalBacking();

    vm.prank(keeper);
    compounder.swapAndCompound(_swapParams(address(compounderRelay), address(router), amountIn, gross));

    assertEq(IERC20(token).balanceOf(manager), fee, 'manager receives measured swap fee in TOKEN');
    assertEq(compounderRelay.totalBacking() - backingBefore, gross - fee, 'only swap net compounds into backing');
    assertEq(IERC20(WETH).balanceOf(address(compounderRelay)), amountIn - amountSpent, 'unspent input returns to Relay');
    assertEq(IERC20(WETH).allowance(address(compounder), address(router)), 0, 'router allowance is cleared');
    assertEq(IERC20(token).balanceOf(address(compounderRelay)), 0, 'no swapped TOKEN remains idle');
  }

  function test_parityWithStockCompounderAtZeroFee() public {
    FeeCompounder zeroFeeCompounder = new FeeCompounder(compounder.FACTORY_REGISTRY(), address(this), manager, 0);
    Compounder stockCompounder = new Compounder(compounder.FACTORY_REGISTRY());
    IRelayFactory factory = IRelayFactory(deployment.relayFactory);

    vm.startPrank(address(deploymentScript));
    IERC20(deployment.token).approve(address(factory), 20_000e18);
    (address zeroFeeRelay,) =
      factory.createMaxiRelay(_compounderParams(address(zeroFeeCompounder), keccak256('zero-fee-compounder')));
    (address stockRelay,) =
      factory.createMaxiRelay(_compounderParams(address(stockCompounder), keccak256('stock-compounder')));
    vm.stopPrank();

    address token = deployment.token;
    uint256 gross = 11_000e18;
    uint256 zeroBackingBefore = IRelay(zeroFeeRelay).totalBacking();
    uint256 stockBackingBefore = IRelay(stockRelay).totalBacking();

    vm.startPrank(address(deploymentScript));
    assertTrue(IERC20(token).transfer(zeroFeeRelay, gross), 'zero-fee Relay funding failed');
    assertTrue(IERC20(token).transfer(stockRelay, gross), 'stock Relay funding failed');
    vm.stopPrank();

    vm.prank(keeper);
    zeroFeeCompounder.compoundIdleBalance(zeroFeeRelay);
    vm.prank(keeper);
    stockCompounder.compoundIdleBalance(stockRelay);

    uint256 zeroGrowth = IRelay(zeroFeeRelay).totalBacking() - zeroBackingBefore;
    uint256 stockGrowth = IRelay(stockRelay).totalBacking() - stockBackingBefore;
    assertEq(zeroGrowth, stockGrowth, 'zero-fee custom compounder matches stock compounder');
    assertEq(zeroGrowth, gross, 'all TOKEN compounds into backing at zero fee');
  }

  function test_compounderRevertsWhenNotKeeper() public {
    vm.prank(address(deploymentScript));
    assertTrue(
      IERC20(deployment.token).transfer(address(compounderRelay), 11_000e18), 'compounder TOKEN transfer failed'
    );

    vm.expectRevert(IBaseEntrypoint.NotKeeper.selector);
    compounder.compoundIdleBalance(address(compounderRelay));
  }

  function test_compounderRevertsWhenNoIdleBalance() public {
    vm.expectRevert(IBaseEntrypoint.NoIdleBalance.selector);
    vm.prank(keeper);
    compounder.compoundIdleBalance(address(compounderRelay));
  }

  function test_compounderRejectsFeeAboveCap() public {
    IFactoryRegistry registry = compounder.FACTORY_REGISTRY();
    vm.expectRevert(abi.encodeWithSelector(FeeEntrypointBase.FeeTooHigh.selector, 5001));
    new FeeCompounder(registry, address(this), manager, 5001);
  }

  function _swapParams(
    address relay_,
    address router,
    uint256 amountIn,
    uint256 minAmountOut
  ) private view returns (IBaseEntrypoint.SwapParams memory) {
    return IBaseEntrypoint.SwapParams({
      relay: relay_,
      router: router,
      tokenIn: WETH,
      amountIn: amountIn,
      minAmountOut: minAmountOut,
      deadline: block.timestamp + 1,
      commands: '',
      inputs: new bytes[](0)
    });
  }

  function _createParams(address converter_, bytes32 salt) private view returns (IRelayFactory.CreateParams memory) {
    return IRelayFactory.CreateParams({
      admin: address(deploymentScript),
      keeper: keeper,
      voter: strategist,
      compounder: address(0),
      converter: converter_,
      bootstrapOwner: treasury,
      rewardToken: USDC,
      entrypointVetoer: address(0),
      seedAmount: 10_000e18,
      isPermanent: true,
      ytTransferable: false,
      stakingWeeks: 0,
      salt: salt,
      config: IRelay.RelayConfig({
        tokenId: 0,
        minDeposit: 1e18,
        keeperWindow: 1 days,
        minWithdrawal: 1e18,
        entrypointTimelock: 2 days,
        lockWeeks: 0,
        evacuationWindow: 7 days,
        name: 'DAMM Relay',
        symbol: 'dREL'
      })
    });
  }

  function _compounderParams(
    address compounder_,
    bytes32 salt
  ) private view returns (IRelayFactory.CreateParams memory) {
    return IRelayFactory.CreateParams({
      admin: address(deploymentScript),
      keeper: keeper,
      voter: strategist,
      compounder: compounder_,
      converter: address(0),
      bootstrapOwner: treasury,
      rewardToken: USDC,
      entrypointVetoer: address(0),
      seedAmount: 10_000e18,
      isPermanent: true,
      ytTransferable: false,
      stakingWeeks: 0,
      salt: salt,
      config: IRelay.RelayConfig({
        tokenId: 0,
        minDeposit: 1e18,
        keeperWindow: 1 days,
        minWithdrawal: 1e18,
        entrypointTimelock: 2 days,
        lockWeeks: 0,
        evacuationWindow: 7 days,
        name: 'DAMM Relay',
        symbol: 'dREL'
      })
    });
  }
}
