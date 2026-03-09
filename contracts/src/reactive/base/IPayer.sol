// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPayer {
    function pay(uint256 amount) external;

    receive() external payable;
}
