// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZKIdentityRegistry, IZKVerifier} from "../contracts/ZKIdentityRegistry.sol";

/// Settable stand-in for the Groth16 verifier, so the registry's own logic is
/// tested independently of a real proof (Verifier.t.sol covers a real one).
contract MockVerifier is IZKVerifier {
    bool public result = true;

    function setResult(bool r) external {
        result = r;
    }

    function verifyProof(uint[2] calldata, uint[2][2] calldata, uint[2] calldata, uint[3] calldata)
        external
        view
        returns (bool)
    {
        return result;
    }
}

contract ZKIdentityRegistryTest is Test {
    ZKIdentityRegistry reg;
    MockVerifier verifier;

    address oracle1 = address(0xA11CE);
    address oracle2 = address(0xB0B);
    address oracle3 = address(0xC0C);
    address user = address(0xCAFE);
    address newOwner = address(0x5AFE);

    bytes32 constant GENESIS = keccak256("demos-beta-genesis");
    bytes32 constant GENESIS_2 = keccak256("demos-mainnet-genesis");
    bytes32 constant ROOT = bytes32(uint256(0x1234abcd));
    uint256 constant BLK = 100;
    uint256 constant LEAVES = 5;
    uint256 constant CONTEXT = 777;

    // dummy proof points; MockVerifier ignores them
    uint[2] a = [uint256(1), 2];
    uint[2][2] b = [[uint256(3), 4], [uint256(5), 6]];
    uint[2] c = [uint256(7), 8];

    function setUp() public {
        verifier = new MockVerifier();
        reg = new ZKIdentityRegistry(oracle1, address(verifier), GENESIS);
    }

    function _vote(address oracle, bytes32 root, uint256 blk) internal {
        vm.prank(oracle);
        reg.submitVote(GENESIS, root, blk, LEAVES);
    }

    function _finalise(bytes32 root, uint256 blk) internal {
        _vote(oracle1, root, blk);
    }

    /// Public signals in the circuit's order: [nullifier, context, merkleRoot].
    function _pub(uint256 nullifier, uint256 context, bytes32 root) internal pure returns (uint[3] memory) {
        return [nullifier, context, uint256(root)];
    }

    // ── construction ───────────────────────────────────────────────────────────

    function test_ConstructorRejectsZeroVerifier() public {
        vm.expectRevert(ZKIdentityRegistry.ZeroAddress.selector);
        new ZKIdentityRegistry(oracle1, address(0), GENESIS);
    }

    function test_ConstructorRejectsZeroOracle() public {
        vm.expectRevert(ZKIdentityRegistry.ZeroAddress.selector);
        new ZKIdentityRegistry(address(0), address(verifier), GENESIS);
    }

    function test_ConstructorRejectsZeroGenesis() public {
        vm.expectRevert(ZKIdentityRegistry.ZeroValue.selector);
        new ZKIdentityRegistry(oracle1, address(verifier), bytes32(0));
    }

    function test_ConstructorOpensFirstEpoch() public view {
        (uint256 id, bytes32 genesis) = reg.currentEpoch();
        assertEq(id, 1);
        assertEq(genesis, GENESIS);
        assertEq(reg.genesisHashOfEpoch(1), GENESIS);
    }

    // ── committee layer ────────────────────────────────────────────────────────

    function test_SubmitVoteFinalisesAtThresholdOne() public {
        _finalise(ROOT, BLK);
        (bytes32 r, uint256 blk, uint256 leaves,, uint256 epoch) = reg.getLatestRoot();
        assertEq(r, ROOT);
        assertEq(blk, BLK);
        assertEq(leaves, LEAVES);
        assertEq(epoch, 1);
        assertTrue(reg.isFinalisedRoot(ROOT));
        assertEq(reg.rootByBlock(BLK).rootHash, ROOT);
    }

    function test_ThresholdTwoRequiresTwoOracles() public {
        reg.addOracle(oracle2);
        reg.setThreshold(2);

        _vote(oracle1, ROOT, BLK);
        assertFalse(reg.isFinalisedRoot(ROOT), "not finalised on one vote");
        assertTrue(reg.hasVoted(oracle1, ROOT, BLK, LEAVES));
        assertEq(reg.getVoteCount(ROOT, BLK, LEAVES), 1);

        _vote(oracle2, ROOT, BLK);
        assertTrue(reg.isFinalisedRoot(ROOT), "finalised on second vote");
    }

    function test_DoubleVoteRejected() public {
        reg.addOracle(oracle2);
        reg.setThreshold(2);
        _vote(oracle1, ROOT, BLK);
        vm.prank(oracle1);
        vm.expectRevert(ZKIdentityRegistry.AlreadyVoted.selector);
        reg.submitVote(GENESIS, ROOT, BLK, LEAVES);
    }

    function test_NonOracleCannotVote() public {
        vm.prank(user);
        vm.expectRevert(ZKIdentityRegistry.NotOracle.selector);
        reg.submitVote(GENESIS, ROOT, BLK, LEAVES);
    }

    function test_ZeroRootRejected() public {
        vm.prank(oracle1);
        vm.expectRevert(ZKIdentityRegistry.ZeroValue.selector);
        reg.submitVote(GENESIS, bytes32(0), BLK, LEAVES);
    }

    function test_StaleRootRejected() public {
        _finalise(ROOT, BLK);
        vm.prank(oracle1);
        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.StaleRoot.selector, BLK, BLK));
        reg.submitVote(GENESIS, ROOT, BLK, LEAVES);
    }

    function test_LargeBlockGapAccepted() public {
        _finalise(ROOT, BLK);
        bytes32 next = bytes32(uint256(0xbeef));
        _finalise(next, BLK + 5_000_000);
        assertTrue(reg.isFinalisedRoot(next));
    }

    function test_PauseHaltsSubmit() public {
        reg.pause();
        vm.prank(oracle1);
        vm.expectRevert(ZKIdentityRegistry.IsPaused.selector);
        reg.submitVote(GENESIS, ROOT, BLK, LEAVES);
    }

    function test_AdminSetLatestRootRecoversAndFinalises() public {
        _finalise(ROOT, BLK);
        bytes32 fixed_ = bytes32(uint256(0xfeed));
        reg.adminSetLatestRoot(fixed_, 42, 2); // can lower the block number
        (, uint256 blk,,,) = reg.getLatestRoot();
        assertEq(blk, 42);
        assertTrue(reg.isFinalisedRoot(fixed_));
    }

    function test_RevokeRootStopsInclusion() public {
        _finalise(ROOT, BLK);
        reg.revokeRoot(ROOT);
        assertFalse(reg.isFinalisedRoot(ROOT));
        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.RootNotFinalised.selector, ROOT));
        reg.verifyIdentity(a, b, c, _pub(1, CONTEXT, ROOT));
    }

    function test_RevokingTheLatestRootClearsIt() public {
        _finalise(ROOT, 9_999_999); // a bad height came with the bad root
        reg.revokeRoot(ROOT);
        (bytes32 r, uint256 blk,,,) = reg.getLatestRoot();
        assertEq(r, bytes32(0));
        assertEq(blk, 0);

        bytes32 honest = bytes32(uint256(0x600d));
        _finalise(honest, BLK); // not refused as stale against the bad height
        assertTrue(reg.isFinalisedRoot(honest));
    }

    function test_RevokedRootCannotComeBack() public {
        _finalise(ROOT, BLK);
        reg.revokeRoot(ROOT);

        vm.prank(oracle1);
        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.RootIsRevoked.selector, ROOT));
        reg.submitVote(GENESIS, ROOT, BLK + 1, LEAVES);

        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.RootIsRevoked.selector, ROOT));
        reg.adminSetLatestRoot(ROOT, BLK + 1, LEAVES);

        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.RootIsRevoked.selector, ROOT));
        reg.revokeRoot(ROOT);

        reg.startEpoch(GENESIS_2);
        vm.prank(oracle1);
        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.RootIsRevoked.selector, ROOT));
        reg.submitVote(GENESIS_2, ROOT, 1, LEAVES);
    }

    function test_RevokingAnOlderRootKeepsTheLatest() public {
        _finalise(ROOT, BLK);
        bytes32 next = bytes32(uint256(0xbeef));
        _finalise(next, BLK + 1);
        reg.revokeRoot(ROOT);
        (bytes32 r,,,,) = reg.getLatestRoot();
        assertEq(r, next);
        assertTrue(reg.isFinalisedRoot(next));
    }

    // ── chain epochs ───────────────────────────────────────────────────────────

    function test_VoteForOtherGenesisReverts() public {
        vm.prank(oracle1);
        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.WrongEpoch.selector, GENESIS_2, GENESIS));
        reg.submitVote(GENESIS_2, ROOT, BLK, LEAVES);
    }

    function test_StartEpochOnlyOwner() public {
        vm.prank(user);
        vm.expectRevert(ZKIdentityRegistry.NotOwner.selector);
        reg.startEpoch(GENESIS_2);
    }

    function test_StartEpochRejectsCurrentAndZeroGenesis() public {
        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.SameEpoch.selector, GENESIS));
        reg.startEpoch(GENESIS);
        vm.expectRevert(ZKIdentityRegistry.ZeroValue.selector);
        reg.startEpoch(bytes32(0));
    }

    function test_EpochResetAcceptsBlockNumbersFromOneAgain() public {
        _finalise(ROOT, 500_000);
        reg.startEpoch(GENESIS_2);

        (bytes32 r, uint256 blk,,,) = reg.getLatestRoot();
        assertEq(r, bytes32(0), "latest root cleared");
        assertEq(blk, 0, "cursor reset");

        // A vote still carrying the old genesis is refused.
        vm.prank(oracle1);
        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.WrongEpoch.selector, GENESIS, GENESIS_2));
        reg.submitVote(GENESIS, bytes32(uint256(0x77)), 1, 1);

        bytes32 fresh = bytes32(uint256(0x77));
        vm.prank(oracle1);
        reg.submitVote(GENESIS_2, fresh, 1, 1);
        (r, blk,,,) = reg.getLatestRoot();
        assertEq(r, fresh);
        assertEq(blk, 1);
        assertTrue(reg.isFinalisedRoot(fresh));
    }

    function test_OldEpochRootRejectedByVerifyIdentity() public {
        _finalise(ROOT, BLK);
        reg.verifyIdentity(a, b, c, _pub(1, CONTEXT, ROOT)); // accepted in its own epoch

        reg.startEpoch(GENESIS_2);
        assertFalse(reg.isFinalisedRoot(ROOT));
        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.RootNotFinalised.selector, ROOT));
        reg.verifyIdentity(a, b, c, _pub(2, CONTEXT, ROOT));
        assertFalse(reg.checkIdentity(a, b, c, _pub(2, CONTEXT, ROOT)));
    }

    function test_ReturningToEarlierGenesisDoesNotReviveOldRoots() public {
        _finalise(ROOT, BLK);
        reg.startEpoch(GENESIS_2);
        reg.startEpoch(GENESIS);
        assertFalse(reg.isFinalisedRoot(ROOT), "a new epoch starts empty even for a known genesis");
    }

    function test_PendingVotesDoNotCarryAcrossEpochs() public {
        reg.addOracle(oracle2);
        reg.setThreshold(2);
        _vote(oracle1, ROOT, BLK);

        reg.startEpoch(GENESIS_2);
        vm.prank(oracle2);
        reg.submitVote(GENESIS_2, ROOT, BLK, LEAVES);
        assertFalse(reg.isFinalisedRoot(ROOT), "oracle1's old-epoch vote must not count");
    }

    // ── oracle set & ownership ─────────────────────────────────────────────────

    function test_RemovedOraclePendingVoteStopsCounting() public {
        reg.addOracle(oracle2);
        reg.addOracle(oracle3);
        reg.setThreshold(2);
        _vote(oracle2, ROOT, BLK);

        reg.removeOracle(oracle2);
        _vote(oracle1, ROOT, BLK);
        assertFalse(reg.isFinalisedRoot(ROOT), "removed oracle's vote must not count");
        _vote(oracle3, ROOT, BLK);
        assertTrue(reg.isFinalisedRoot(ROOT));
    }

    function test_RemoveOracleBelowThresholdReverts() public {
        reg.addOracle(oracle2);
        reg.setThreshold(2);
        vm.expectRevert(ZKIdentityRegistry.InvalidThreshold.selector);
        reg.removeOracle(oracle2);

        vm.expectEmit(true, true, true, true);
        emit ZKIdentityRegistry.ThresholdChanged(2, 1);
        reg.setThreshold(1);
        vm.expectEmit(true, true, true, true);
        emit ZKIdentityRegistry.OracleRemoved(oracle2, 1);
        reg.removeOracle(oracle2);
        assertEq(reg.oracleCount(), 1);
    }

    function test_AddOracleRejectsZeroAndEmits() public {
        vm.expectRevert(ZKIdentityRegistry.ZeroAddress.selector);
        reg.addOracle(address(0));
        vm.expectEmit(true, true, true, true);
        emit ZKIdentityRegistry.OracleAdded(oracle2);
        reg.addOracle(oracle2);
    }

    function test_TwoStepOwnershipTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit ZKIdentityRegistry.OwnershipTransferStarted(address(this), newOwner);
        reg.transferOwnership(newOwner);
        assertEq(reg.owner(), address(this), "owner unchanged until accepted");
        assertEq(reg.pendingOwner(), newOwner);

        vm.prank(user);
        vm.expectRevert(ZKIdentityRegistry.NotPendingOwner.selector);
        reg.acceptOwnership();

        vm.expectEmit(true, true, true, true);
        emit ZKIdentityRegistry.OwnershipTransferred(address(this), newOwner);
        vm.prank(newOwner);
        reg.acceptOwnership();
        assertEq(reg.owner(), newOwner);
        assertEq(reg.pendingOwner(), address(0));

        vm.expectRevert(ZKIdentityRegistry.NotOwner.selector);
        reg.setThreshold(1);
    }

    function test_TransferOwnershipRejectsZero() public {
        vm.expectRevert(ZKIdentityRegistry.ZeroAddress.selector);
        reg.transferOwnership(address(0));
    }

    // ── trustless inclusion layer ──────────────────────────────────────────────

    function test_VerifyIdentityHappyPath() public {
        _finalise(ROOT, BLK);
        uint256 nullifier = 4919;

        vm.expectEmit(true, true, true, true);
        emit ZKIdentityRegistry.IdentityVerified(nullifier, ROOT, CONTEXT, user);
        vm.prank(user);
        bool ok = reg.verifyIdentity(a, b, c, _pub(nullifier, CONTEXT, ROOT));

        assertTrue(ok);
        assertTrue(reg.nullifierUsed(user, nullifier));
        assertFalse(reg.nullifierUsed(address(this), nullifier), "spent only for the caller");
    }

    /// Anyone can submit a user's proof. Submitting it first must not burn the
    /// nullifier for the consumer the user meant it for.
    function test_FrontRunningThirdPartyDoesNotBlockConsumer() public {
        _finalise(ROOT, BLK);
        address consumer = address(0xC0FFEE);
        address attacker = address(0xBAD);
        uint[3] memory pub = _pub(4242, CONTEXT, ROOT);

        vm.prank(attacker);
        reg.verifyIdentity(a, b, c, pub);

        vm.prank(consumer);
        assertTrue(reg.checkIdentity(a, b, c, pub));
        vm.prank(consumer);
        assertTrue(reg.verifyIdentity(a, b, c, pub));
        assertTrue(reg.nullifierUsed(consumer, 4242));
    }

    /// The prover picks the context freely. A proof whose context equals a
    /// finalised root while its real root (signal 2) is a private tree must be
    /// refused: reading the root from the wrong position would accept it.
    function test_ContextEqualToFinalisedRootIsNotAccepted() public {
        _finalise(ROOT, BLK);
        bytes32 attackerTree = bytes32(uint256(0xbad));
        uint[3] memory pub = _pub(1, uint256(ROOT), attackerTree);

        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.RootNotFinalised.selector, attackerTree));
        reg.verifyIdentity(a, b, c, pub);
        assertFalse(reg.checkIdentity(a, b, c, pub));
    }

    function test_VerifyIdentityRevertsIfRootNotFinalised() public {
        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.RootNotFinalised.selector, ROOT));
        reg.verifyIdentity(a, b, c, _pub(1, 0, ROOT));
    }

    function test_VerifyIdentityRevertsOnReusedNullifier() public {
        _finalise(ROOT, BLK);
        uint[3] memory pub = _pub(0xABC, 1, ROOT);
        reg.verifyIdentity(a, b, c, pub);
        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.NullifierAlreadyUsed.selector, 0xABC));
        reg.verifyIdentity(a, b, c, pub);
    }

    function test_VerifyIdentityRevertsOnInvalidProof() public {
        _finalise(ROOT, BLK);
        verifier.setResult(false);
        vm.expectRevert(ZKIdentityRegistry.InvalidProof.selector);
        reg.verifyIdentity(a, b, c, _pub(9, 2, ROOT));
    }

    function test_CheckIdentityIsNonMutating() public {
        _finalise(ROOT, BLK);
        assertTrue(reg.checkIdentity(a, b, c, _pub(5, 3, ROOT)));
        assertFalse(reg.nullifierUsed(address(this), 5), "view must not burn the nullifier");

        // unfinalised root -> false, not revert
        assertFalse(reg.checkIdentity(a, b, c, _pub(5, 3, bytes32(uint256(0x999)))));
    }

    function test_CheckIdentityFalseOnceTheCallerSpentTheNullifier() public {
        _finalise(ROOT, BLK);
        uint[3] memory pub = _pub(6, 3, ROOT);
        reg.verifyIdentity(a, b, c, pub);
        assertFalse(reg.checkIdentity(a, b, c, pub), "spent for this caller");
        vm.prank(user);
        assertTrue(reg.checkIdentity(a, b, c, pub), "still unspent for another caller");
    }
}
