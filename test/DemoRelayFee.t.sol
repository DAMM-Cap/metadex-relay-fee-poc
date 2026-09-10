// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';

import {FeeConverter} from '../src/FeeConverter.sol';
import {FeeCompounder} from '../src/FeeCompounder.sol';
import {DeployRelayPoc} from '../script/DeployRelayPoc.s.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';

/// @notice Narrated, end-to-end cash-fee walkthrough run by `scripts/dev.sh` against its pinned Base-fork Anvil.
/// @dev This deliberately uses test cheatcodes. The unmodified token's transfer gate prevents an atomic live
///      deployment + relay seed; the fork test is the accurate demonstration of the full flow.
contract DemoRelayFeeTest is Test {
  address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  uint256 internal constant FORK_BLOCK = 50_718_500;
  uint256 internal constant GROSS_REWARD = 11_000e6;
  uint256 internal constant FEE = 1_100e6;
  uint256 internal constant NET_REWARD = 9_900e6;
  uint256 internal constant TOKEN_GROSS = 11_000e18;
  uint256 internal constant TOKEN_FEE = 1_100e18;
  uint256 internal constant TOKEN_NET = 9_900e18;

  function test_demo() public {
    vm.createSelectFork(vm.envString('DEMO_RPC_URL'));
    assertEq(block.chainid, 8453, 'demo must run against a Base fork');

    address manager = makeAddr('manager');
    address keeper = makeAddr('keeper');
    address strategist = makeAddr('strategist');
    address treasury = makeAddr('treasury');
    address alice = makeAddr('alice');

    DeployRelayPoc deployer = new DeployRelayPoc();
    DeployRelayPoc.Deployment memory d = deployer.deployForTest(
      DeployRelayPoc.Actors({
        deployer: address(deployer),
        manager: manager,
        keeper: keeper,
        strategist: strategist,
        treasury: treasury
      })
    );
    IRelay relay = IRelay(d.relay);
    FeeConverter converter = FeeConverter(d.feeConverter);

    console2.log('--- MetaDEX relay cash-fee demo (Base fork @ %s) ---', FORK_BLOCK);
    console2.log('relay              ', d.relay);
    console2.log('feeConverter       ', d.feeConverter);
    console2.log('fee bps            ', converter.FEE_BPS());
    console2.log('fee recipient      ', converter.FEE_RECIPIENT());

    // Give a second holder a stake so the pro-rata split is visible.
    vm.warp(d.transfersEnabledAt);
    vm.prank(address(deployer));
    IERC20(d.token).transfer(alice, 1_000e18);
    vm.startPrank(alice);
    IERC20(d.token).approve(d.votingEscrow, 1_000e18);
    uint256 tokenId = relay.VOTING_ESCROW().createStake(1_000e18, 0, true);
    relay.VOTING_ESCROW().setApprovalForAll(address(relay), true);
    relay.VOTING_ESCROW().setApprovalForAll(d.vpm, true);
    relay.requestDeposit(tokenId, 1_000e18, alice);
    vm.stopPrank();
    vm.prank(keeper);
    relay.processPending(1);

    // A real Base USDC reward arrives as cash; keeper conversion skims cash fee before accounting net.
    deal(USDC, d.relay, GROSS_REWARD);
    vm.prank(keeper);
    converter.convertIdleBalance(d.relay);

    console2.log('');
    console2.log('reward lands on relay (USDC): ', GROSS_REWARD);
    console2.log('manager USDC after (fee)     ', IERC20(USDC).balanceOf(manager));
    console2.log('relay accounted USDC after   ', relay.accountedBalance(USDC));

    vm.prank(treasury);
    uint256 treasuryClaim = relay.claim(USDC, treasury);
    vm.prank(alice);
    uint256 aliceClaim = relay.claim(USDC, alice);

    console2.log('');
    console2.log('treasury claim (net)         ', treasuryClaim);
    console2.log('alice claim (net)            ', aliceClaim);
    console2.log('holders total                ', treasuryClaim + aliceClaim);
    console2.log('manager fee + holders total  ', IERC20(USDC).balanceOf(manager) + treasuryClaim + aliceClaim);
    console2.log('--- gross reward split into fee + net ---');

    assertEq(IERC20(USDC).balanceOf(manager), FEE, 'manager receives cash fee');
    assertEq(relay.accountedBalance(USDC), 0, 'claims clear accounting');
    assertApproxEqAbs(treasuryClaim + aliceClaim, NET_REWARD, 1, 'holders receive net reward');

    // Second path: the sibling FeeCompounder on its own Relay takes its fee in TOKEN and compounds the net into
    // backing, so no new shares mint and every share appreciates. A manager picks one path per Relay.
    IRelay compounderRelay = IRelay(d.compounderRelay);
    FeeCompounder compounder = FeeCompounder(d.feeCompounder);
    uint256 backingBefore = compounderRelay.totalBacking();
    vm.prank(address(deployer));
    IERC20(d.token).transfer(d.compounderRelay, TOKEN_GROSS);
    vm.prank(keeper);
    compounder.compoundIdleBalance(d.compounderRelay);

    console2.log('');
    console2.log('--- MetaDEX relay compounding-fee demo ---');
    console2.log('compounderRelay              ', d.compounderRelay);
    console2.log('feeCompounder                ', d.feeCompounder);
    console2.log('TOKEN reward compounded      ', TOKEN_GROSS);
    console2.log('manager TOKEN after (fee)    ', IERC20(d.token).balanceOf(manager));
    console2.log('backing growth (net)         ', compounderRelay.totalBacking() - backingBefore);
    console2.log('--- gross TOKEN split into fee (cash) + net (compounded) ---');

    assertEq(IERC20(d.token).balanceOf(manager), TOKEN_FEE, 'manager receives compounding fee in TOKEN');
    assertEq(compounderRelay.totalBacking() - backingBefore, TOKEN_NET, 'net compounds into backing');
  }
}
