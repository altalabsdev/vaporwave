//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Admin interface
interface IAdmin {
    function setAdmin(address _admin) external;
}
