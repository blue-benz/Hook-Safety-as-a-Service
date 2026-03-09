// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractPayer} from "../../src/reactive/base/AbstractPayer.sol";
import {IPayable} from "../../src/reactive/base/IPayable.sol";

contract AbstractPayerHarness is AbstractPayer {
    constructor(address vendor_, address initialSender) {
        vendor = IPayable(payable(vendor_));
        addAuthorizedSender(initialSender);
    }

    function addSender(address sender) external {
        addAuthorizedSender(sender);
    }

    function removeSender(address sender) external {
        removeAuthorizedSender(sender);
    }

    function directPay(address payable recipient, uint256 amount) external {
        _pay(recipient, amount);
    }

    function isSender(address sender) external view returns (bool) {
        return senders[sender];
    }
}
