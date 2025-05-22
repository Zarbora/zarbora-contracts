// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MockContract {
    uint256 public value;
    
    function setValue(uint256 _value) external {
        value = _value;
    }
}

contract MockRevertingContract {
    function revertingFunction() external pure {
        revert("This function always reverts");
    }
} 