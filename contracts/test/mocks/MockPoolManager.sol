// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookSafetyFirewallHook} from "../../src/hooks/HookSafetyFirewallHook.sol";

contract MockPoolManager {
    mapping(bytes32 => bytes32) internal storageSlots;

    function setSlot(bytes32 slot, bytes32 value) external {
        storageSlots[slot] = value;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return storageSlots[slot];
    }

    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
        uint256 start = uint256(startSlot);
        for (uint256 i = 0; i < nSlots; ++i) {
            values[i] = storageSlots[bytes32(start + i)];
        }
    }

    function callBeforeSwap(HookSafetyFirewallHook hook, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return hook.beforeSwap(msg.sender, key, params, hookData);
    }

    function callAfterSwap(
        HookSafetyFirewallHook hook,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        return hook.afterSwap(msg.sender, key, params, delta, hookData);
    }
}
