// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "lib/community-contracts/contracts/utils/cryptography/MultiSignerERC7913Weighted.sol";

contract WeightedMultisigAccount is MultiSignerERC7913Weighted {
    address public owner;

    event ActionProposed(bytes32 indexed actionHash);
    event ActionExecuted(bytes32 indexed actionHash);

    error ActionAlreadyProposed(bytes32 actionHash);
    error NotSigner();
    error ActionNotProposed(bytes32 actionHash);
    error ActionAlreadyExecuted(bytes32 actionHash);
    error AlreadyVoted(bytes32 actionHash);
    error ActionFailed(bytes32 actionHash);

    modifier onlySigner() {
        if (!isSigner(abi.encodePacked(msg.sender))) {
            revert NotSigner();
        }
        _;
    }

    struct Action {
        address target;
        uint256 value;
        bytes callData;

        bool executed;

        uint256 votedCount;
        mapping(uint256 => address) voted;
    }

    // maps action keccak256 hash to action data
    mapping(bytes32 => Action) public actions;

    constructor(uint256 newThreshold) {
        owner = msg.sender;
        _setThreshold(newThreshold);
    }

    function addSigner(address signer, uint256 weight) external {
        bytes[] memory signers = new bytes[](1);
        signers[0] = abi.encodePacked(signer);
        _addSigners(signers);
        
        uint256[] memory weights = new uint256[](1);
        weights[0] = weight;
        _setSignerWeights(signers, weights);
    }

    function changeSignerWeight(address signer, uint256 weight) external {
        bytes[] memory signers = new bytes[](1);
        signers[0] = abi.encodePacked(signer);

        uint256[] memory weights = new uint256[](1);
        weights[0] = weight;

        _setSignerWeights(signers, weights);
    }

    function _validateReachableThreshold() internal view override {
        // do nothing
    }

    function setThreshold(uint256 newThreshold) external {
        _setThreshold(newThreshold);
    }
        
    function proposeAction(address target, uint256 value, bytes memory callData) external {
        bytes32 actionHash = keccak256(abi.encodePacked(target, value, callData));

        if (actions[actionHash].target != address(0)) {
            revert ActionAlreadyProposed(actionHash);
        }

        Action storage action = actions[actionHash];
        action.target = target;
        action.value = value;
        action.callData = callData;
        action.executed = false;

        emit ActionProposed(actionHash);
    }

    function voteOnAction(bytes32 actionHash) external onlySigner {
        Action storage action = actions[actionHash];

        if (action.target == address(0)) {
            revert ActionNotProposed(actionHash);
        }

        if (action.executed) {
            revert ActionAlreadyExecuted(actionHash);
        }

        // check if signer has already voted
        for (uint256 i = 0; i < action.votedCount; i++) {
            if (action.voted[i] == msg.sender) {
                revert AlreadyVoted(actionHash);
            }
        }

        action.voted[action.votedCount] = msg.sender;
        action.votedCount++;

        bytes[] memory encodedVoters = new bytes[](action.votedCount);
        for (uint256 i = 0; i < action.votedCount; i++) {
            encodedVoters[i] = abi.encodePacked(action.voted[i]);
        }

        if (_validateThreshold(encodedVoters)) {
            action.executed = true;

            // execute action
            (bool success, ) = action.target.call{value: action.value}(action.callData);
            if (!success) {
                revert ActionFailed(actionHash);
            }

            emit ActionExecuted(actionHash);
        }
    }
}
