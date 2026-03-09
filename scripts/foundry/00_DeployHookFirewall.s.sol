// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookSafetyFirewallHook} from "../../contracts/src/hooks/HookSafetyFirewallHook.sol";

contract DeployHookFirewallScript is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (HookSafetyFirewallHook hook) {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address owner = vm.envOr("OWNER", msg.sender);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), owner);
        (address expectedAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(HookSafetyFirewallHook).creationCode, constructorArgs);

        vm.startBroadcast();
        hook = new HookSafetyFirewallHook{salt: salt}(IPoolManager(poolManager), owner);
        vm.stopBroadcast();

        require(address(hook) == expectedAddress, "Hook deployment address mismatch");

        console2.log("Deployed HookSafetyFirewallHook:", address(hook));
        console2.logBytes32(salt);
    }
}
