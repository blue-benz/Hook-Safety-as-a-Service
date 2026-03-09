// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Owned} from "../../src/common/Owned.sol";
import {HookSafetyExecutor} from "../../src/executor/HookSafetyExecutor.sol";
import {MockCallbackProxy} from "../mocks/MockCallbackProxy.sol";
import {MockHookTarget} from "../mocks/MockHookTarget.sol";

contract HookSafetyExecutorTest is Test {
    HookSafetyExecutor internal executor;
    MockCallbackProxy internal callbackProxy;
    MockHookTarget internal hook;

    bytes32 internal constant POOL_ID = keccak256("pool-x");
    address internal constant ALICE = address(0xA11CE);

    function setUp() public {
        callbackProxy = new MockCallbackProxy();
        hook = new MockHookTarget();
        executor = new HookSafetyExecutor(address(callbackProxy), address(hook), address(this));
    }

    function testRejectsUnauthorizedSender() public {
        vm.expectRevert();
        executor.executeMitigation(address(this), POOL_ID, 1, 60, uint40(block.timestamp + 10), 0, 1, keccak256("evidence"));
    }

    function testConstructorRejectsZeroOwner() public {
        vm.expectRevert(Owned.ZeroAddressOwner.selector);
        new HookSafetyExecutor(address(callbackProxy), address(hook), address(0));
    }

    function testOnlyOwnerCanBindRvmIdAndToggleEmergencyStop() public {
        executor.bindRvmId(ALICE);
        assertEq(executor.owner(), address(this));
        assertFalse(executor.emergencyStop());

        executor.setEmergencyStop(true);
        assertTrue(executor.emergencyStop());

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Owned.NotOwner.selector, ALICE));
        executor.bindRvmId(address(this));
    }

    function testTransferOwnershipAppliesOwnerChecks() public {
        executor.transferOwnership(ALICE);
        assertEq(executor.owner(), ALICE);

        vm.expectRevert(abi.encodeWithSelector(Owned.NotOwner.selector, address(this)));
        executor.setEmergencyStop(true);

        vm.prank(ALICE);
        executor.setEmergencyStop(true);
        assertTrue(executor.emergencyStop());

        vm.prank(ALICE);
        vm.expectRevert(Owned.ZeroAddressOwner.selector);
        executor.transferOwnership(address(0));
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

    function testEmergencyStopBlocksMitigation() public {
        executor.setEmergencyStop(true);

        bytes memory payload = abi.encodeWithSelector(
            executor.executeMitigation.selector,
            address(this),
            POOL_ID,
            uint8(1),
            uint16(70),
            uint40(block.timestamp + 10),
            uint40(0),
            uint64(1),
            keccak256("stop")
        );

        vm.expectRevert();
        callbackProxy.relay(address(executor), payload);
    }

    function testInvalidTierReverts() public {
        bytes memory payload = abi.encodeWithSelector(
            executor.executeMitigation.selector,
            address(this),
            POOL_ID,
            uint8(3),
            uint16(75),
            uint40(block.timestamp + 10),
            uint40(0),
            uint64(1),
            keccak256("invalid-tier")
        );

        vm.expectRevert();
        callbackProxy.relay(address(executor), payload);
    }

    function testBoundRvmIdMustMatch() public {
        executor.bindRvmId(ALICE);

        bytes memory badPayload = abi.encodeWithSelector(
            executor.executeMitigation.selector,
            address(this),
            POOL_ID,
            uint8(1),
            uint16(70),
            uint40(block.timestamp + 10),
            uint40(0),
            uint64(1),
            keccak256("bad-rvm")
        );
        vm.expectRevert();
        callbackProxy.relay(address(executor), badPayload);

        bytes memory okPayload = abi.encodeWithSelector(
            executor.executeMitigation.selector,
            ALICE,
            POOL_ID,
            uint8(1),
            uint16(70),
            uint40(block.timestamp + 10),
            uint40(0),
            uint64(1),
            keccak256("ok-rvm")
        );
        callbackProxy.relay(address(executor), okPayload);
        assertEq(executor.lastNonceByPool(POOL_ID), 1);
    }
}
