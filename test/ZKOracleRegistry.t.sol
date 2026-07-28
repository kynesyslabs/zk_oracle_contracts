// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZKOracleRegistry} from "../contracts/ZKOracleRegistry.sol";

contract ZKOracleRegistryTest is Test {
    ZKOracleRegistry registry;

    address owner = address(this);
    address oracle = address(0xA11CE);
    address stranger = address(0xBEEF);

    bytes32 constant ROOT_A = keccak256("root-a");
    bytes32 constant ROOT_B = keccak256("root-b");

    function setUp() public {
        registry = new ZKOracleRegistry(oracle);
    }

    function _vote(bytes32 root, uint256 block_, uint256 leaves) internal {
        vm.prank(oracle);
        registry.submitVote(root, block_, leaves);
    }

    // ─── the bug the client reported: a bad block number wedges the registry ───

    function test_badBlockNumber_canBeRecovered_byOwner() public {
        // A garbage node read finalises an absurd block number.
        _vote(ROOT_A, 999_999_999, 1);
        (, uint256 latest,,) = registry.getLatestRoot();
        assertEq(latest, 999_999_999);

        // Every honest submission now reverts as stale — the registry is wedged.
        vm.prank(oracle);
        vm.expectRevert(
            abi.encodeWithSelector(ZKOracleRegistry.StaleRoot.selector, 101, 999_999_999)
        );
        registry.submitVote(ROOT_B, 101, 2);

        // The escape hatch the contract previously lacked: pause, correct, resume.
        registry.pause();
        registry.adminSetLatestRoot(ROOT_A, 100, 1);
        registry.unpause();

        // Honest voting works again.
        _vote(ROOT_B, 101, 2);
        (bytes32 root, uint256 blk,,) = registry.getLatestRoot();
        assertEq(root, ROOT_B);
        assertEq(blk, 101);
    }

    function test_maxBlockAdvance_rejectsImplausibleJump() public {
        _vote(ROOT_A, 100, 1);
        registry.setMaxBlockAdvance(1000);

        // A jump beyond the bound is refused up front — it never becomes latest,
        // so no owner correction is needed to undo it.
        vm.prank(oracle);
        vm.expectRevert(
            abi.encodeWithSelector(ZKOracleRegistry.BlockJumpTooLarge.selector, 999_999, 100, 1000)
        );
        registry.submitVote(ROOT_B, 999_999, 2);

        // A jump within the bound still works.
        _vote(ROOT_B, 900, 2);
        (, uint256 latest,,) = registry.getLatestRoot();
        assertEq(latest, 900);
    }

    function test_maxBlockAdvance_firstRootIsUnbounded() public {
        // No baseline to bound against on the very first root.
        registry.setMaxBlockAdvance(10);
        _vote(ROOT_A, 5_000_000, 1);
        (, uint256 latest,,) = registry.getLatestRoot();
        assertEq(latest, 5_000_000);
    }

    // ─── pause semantics ───────────────────────────────────────────────────────

    function test_pause_haltsVoting() public {
        registry.pause();
        vm.prank(oracle);
        vm.expectRevert(ZKOracleRegistry.IsPaused.selector);
        registry.submitVote(ROOT_A, 100, 1);
    }

    function test_pause_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(ZKOracleRegistry.NotOwner.selector);
        registry.pause();
    }

    function test_doublePause_reverts() public {
        registry.pause();
        vm.expectRevert(ZKOracleRegistry.IsPaused.selector);
        registry.pause();
    }

    function test_unpauseWhenNotPaused_reverts() public {
        vm.expectRevert(ZKOracleRegistry.NotPaused.selector);
        registry.unpause();
    }

    // ─── admin correction is owner-gated and audit-logged ──────────────────────

    function test_adminSetLatestRoot_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(ZKOracleRegistry.NotOwner.selector);
        registry.adminSetLatestRoot(ROOT_A, 1, 1);
    }

    function test_adminSetLatestRoot_emitsAudit() public {
        vm.expectEmit(true, false, false, true);
        emit ZKOracleRegistry.RootCorrected(ROOT_A, 42, 7, block.timestamp);
        registry.adminSetLatestRoot(ROOT_A, 42, 7);
    }

    // ─── the happy path still holds ────────────────────────────────────────────

    function test_normalVoting_finalises() public {
        _vote(ROOT_A, 100, 5);
        (bytes32 root, uint256 blk, uint256 leaves,) = registry.getLatestRoot();
        assertEq(root, ROOT_A);
        assertEq(blk, 100);
        assertEq(leaves, 5);
    }
}
