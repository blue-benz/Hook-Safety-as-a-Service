// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookSafetyExecutor} from "../../src/executor/HookSafetyExecutor.sol";
import {MockCallbackProxy} from "../mocks/MockCallbackProxy.sol";
import {MockHookTarget} from "../mocks/MockHookTarget.sol";

contract CallbackAuthSecurityTest is Test {
    HookSafetyExecutor internal executor;
    MockCallbackProxy internal callbackProxy;

    bytes32 internal constant POOL_ID = keccak256("callback-auth");

    function setUp() public {
        callbackProxy = new MockCallbackProxy();
        executor = new HookSafetyExecutor(address(callbackProxy), address(new MockHookTarget()), address(this));
    }

    function testRejectsWrongRvmIdEvenFromCallbackProxy() public {
        bytes memory payload = abi.encodeWithSelector(
            executor.executeMitigation.selector,
            address(0xBEEF),
            POOL_ID,
            uint8(1),
            uint16(70),
            uint40(block.timestamp + 12),
            uint40(0),
            uint64(1),
            bytes32(uint256(1))
        );

        vm.expectRevert();
        callbackProxy.relay(address(executor), payload);
    }

    function testAcceptsAuthorizedProxyAndExpectedRvmId() public {
        bytes memory payload = abi.encodeWithSelector(
            executor.executeMitigation.selector,
            address(this),
            POOL_ID,
            uint8(1),
            uint16(70),
            uint40(block.timestamp + 12),
            uint40(0),
            uint64(1),
            bytes32(uint256(1))
        );

        callbackProxy.relay(address(executor), payload);
        assertEq(executor.lastNonceByPool(POOL_ID), 1);
    }
}
