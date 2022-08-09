// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IUSDV.sol";
import "./YieldToken.sol";

/// Function can only be called by a vault
error VaultRestricted();

/// @title Vaporwave USDV token contract
contract USDV is YieldToken, IUSDV {
    mapping(address => bool) public vaults;

    modifier onlyVault() {
        if (!vaults[msg.sender]) {
            revert VaultRestricted();
        }
        _;
    }

    constructor(address _vault) YieldToken("USD Vaporwave", "USDV", 0) {
        vaults[_vault] = true;
    }

    /// @notice Add a vault to the list of vaults
    /// @param _vault Address of the vault to add
    function addVault(address _vault) external override onlyOwner {
        vaults[_vault] = true;
    }

    /// @notice Remove a vault from the list of vaults
    /// @param _vault Address of the vault to remove
    function removeVault(address _vault) external override onlyOwner {
        vaults[_vault] = false;
    }

    /// @notice Mint USDV
    /// @param _account Address of the account to mint to
    /// @param _amount Amount of USDV to mint
    function mint(address _account, uint256 _amount)
        external
        override
        onlyVault
    {
        _mint(_account, _amount);
    }

    /// @notice Burn USDV
    /// @param _account Address of the account to burn from
    /// @param _amount Amount of USDV to burn
    function burn(address _account, uint256 _amount)
        external
        override
        onlyVault
    {
        _burn(_account, _amount);
    }
}
