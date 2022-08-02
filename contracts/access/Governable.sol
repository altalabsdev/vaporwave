// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// Function can only be called by the governor address
error GovRestricted();

/// @title Vaporwave Governable
/// @notice Provides governor access control functions
/// @dev Contract not intended to be deployed as a standalone contract
contract Governable {
    address public gov;

    modifier onlyGov() {
        if (msg.sender != gov) {
            revert GovRestricted();
        }
        _;
    }

    constructor() {
        gov = msg.sender;
    }

    /// @notice Set the governor address to `_gov`
    /// @param _gov The new governor address
    function setGov(address _gov) external onlyGov {
        gov = _gov;
    }
}
