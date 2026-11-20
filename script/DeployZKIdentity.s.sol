// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Groth16Verifier} from "../contracts/Verifier.sol";
import {ZKIdentityRegistry} from "../contracts/ZKIdentityRegistry.sol";

/// Deploys the verifier and the registry, then hands ownership to OWNER (a
/// Safe behind a timelock in production) as a pending transfer it must accept.
contract DeployZKIdentity is Script {
    function run() external {
        address[] memory oracles = vm.envAddress("ORACLES", ",");
        uint256 threshold = vm.envUint("THRESHOLD");
        bytes32 genesisHash = vm.envBytes32("DEMOS_GENESIS_HASH");
        address finalOwner = vm.envOr("OWNER", address(0));

        vm.startBroadcast();
        Groth16Verifier verifier = new Groth16Verifier();
        ZKIdentityRegistry registry = new ZKIdentityRegistry(oracles, threshold, address(verifier), genesisHash);
        if (finalOwner != address(0)) registry.transferOwnership(finalOwner);
        vm.stopBroadcast();

        console.log("Groth16Verifier   :", address(verifier));
        console.log("ZKIdentityRegistry:", address(registry));
        for (uint256 i = 0; i < oracles.length; i++) {
            console.log("oracle            :", oracles[i]);
        }
        console.log("threshold         :", threshold);
        console.log("epoch genesis     :", vm.toString(genesisHash));
        if (finalOwner != address(0)) console.log("pending owner     :", finalOwner);
    }
}
