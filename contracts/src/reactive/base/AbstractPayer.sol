// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPayer} from "./IPayer.sol";
import {IPayable} from "./IPayable.sol";

abstract contract AbstractPayer is IPayer {
    IPayable internal vendor;
    mapping(address => bool) internal senders;

    error AuthorizedSenderOnly();
    error InsufficientFunds(uint256 balance, uint256 needed);
    error TransferFailed();

    receive() external payable virtual {}

    modifier authorizedSenderOnly() {
        if (!senders[msg.sender]) revert AuthorizedSenderOnly();
        _;
    }

    function pay(uint256 amount) external authorizedSenderOnly {
        _pay(payable(msg.sender), amount);
    }

    function coverDebt() external {
        uint256 amount = vendor.debt(address(this));
        _pay(payable(address(vendor)), amount);
    }

    function _pay(address payable recipient, uint256 amount) internal {
        uint256 balance = address(this).balance;
        if (balance < amount) revert InsufficientFunds(balance, amount);
        if (amount == 0) return;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function addAuthorizedSender(address sender) internal {
        senders[sender] = true;
    }

    function removeAuthorizedSender(address sender) internal {
        senders[sender] = false;
    }
}
