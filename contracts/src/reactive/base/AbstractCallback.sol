// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPayable} from "./IPayable.sol";
import {AbstractPayer} from "./AbstractPayer.sol";

abstract contract AbstractCallback is AbstractPayer {
    address internal rvm_id;

    error AuthorizedRvmOnly(address expected, address actual);

    constructor(address callbackSender) {
        rvm_id = msg.sender;
        vendor = IPayable(payable(callbackSender));
        addAuthorizedSender(callbackSender);
    }

    modifier rvmIdOnly(address candidateRvm) {
        if (rvm_id != address(0) && rvm_id != candidateRvm) {
            revert AuthorizedRvmOnly(rvm_id, candidateRvm);
        }
        _;
    }
}
