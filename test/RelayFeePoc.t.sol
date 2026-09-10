// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Test} from 'forge-std/Test.sol';

import {FeeConverter} from '../src/FeeConverter.sol';
import {DeployRelayPoc} from '../script/DeployRelayPoc.s.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {SingleConverter} from 'V3/relay/entrypoints/SingleConverter.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';

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
    relay = IRelay(deployment.relay);

    vm.warp(deployment.transfersEnabledAt);
    vm.prank(address(deploymentScript));
    IERC20(deployment.token).transfer(alice, 1_000e18);
    vm.startPrank(alice);
    IERC20(deployment.token).approve(deployment.votingEscrow, 1_000e18);
    uint256 tokenId = relay.VOTING_ESCROW().createStake(1_000e18, 0, true);
    relay.VOTING_ESCROW().setApprovalForAll(address(relay), true);
    relay.VOTING_ESCROW().setApprovalForAll(deployment.vpm, true);
    relay.requestDeposit(tokenId, 1_000e18, alice);
    vm.stopPrank();
    vm.prank(keeper);
    relay.processPending(1);
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

    vm.expectRevert(FeeConverter.NotKeeper.selector);
    converter.convertIdleBalance(address(relay));
  }

  function test_revertsWhenNoIdleBalance() public {
    vm.expectRevert(FeeConverter.NoIdleBalance.selector);
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
}
