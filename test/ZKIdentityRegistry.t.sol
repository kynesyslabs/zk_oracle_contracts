// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZKIdentityRegistry, IZKVerifier} from "../contracts/ZKIdentityRegistry.sol";

/// Settable stand-in for the Groth16 verifier, so the registry's own logic is
/// tested independently of a real proof (a real proof is covered separately by
/// the generated verifier + the vk match against the SDK's proving key).
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
    address user = address(0xCAFE);

    bytes32 constant ROOT = bytes32(uint256(0x1234abcd));
    uint256 constant BLK = 100;
    uint256 constant LEAVES = 5;

    // dummy proof points — MockVerifier ignores them
    uint[2] a = [uint256(1), 2];
    uint[2][2] b = [[uint256(3), 4], [uint256(5), 6]];
    uint[2] c = [uint256(7), 8];

    function setUp() public {
        verifier = new MockVerifier();
        reg = new ZKIdentityRegistry(oracle1, address(verifier));
    }

    function _finalise(bytes32 root, uint256 blk) internal {
        vm.prank(oracle1);
        reg.submitVote(root, blk, LEAVES);
    }

    // ── committee layer ────────────────────────────────────────────────────────

    function test_ConstructorRejectsZeroVerifier() public {
        vm.expectRevert(ZKIdentityRegistry.ZeroVerifier.selector);
        new ZKIdentityRegistry(oracle1, address(0));
    }

    function test_SubmitVoteFinalisesAtThresholdOne() public {
        _finalise(ROOT, BLK);
        (bytes32 r, uint256 blk, uint256 leaves,) = reg.getLatestRoot();
        assertEq(r, ROOT);
        assertEq(blk, BLK);
        assertEq(leaves, LEAVES);
        assertTrue(reg.isFinalisedRoot(ROOT));
    }

    function test_ThresholdTwoRequiresTwoOracles() public {
        reg.addOracle(oracle2);
        reg.setThreshold(2);

        vm.prank(oracle1);
        reg.submitVote(ROOT, BLK, LEAVES);
        assertFalse(reg.isFinalisedRoot(ROOT), "not finalised on one vote");

        vm.prank(oracle2);
        reg.submitVote(ROOT, BLK, LEAVES);
        assertTrue(reg.isFinalisedRoot(ROOT), "finalised on second vote");
    }

    function test_NonOracleCannotVote() public {
        vm.prank(user);
        vm.expectRevert(ZKIdentityRegistry.NotOracle.selector);
        reg.submitVote(ROOT, BLK, LEAVES);
    }

    function test_StaleRootRejected() public {
        _finalise(ROOT, BLK);
        vm.prank(oracle1);
        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.StaleRoot.selector, BLK, BLK));
        reg.submitVote(ROOT, BLK, LEAVES);
    }

    function test_PauseHaltsSubmit() public {
        reg.pause();
        vm.prank(oracle1);
        vm.expectRevert(ZKIdentityRegistry.IsPaused.selector);
        reg.submitVote(ROOT, BLK, LEAVES);
    }

    function test_MaxBlockAdvanceGuard() public {
        _finalise(ROOT, BLK);
        reg.setMaxBlockAdvance(10);
        vm.prank(oracle1);
        vm.expectRevert(
            abi.encodeWithSelector(ZKIdentityRegistry.BlockJumpTooLarge.selector, BLK + 50, BLK, 10)
        );
        reg.submitVote(bytes32(uint256(0xdead)), BLK + 50, LEAVES);
    }

    function test_AdminSetLatestRootRecoversAndFinalises() public {
        _finalise(ROOT, BLK);
        bytes32 fixed_ = bytes32(uint256(0xfeed));
        reg.adminSetLatestRoot(fixed_, 42, 2); // can lower the block number
        (, uint256 blk,,) = reg.getLatestRoot();
        assertEq(blk, 42);
        assertTrue(reg.isFinalisedRoot(fixed_));
    }

    // ── trustless inclusion layer ──────────────────────────────────────────────

    function test_VerifyIdentityHappyPath() public {
        _finalise(ROOT, BLK);
        uint256 nullifier = 4919; // arbitrary
        uint[3] memory pub = [nullifier, uint256(ROOT), uint256(777)];

        vm.expectEmit(true, true, true, true);
        emit ZKIdentityRegistry.IdentityVerified(nullifier, ROOT, 777, user);
        vm.prank(user);
        bool ok = reg.verifyIdentity(a, b, c, pub);

        assertTrue(ok);
        assertTrue(reg.nullifierUsed(nullifier));
    }

    function test_VerifyIdentityRevertsIfRootNotFinalised() public {
        uint[3] memory pub = [uint256(1), uint256(ROOT), 0];
        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.RootNotFinalised.selector, ROOT));
        reg.verifyIdentity(a, b, c, pub);
    }

    function test_VerifyIdentityRevertsOnReusedNullifier() public {
        _finalise(ROOT, BLK);
        uint[3] memory pub = [uint256(0xABC), uint256(ROOT), 1];
        reg.verifyIdentity(a, b, c, pub);
        vm.expectRevert(abi.encodeWithSelector(ZKIdentityRegistry.NullifierAlreadyUsed.selector, 0xABC));
        reg.verifyIdentity(a, b, c, pub);
    }

    function test_VerifyIdentityRevertsOnInvalidProof() public {
        _finalise(ROOT, BLK);
        verifier.setResult(false);
        uint[3] memory pub = [uint256(9), uint256(ROOT), 2];
        vm.expectRevert(ZKIdentityRegistry.InvalidProof.selector);
        reg.verifyIdentity(a, b, c, pub);
    }

    function test_CheckIdentityIsNonMutating() public {
        _finalise(ROOT, BLK);
        uint[3] memory pub = [uint256(5), uint256(ROOT), 3];
        assertTrue(reg.checkIdentity(a, b, c, pub));
        assertFalse(reg.nullifierUsed(5), "view must not burn the nullifier");

        // unfinalised root -> false, not revert
        uint[3] memory pub2 = [uint256(5), uint256(0x999), 3];
        assertFalse(reg.checkIdentity(a, b, c, pub2));
    }
}
