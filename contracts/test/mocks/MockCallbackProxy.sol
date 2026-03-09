// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockCallbackProxy {
    error RelayFailed(bytes returndata);

    function relay(address target, bytes calldata payload) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(payload);
        if (!ok) revert RelayFailed(ret);
        return ret;
    }
}
