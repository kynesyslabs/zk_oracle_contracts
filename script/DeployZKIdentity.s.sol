// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Groth16Verifier} from "../contracts/Verifier.sol";
import {ZKIdentityRegistry} from "../contracts/ZKIdentityRegistry.sol";

/// Deploys the verifier and the registry, then hands ownership to OWNER (a
/// Safe behind a timelock in production) as a pending transfer it must accept.
contract DeployZKIdentity is Script {
    function run() external {
        address initialOracle = vm.envAddress("INITIAL_ORACLE");
        bytes32 genesisHash = vm.envBytes32("DEMOS_GENESIS_HASH");
        address finalOwner = vm.envOr("OWNER", address(0));

        vm.startBroadcast();
        Groth16Verifier verifier = new Groth16Verifier();
        ZKIdentityRegistry registry = new ZKIdentityRegistry(initialOracle, address(verifier), genesisHash);
        if (finalOwner != address(0)) registry.transferOwnership(finalOwner);
        vm.stopBroadcast();

        console.log("Groth16Verifier   :", address(verifier));
        console.log("ZKIdentityRegistry:", address(registry));
        console.log("initial oracle    :", initialOracle);
        console.log("epoch genesis     :", vm.toString(genesisHash));
        if (finalOwner != address(0)) console.log("pending owner     :", finalOwner);
    }
}
