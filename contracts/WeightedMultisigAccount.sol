// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "lib/community-contracts/contracts/utils/cryptography/MultiSignerERC7913Weighted.sol";

contract WeightedMultisigAccount is MultiSignerERC7913Weighted {
    address public owner;

    event ActionProposed(bytes32 indexed actionHash);
    event ActionExecuted(bytes32 indexed actionHash);

    constructor(
        address[] memory signers,
        uint256[] memory weights,
        uint256 threshold
    ) {
        require(signers.length == weights.length, "Mismatch");

        bytes[] memory encodedSigners = _encodeAddressesToBytes(signers);
        _addSigners(encodedSigners);
        _setSignerWeights(encodedSigners, weights);
        _setThreshold(threshold);
        owner = msg.sender;
    }

    function _encodeAddressesToBytes(address[] memory addresses) internal pure returns (bytes[] memory) {
        bytes[] memory result = new bytes[](addresses.length);
        for (uint i = 0; i < addresses.length; i++) {
            result[i] = abi.encodePacked(addresses[i]);
        }
        return result;
    }

    function addSigner(address signer, uint256 weight) external {
        address[] memory signers = new address[](1);
        signers[0] = signer;
        bytes[] memory encodedSigners = _encodeAddressesToBytes(signers);
        _addSigners(encodedSigners);
        
        uint256[] memory weights = new uint256[](1);
        weights[0] = weight;
        _setSignerWeights(encodedSigners, weights);
    }

    function executeAction(bytes32 actionHash, address[] memory voters) external returns (bool) {
        bytes[] memory encodedVoters = _encodeAddressesToBytes(voters);
        if (_validateThreshold(encodedVoters)) {
            return true;
        }
        return false;
    }

    receive() external payable {}
}
