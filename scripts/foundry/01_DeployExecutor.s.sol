// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {HookSafetyExecutor} from "../../contracts/src/executor/HookSafetyExecutor.sol";

contract DeployExecutorScript is Script {
    function run() external returns (HookSafetyExecutor executor) {
        address callbackProxy = vm.envAddress("CALLBACK_PROXY");
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        address owner = vm.envOr("OWNER", msg.sender);

        vm.startBroadcast();
        executor = new HookSafetyExecutor(callbackProxy, hookAddress, owner);
        vm.stopBroadcast();

        console2.log("Deployed HookSafetyExecutor:", address(executor));
    }
}
