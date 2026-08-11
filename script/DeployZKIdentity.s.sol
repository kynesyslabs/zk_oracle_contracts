// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Groth16Verifier} from "../contracts/Verifier.sol";
import {ZKIdentityRegistry} from "../contracts/ZKIdentityRegistry.sol";

contract DeployZKIdentity is Script {
    function run() external {
        address initialOracle = vm.envAddress("INITIAL_ORACLE");
        vm.startBroadcast();
        Groth16Verifier verifier = new Groth16Verifier();
        ZKIdentityRegistry registry = new ZKIdentityRegistry(initialOracle, address(verifier));
        vm.stopBroadcast();
        console.log("Groth16Verifier :", address(verifier));
        console.log("ZKIdentityRegistry:", address(registry));
        console.log("owner/oracle     :", initialOracle);
    }
}
