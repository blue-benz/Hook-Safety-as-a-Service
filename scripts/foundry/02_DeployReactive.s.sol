// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {HookSafetyReactive} from "../../contracts/src/reactive/HookSafetyReactive.sol";

contract DeployReactiveScript is Script {
    function run() external returns (HookSafetyReactive reactive) {
        address serviceAddress = vm.envOr("SERVICE_CONTRACT", address(0x0000000000000000000000000000000000fffFfF));
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        uint256 destinationChainId = vm.envUint("DESTINATION_CHAIN_ID");
        address executorAddress = vm.envAddress("EXECUTOR_ADDRESS");

        vm.startBroadcast();
        reactive = new HookSafetyReactive(
            serviceAddress,
            originChainId,
            hookAddress,
            destinationChainId,
            executorAddress,
            uint16(vm.envOr("MEDIUM_THRESHOLD", uint256(55))),
            uint16(vm.envOr("HIGH_THRESHOLD", uint256(80)))
        );
        vm.stopBroadcast();

        console2.log("Deployed HookSafetyReactive:", address(reactive));
    }
}
