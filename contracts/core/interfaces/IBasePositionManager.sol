// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// Interface for BasePositionManager
interface IBasePositionManager {
    function maxGlobalLongSizes(address _token) external view returns (uint256);

    function maxGlobalShortSizes(address _token)
        external
        view
        returns (uint256);
}
