// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookSafetyExecutor} from "../../src/executor/HookSafetyExecutor.sol";
import {MockCallbackProxy} from "../mocks/MockCallbackProxy.sol";
import {MockHookTarget} from "../mocks/MockHookTarget.sol";

contract HookSafetyExecutorTest is Test {
    HookSafetyExecutor internal executor;
    MockCallbackProxy internal callbackProxy;
    MockHookTarget internal hook;

    bytes32 internal constant POOL_ID = keccak256("pool-x");

    function setUp() public {
        callbackProxy = new MockCallbackProxy();
        hook = new MockHookTarget();
        executor = new HookSafetyExecutor(address(callbackProxy), address(hook), address(this));
    }

    function testRejectsUnauthorizedSender() public {
        vm.expectRevert();
        executor.executeMitigation(address(this), POOL_ID, 1, 60, uint40(block.timestamp + 10), 0, 1, keccak256("evidence"));
    }

    function testExecutesMitigationViaCallbackProxyAndProtectsReplay() public {
        bytes memory payload = abi.encodeWithSelector(
            executor.executeMitigation.selector,
            address(this),
            POOL_ID,
            uint8(2),
            uint16(88),
            uint40(block.timestamp + 90),
            uint40(block.timestamp + 45),
            uint64(7),
            keccak256("evidence")
        );

        callbackProxy.relay(address(executor), payload);

        assertEq(uint8(hook.lastTier()), 2);
        assertEq(hook.lastNonce(), 7);
        assertEq(executor.lastNonceByPool(POOL_ID), 7);

        vm.expectRevert();
        callbackProxy.relay(address(executor), payload);
    }
}
