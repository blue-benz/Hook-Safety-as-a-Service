// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {AbstractPayer} from "../../src/reactive/base/AbstractPayer.sol";
import {AbstractPayerHarness} from "../mocks/AbstractPayerHarness.sol";
import {MockSystemContract} from "../mocks/MockSystemContract.sol";

contract AbstractPayerUnitTest is Test {
    AbstractPayerHarness internal payer;
    MockSystemContract internal vendor;

    address internal constant AUTHORIZED = address(0xA11CE);
    address internal constant UNAUTHORIZED = address(0xB0B);

    function setUp() public {
        vendor = new MockSystemContract();
        payer = new AbstractPayerHarness(address(vendor), address(this));
        payer.addSender(AUTHORIZED);
    }

    function testPayTransfersToAuthorizedCaller() public {
        vm.deal(address(payer), 2 ether);
        vm.deal(AUTHORIZED, 0);

        vm.prank(AUTHORIZED);
        payer.pay(0.4 ether);

        assertEq(AUTHORIZED.balance, 0.4 ether);
    }

    function testPayZeroAmountNoop() public {
        vm.deal(address(payer), 1 ether);
        uint256 beforeBalance = AUTHORIZED.balance;

        vm.prank(AUTHORIZED);
        payer.pay(0);

        assertEq(AUTHORIZED.balance, beforeBalance);
    }

    function testPayRejectsUnauthorizedSender() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(AbstractPayer.AuthorizedSenderOnly.selector);
        payer.pay(1);
    }

    function testPayRevertsWhenFundsInsufficient() public {
        vm.prank(AUTHORIZED);
        vm.expectRevert();
        payer.pay(1);
    }

    function testCoverDebtPaysVendor() public {
        vm.deal(address(payer), 1 ether);
        vendor.setDebt(0.5 ether);

        payer.coverDebt();

        assertEq(vendor.receivedValue(), 0.5 ether);
    }

    function testCoverDebtBubblesTransferFailure() public {
        vm.deal(address(payer), 1 ether);
        vendor.setDebt(0.2 ether);
        vendor.setRejectPayments(true);

        vm.expectRevert(AbstractPayer.TransferFailed.selector);
        payer.coverDebt();
    }

    function testRemoveSenderRevokesAuthorization() public {
        payer.removeSender(AUTHORIZED);
        assertFalse(payer.isSender(AUTHORIZED));

        vm.prank(AUTHORIZED);
        vm.expectRevert(AbstractPayer.AuthorizedSenderOnly.selector);
        payer.pay(0.1 ether);
    }

    function testDirectPayRevertsForInsufficientBalance() public {
        vm.expectRevert();
        payer.directPay(payable(address(this)), 1 wei);
    }
}
