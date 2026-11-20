// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Groth16Verifier} from "../contracts/Verifier.sol";
import {ZKIdentityRegistry} from "../contracts/ZKIdentityRegistry.sol";

/// Pins contracts/Verifier.sol to the ceremony-final verification key in
/// keys/verification_key_merkle.json (the node's key), and runs a real proof
/// made with the ceremony's final zkey through the verifier and the registry.
contract VerifierTest is Test {
    string constant VKEY = "keys/verification_key_merkle.json";
    string constant VERIFIER = "contracts/Verifier.sol";
    string constant PROOF = "test/fixtures/identity_proof.json";

    bytes32 constant GENESIS = keccak256("demos-beta-genesis");

    string vkey;
    string source;

    function setUp() public {
        vkey = vm.readFile(VKEY);
        source = vm.readFile(VERIFIER);
    }

    function _assertConstant(string memory name, string memory jsonPath) internal view {
        uint256 value = vm.parseJsonUint(vkey, jsonPath);
        string memory needle = string.concat("uint256 constant ", name, " = ", vm.toString(value), ";");
        assertTrue(vm.contains(source, needle), string.concat("Verifier.sol does not pin ", needle));
    }

    /// The snarkJS template swaps each G2 coordinate pair: x1 = [0][1], x2 = [0][0].
    /// `pad` is the template's column alignment after the name.
    function _assertG2(string memory prefix, string memory pad, string memory key) internal view {
        string memory base = string.concat(".", key);
        _assertConstant(string.concat(prefix, "x1", pad), string.concat(base, "[0][1]"));
        _assertConstant(string.concat(prefix, "x2", pad), string.concat(base, "[0][0]"));
        _assertConstant(string.concat(prefix, "y1", pad), string.concat(base, "[1][1]"));
        _assertConstant(string.concat(prefix, "y2", pad), string.concat(base, "[1][0]"));
    }

    function test_EveryVerifierConstantMatchesTheCeremonyKey() public view {
        assertEq(vm.parseJsonString(vkey, ".protocol"), "groth16");
        assertEq(vm.parseJsonString(vkey, ".curve"), "bn128");
        assertEq(vm.parseJsonUint(vkey, ".nPublic"), 3);

        _assertConstant("alphax ", ".vk_alpha_1[0]");
        _assertConstant("alphay ", ".vk_alpha_1[1]");
        _assertG2("beta", " ", "vk_beta_2");
        _assertG2("gamma", "", "vk_gamma_2");
        _assertG2("delta", "", "vk_delta_2");

        for (uint256 i = 0; i < 4; i++) {
            string memory idx = vm.toString(i);
            _assertConstant(string.concat("IC", idx, "x"), string.concat(".IC[", idx, "][0]"));
            _assertConstant(string.concat("IC", idx, "y"), string.concat(".IC[", idx, "][1]"));
        }
        assertFalse(vm.contains(source, "IC4x"), "verifier has more public inputs than the key");
    }

    struct Proof {
        uint[2] a;
        uint[2][2] b;
        uint[2] c;
        uint[3] pub;
    }

    function _one(address o) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = o;
    }

    function _proof() internal view returns (Proof memory p) {
        string memory json = vm.readFile(PROOF);
        uint256[] memory a = vm.parseJsonUintArray(json, ".a");
        uint256[] memory b0 = vm.parseJsonUintArray(json, ".b[0]");
        uint256[] memory b1 = vm.parseJsonUintArray(json, ".b[1]");
        uint256[] memory c = vm.parseJsonUintArray(json, ".c");
        uint256[] memory pub = vm.parseJsonUintArray(json, ".pubSignals");
        p.a = [a[0], a[1]];
        p.b = [[b0[0], b0[1]], [b1[0], b1[1]]];
        p.c = [c[0], c[1]];
        p.pub = [pub[0], pub[1], pub[2]];
    }

    function test_RealCeremonyProofVerifies() public {
        Groth16Verifier verifier = new Groth16Verifier();
        Proof memory p = _proof();
        assertTrue(verifier.verifyProof(p.a, p.b, p.c, p.pub));

        p.pub[1] += 1; // any change to a public signal breaks the proof
        assertFalse(verifier.verifyProof(p.a, p.b, p.c, p.pub));
    }

    function test_RealProofThroughRegistryUsesSignalTwoAsRoot() public {
        Groth16Verifier verifier = new Groth16Verifier();
        ZKIdentityRegistry reg = new ZKIdentityRegistry(_one(address(this)), 1, address(verifier), GENESIS);
        Proof memory p = _proof();
        string memory json = vm.readFile(PROOF);
        bytes32 root = bytes32(vm.parseJsonUint(json, ".root"));
        assertEq(uint256(root), p.pub[2], "fixture root is public signal 2");
        assertEq(vm.parseJsonUint(json, ".context"), p.pub[1], "fixture context is public signal 1");

        assertFalse(reg.checkIdentity(p.a, p.b, p.c, p.pub), "root not finalised yet");

        reg.submitVote(GENESIS, root, 10, 1);
        assertTrue(reg.verifyIdentity(p.a, p.b, p.c, p.pub));
        assertTrue(reg.nullifierUsed(address(this), p.pub[0]));
    }
}
