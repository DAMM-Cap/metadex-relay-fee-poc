// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Test} from 'forge-std/Test.sol';

import {FeeConverter} from '../src/FeeConverter.sol';
import {FeeCompounder} from '../src/FeeCompounder.sol';
import {DeployRelayPoc} from '../script/DeployRelayPoc.s.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {SingleConverter} from 'V3/relay/entrypoints/SingleConverter.sol';
import {Compounder} from 'V3/relay/entrypoints/Compounder.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {ISingleConverter} from 'V3/interfaces/relay/entrypoints/ISingleConverter.sol';
import {ICompounder} from 'V3/interfaces/relay/entrypoints/ICompounder.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';

contract RelayFeePocTest is Test {
  address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  uint256 internal constant FORK_BLOCK = 50_718_500;
  uint256 internal constant GROSS_REWARD = 11_000e6;
  uint256 internal constant NET_REWARD = 9_900e6;
  uint256 internal constant FEE = 1_100e6;

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
    deployment = deploymentScript.deployForTest(DeployRelayPoc.Actors({
      deployer: address(deploymentScript),
      manager: manager,
      keeper: keeper,
      strategist: strategist,
      treasury: treasury
    }));
    converter = FeeConverter(deployment.feeConverter);
    compounder = FeeCompounder(deployment.feeCompounder);
    relay = IRelay(deployment.relay);
    compounderRelay = IRelay(deployment.compounderRelay);

    vm.warp(deployment.transfersEnabledAt);
    _depositAlice(relay, 1_000e18);
    _depositAlice(compounderRelay, 1_000e18);
  }

  /// @dev Alice stakes a fresh veNFT and deposits it into `r`, so she becomes a real Relay share holder.
  function _depositAlice(IRelay r, uint128 amount) private {
    vm.prank(address(deploymentScript));
    IERC20(deployment.token).transfer(alice, amount);
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
      IRelayEntrypoint(address(relay)).hasAnyRole(address(configuredConverter), 1 << 3),
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
    emit FeeConverter.ManagementFeeTaken(address(relay), USDC, GROSS_REWARD, FEE);
    vm.prank(keeper);
    converter.convertIdleBalance(address(relay));

    assertEq(IERC20(USDC).balanceOf(manager), FEE, 'manager receives cash fee');
    assertEq(relay.accountedBalance(USDC), NET_REWARD, 'only net reward is accounted');
    assertEq(IERC20(address(relay.yieldToken())).balanceOf(manager), 0, 'manager receives no yield tokens');
    assertEq(IERC20(address(relay.principalToken())).balanceOf(manager), 0, 'manager receives no principal tokens');
  }

  function test_holdersClaimExactlyNetProRata() public {
    deal(USDC, address(relay), GROSS_REWARD);
    vm.prank(keeper);
    converter.convertIdleBalance(address(relay));

    uint256 treasuryYT = IERC20(address(relay.yieldToken())).balanceOf(treasury);
    uint256 aliceYT = IERC20(address(relay.yieldToken())).balanceOf(alice);
    uint256 totalYT = IERC20(address(relay.yieldToken())).totalSupply();
    uint256 expectedTreasury = NET_REWARD * treasuryYT / totalYT;
    uint256 expectedAlice = NET_REWARD * aliceYT / totalYT;

    vm.prank(treasury);
    uint256 treasuryClaim = relay.claim(USDC, treasury);
    vm.prank(alice);
    uint256 aliceClaim = relay.claim(USDC, alice);

    assertApproxEqAbs(treasuryClaim, expectedTreasury, 1, 'treasury claim is pro rata');
    assertApproxEqAbs(aliceClaim, expectedAlice, 1, 'alice claim is pro rata');
    assertApproxEqAbs(treasuryClaim + aliceClaim, NET_REWARD, 1, 'holders claim exactly net');
  }

  function test_parityWithStockConverterAtZeroFee() public {
    FeeConverter zeroFeeConverter = new FeeConverter(converter.FACTORY_REGISTRY(), USDC, manager, 0);
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
    vm.expectRevert(abi.encodeWithSelector(FeeConverter.FeeTooHigh.selector, 5_001));
    new FeeConverter(registry, USDC, manager, 5_001);
  }

  function test_secondRoundAfterPartialClaim() public {
    deal(USDC, address(relay), GROSS_REWARD);
    vm.prank(keeper);
    converter.convertIdleBalance(address(relay));
    vm.prank(alice);
    uint256 aliceFirst = relay.claim(USDC, alice);

    // Fresh second-round reward stacked on top of the still-unclaimed first round.
    uint256 secondGross = 1_000e6;
    deal(USDC, address(relay), IERC20(USDC).balanceOf(address(relay)) + secondGross);
    vm.prank(keeper);
    converter.convertIdleBalance(address(relay));

    // Fee is 10% of each round's gross, banked across rounds.
    assertEq(IERC20(USDC).balanceOf(manager), FEE + secondGross / 10, 'fee is banked across rounds');

    vm.prank(treasury);
    uint256 treasuryClaim = relay.claim(USDC, treasury);
    vm.prank(alice);
    uint256 aliceSecond = relay.claim(USDC, alice);

    // Holders draw both rounds' net down to accumulator dust: notifyReward accounts the share-divisible part and
    // strands the sub-unit remainder per round (documented "rounded up, rest un-accounted" behaviour). Two rounds
    // over an ~11e18 YT supply leave well under a cent of 6-decimal USDC un-drawn.
    uint256 netTotal = NET_REWARD + (secondGross - secondGross / 10);
    uint256 dust = 10_000; // 0.01 USDC
    assertApproxEqAbs(aliceFirst + aliceSecond + treasuryClaim, netTotal, dust, 'holders draw both rounds net minus dust');
    assertApproxEqAbs(relay.accountedBalance(USDC), 0, dust, 'accounting clears to dust after claims');
  }

  /// @notice NFT deposit (setUp) -> configured compounder -> Relay backing grows -> every share appreciates.
  /// @dev The fee-in-cash sibling routes value to holder claims; the compounder instead takes its fee in TOKEN and
  ///      compounds the net into `totalBacking`, so no new shares are minted and each existing share is worth more.
  function test_nftDepositBackingGrowsThroughConfiguredCompounder() public {
    ICompounder configuredCompounder = compounder;
    assertTrue(
      IRelayEntrypoint(address(compounderRelay)).hasAnyRole(address(configuredCompounder), 1 << 2),
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
    IERC20(token).transfer(address(compounderRelay), gross);

    vm.expectEmit(true, true, false, true, address(configuredCompounder));
    emit FeeCompounder.ManagementFeeTaken(address(compounderRelay), token, gross, fee);
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

    uint256 backingBefore = compounderRelay.totalBacking();
    vm.prank(address(deploymentScript));
    IERC20(token).transfer(address(compounderRelay), gross);

    vm.prank(keeper);
    compounder.compoundIdleBalance(address(compounderRelay));

    assertEq(IERC20(token).balanceOf(manager), fee, 'manager receives the fee in TOKEN');
    assertEq(compounderRelay.totalBacking() - backingBefore, net, 'only the net is compounded into backing');
    assertEq(IERC20(token).balanceOf(address(compounderRelay)), 0, 'no idle TOKEN is stranded on the Relay');
    assertEq(IERC20(USDC).balanceOf(manager), 0, 'the compounder never pays the manager in the reward token');
  }

  function test_parityWithStockCompounderAtZeroFee() public {
    FeeCompounder zeroFeeCompounder = new FeeCompounder(compounder.FACTORY_REGISTRY(), manager, 0);
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
    IERC20(token).transfer(zeroFeeRelay, gross);
    IERC20(token).transfer(stockRelay, gross);
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
    IERC20(deployment.token).transfer(address(compounderRelay), 11_000e18);

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
    vm.expectRevert(abi.encodeWithSelector(FeeCompounder.FeeTooHigh.selector, 5_001));
    new FeeCompounder(registry, manager, 5_001);
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

  function _compounderParams(address compounder_, bytes32 salt) private view returns (IRelayFactory.CreateParams memory) {
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
