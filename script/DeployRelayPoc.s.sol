// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Script} from 'forge-std/Script.sol';

import {FeeCompounder} from '../src/FeeCompounder.sol';
import {FeeConverter} from '../src/FeeConverter.sol';
import {VeArtProxy} from 'V3/art/VeArtProxy.sol';
import {RootMessageOrchestrator} from 'V3/bridge/RootMessageOrchestrator.sol';
import {VotingEscrow} from 'V3/core/VotingEscrow.sol';
import {FactoryRegistry} from 'V3/factories/FactoryRegistry.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IMinter} from 'V3/interfaces/minter/IMinter.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {MAX_PIPS, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {Roles} from 'V3/libraries/Roles.sol';
import {Minter} from 'V3/minter/Minter.sol';
import {MaxiRelay} from 'V3/relay/MaxiRelay.sol';
import {ProtocolRelay} from 'V3/relay/ProtocolRelay.sol';
import {RelayFactory} from 'V3/relay/RelayFactory.sol';
import {RelayToken} from 'V3/relay/RelayToken.sol';
import {RelayTokenVotes} from 'V3/relay/RelayTokenVotes.sol';
import {RelayVoteAdapter} from 'V3/relay/RelayVoteAdapter.sol';
import {Splitter} from 'V3/splitter/Splitter.sol';
import {Token} from 'V3/token/Token.sol';
import {Voter} from 'V3/voter/Voter.sol';
import {VoterPaymentsModule} from 'V3/vpm/VoterPaymentsModule.sol';

/// @dev The idle proof never reads governance. This stub only satisfies RelayFactory's non-zero dependency.
contract GovernorStub {}

/// @notice Deploys a root-only MetaDEX stack plus unmodified MaxiRelays and DAMM's two fee entrypoints for fork tests.
contract DeployRelayPoc is Script {
  uint256 public constant BASE_CHAIN_ID = 8453;
  uint256 public constant FORK_BLOCK = 50_718_500;
  address public constant WETH = 0x4200000000000000000000000000000000000006;
  address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  uint256 internal constant MANAGEMENT_FEE_BPS = 1000;
  uint128 internal constant SEED_AMOUNT = 10_000e18;
  /// @dev Mirror RelayRoles bits because IRelayEntrypoint exposes only KEEPER.
  uint256 internal constant COMPOUNDER_ROLE = 1 << 2;
  uint256 internal constant CONVERTER_ROLE = 1 << 3;

  error InvalidActor();
  error TestDeployerMustBeScript(address expected, address actual);
  error UnexpectedChainId(uint256 actual);
  error RelaySmokeFailed(address relay);
  error ConverterRoleMissing(address converter);
  error CompounderRoleMissing(address compounder);

  struct Actors {
    address deployer;
    address manager;
    address keeper;
    address strategist;
    address treasury;
  }

  struct Deployment {
    address token;
    address votingEscrow;
    address voter;
    address vpm;
    address relayFactory;
    address factoryRegistry;
    address feeConverter;
    address feeCompounder;
    address relay;
    address compounderRelay;
    address manager;
    address keeper;
    address strategist;
    address treasury;
    uint48 transfersEnabledAt;
  }

  function deployForTest(Actors memory actors) external returns (Deployment memory deployment) {
    if (actors.deployer != address(this)) revert TestDeployerMustBeScript(address(this), actors.deployer);
    deployment = _deploy(actors, address(this));
  }

  function _deploy(Actors memory actors, address creator) internal returns (Deployment memory deployment) {
    if (block.chainid != BASE_CHAIN_ID) revert UnexpectedChainId(block.chainid);
    if (
      actors.deployer == address(0) || actors.manager == address(0) || actors.keeper == address(0)
        || actors.strategist == address(0) || actors.treasury == address(0)
    ) revert InvalidActor();

    uint48 migrationOpen = uint48((block.timestamp / uint256(WEEK) + 1) * uint256(WEEK));
    uint64 nonce = vm.getNonce(creator);
    address voterAddress = vm.computeCreateAddress(creator, nonce + 1);
    address votingEscrowAddress = vm.computeCreateAddress(creator, nonce + 2);
    address minterAddress = vm.computeCreateAddress(creator, nonce + 3);
    address tokenAddress = vm.computeCreateAddress(creator, nonce + 4);
    address splitterAddress = vm.computeCreateAddress(creator, nonce + 5);
    address artProxyAddress = vm.computeCreateAddress(creator, nonce + 6);

    RootMessageOrchestrator orchestrator = new RootMessageOrchestrator(voterAddress);
    Voter voter = new Voter({
      _orchestrator: address(orchestrator),
      _votingEscrow: votingEscrowAddress,
      _minter: minterAddress,
      _token: tokenAddress,
      _adapterAuthority: actors.deployer,
      _governor: actors.deployer,
      _configAdmin: actors.deployer,
      _allocationLifetime: uint48(1 days),
      _messageLifetime: uint48(1 days)
    });
    VotingEscrow votingEscrow = new VotingEscrow({
      _contracts: IVotingEscrow.Contracts({token: tokenAddress, voter: address(voter), artProxy: artProxyAddress}),
      _admins: IVotingEscrow.Admins({
        vpmAdmin: actors.deployer, artProxyAdmin: actors.deployer, burnFeesAdmin: actors.deployer
      })
    });
    Minter minter = new Minter({
      _params: IMinter.ConstructorParams({
        token: tokenAddress,
        voter: address(voter),
        splitter: splitterAddress,
        operator: actors.deployer,
        migrationOpen: migrationOpen,
        initialBaseRate: 1e18,
        maxBaseRateChangePips: 0,
        baseRateUpdateCooldown: WEEK,
        teamRate: 0,
        maxBaseRateChangePipsCap: 50_000,
        minBaseRateUpdateCooldown: WEEK,
        maxBaseRateUpdateCooldown: WEEK,
        maxBandFloorPips: 1,
        // MAX_PIPS is 1_000_000, safely below uint24 max.
        // forge-lint: disable-next-line(unsafe-typecast)
        maxBandCeilingPips: uint24(MAX_PIPS)
      })
    });
    Token token = new Token({
      _minter: address(minter),
      _votingEscrow: address(votingEscrow),
      _migration: actors.deployer,
      _velodromeMigration: actors.deployer,
      _migrationOpen: migrationOpen,
      _migrationAllocation: 10_000_000e18,
      _velodromeAllocation: 10_000_000e18,
      _name: 'MetaDEX Voting Token',
      _symbol: 'mVOTE'
    });
    address[] memory recipients = new address[](1);
    recipients[0] = actors.deployer;
    uint256[] memory shares = new uint256[](1);
    shares[0] = MAX_PIPS;
    new Splitter({
      _token: address(token), _voter: address(voter), _initialRecipients: recipients, _initialShares: shares
    });
    new VeArtProxy(address(votingEscrow), address(voter));

    VoterPaymentsModule vpm = new VoterPaymentsModule(address(votingEscrow), actors.deployer);
    votingEscrow.grantRole(votingEscrow.VPM_ROLE(), address(vpm));

    RelayToken relayToken = new RelayToken();
    RelayTokenVotes relayTokenVotes = new RelayTokenVotes();
    RelayVoteAdapter voteAdapter = new RelayVoteAdapter();
    MaxiRelay maxiImplementation =
      new MaxiRelay(votingEscrow, voter, address(relayTokenVotes), address(relayToken), WETH);
    ProtocolRelay protocolImplementation =
      new ProtocolRelay(votingEscrow, voter, address(relayTokenVotes), address(relayToken), WETH);
    RelayFactory relayFactory = new RelayFactory(
      votingEscrow,
      address(voter),
      address(maxiImplementation),
      address(protocolImplementation),
      vpm,
      IGovernor(address(new GovernorStub())),
      voteAdapter
    );
    voter.grantRole(Roles.RELAY_DEPLOYER_ROLE, actors.deployer);
    voter.grantRole(Roles.FACTORY_REGISTRY_ADMIN_ROLE, actors.deployer);
    FactoryRegistry factoryRegistry = new FactoryRegistry(address(0), address(voter));

    FeeConverter feeConverter =
      new FeeConverter(factoryRegistry, USDC, actors.deployer, actors.manager, MANAGEMENT_FEE_BPS);

    FeeCompounder feeCompounder =
      new FeeCompounder(factoryRegistry, actors.deployer, actors.manager, MANAGEMENT_FEE_BPS);

    // TOKEN transfers stay gated until one week after migration opens. The seed stake below routes TOKEN through
    // the non-exempt RelayFactory, so advance the clock to the enable time before any relay is seeded.
    vm.warp(uint256(migrationOpen) + 1 weeks);
    token.approve(address(relayFactory), SEED_AMOUNT);

    (address relay,) = relayFactory.createMaxiRelay(
      IRelayFactory.CreateParams({
        admin: actors.deployer,
        keeper: actors.keeper,
        voter: actors.strategist,
        compounder: address(0),
        converter: address(feeConverter),
        bootstrapOwner: actors.treasury,
        rewardToken: USDC,
        entrypointVetoer: address(0),
        seedAmount: SEED_AMOUNT,
        isPermanent: true,
        ytTransferable: false,
        stakingWeeks: 0,
        salt: keccak256('metadex-relay-fee-poc'),
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
      })
    );

    // Smoke checks: the factory recognises the relay, and the fee converter holds the CONVERTER role that
    // authorises pull + notifyReward. If either fails the whole deployment is void.
    if (!relayFactory.isRelay(relay)) revert RelaySmokeFailed(relay);
    if (!IRelayEntrypoint(relay).hasAnyRole(address(feeConverter), CONVERTER_ROLE)) {
      revert ConverterRoleMissing(address(feeConverter));
    }

    // A manager picks one yield path per Relay, so the compounder gets its own single-entrypoint Relay: it holds
    // COMPOUNDER (not CONVERTER), takes its fee in TOKEN, and compounds the net into backing.
    token.approve(address(relayFactory), SEED_AMOUNT);
    (address compounderRelay,) = relayFactory.createMaxiRelay(
      IRelayFactory.CreateParams({
        admin: actors.deployer,
        keeper: actors.keeper,
        voter: actors.strategist,
        compounder: address(feeCompounder),
        converter: address(0),
        bootstrapOwner: actors.treasury,
        rewardToken: USDC,
        entrypointVetoer: address(0),
        seedAmount: SEED_AMOUNT,
        isPermanent: true,
        ytTransferable: false,
        stakingWeeks: 0,
        salt: keccak256('metadex-relay-fee-poc-compounder'),
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
      })
    );
    if (!relayFactory.isRelay(compounderRelay)) revert RelaySmokeFailed(compounderRelay);
    if (!IRelayEntrypoint(compounderRelay).hasAnyRole(address(feeCompounder), COMPOUNDER_ROLE)) {
      revert CompounderRoleMissing(address(feeCompounder));
    }

    deployment = Deployment({
      token: address(token),
      votingEscrow: address(votingEscrow),
      voter: address(voter),
      vpm: address(vpm),
      relayFactory: address(relayFactory),
      factoryRegistry: address(factoryRegistry),
      relay: relay,
      compounderRelay: compounderRelay,
      feeConverter: address(feeConverter),
      feeCompounder: address(feeCompounder),
      manager: actors.manager,
      keeper: actors.keeper,
      strategist: actors.strategist,
      treasury: actors.treasury,
      transfersEnabledAt: uint48(token.TRANSFERS_ENABLED_AT())
    });
  }
}
