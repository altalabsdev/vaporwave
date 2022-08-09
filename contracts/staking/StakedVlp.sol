// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../core/interfaces/IVlpManager.sol";

import "./interfaces/IRewardTracker.sol";
import "./interfaces/IRewardTracker.sol";

/// Allowance is less than the attempted transfer amount
error InsufficientAllowance();
/// Token cannot interact with the zero address
error ZeroAddress();

// TODO add NatSpec
// provide a way to transfer staked VLP tokens by unstaking from the sender
// and staking for the receiver
// tests in RewardRouterV2.js
/// @title Vaporwave Staked VLP token contract
contract StakedVlp {
    /// The name of the token is StakedVlp
    string public constant name = "StakedVlp";
    /// The token symbol is sVLP
    string public constant symbol = "sVLP";
    /// The decimals of the token is 18
    uint8 public constant decimals = 18;

    /// The VLP token address
    address public vlp;
    /// The VLP manager address
    IVlpManager public vlpManager;
    /// The staked VLP tracker address
    address public stakedVlpTracker;
    /// The fee VLP tracker address
    address public feeVlpTracker;

    /// Mapping of token owners to their spender allowances
    mapping(address => mapping(address => uint256)) public allowances;

    /// @notice Emitted when a token approval is made
    /// @param owner The owner of the tokens
    /// @param spender The address that is allowed to spend the tokens
    /// @param value The amount of tokens approved
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    constructor(
        address _vlp,
        IVlpManager _vlpManager,
        address _stakedVlpTracker,
        address _feeVlpTracker
    ) {
        vlp = _vlp;
        vlpManager = _vlpManager;
        stakedVlpTracker = _stakedVlpTracker;
        feeVlpTracker = _feeVlpTracker;
    }

    function approve(address _spender, uint256 _amount)
        external
        returns (bool)
    {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    /// @notice Transfer `_amount` tokens to `_recipient`
    function transfer(address _recipient, uint256 _amount)
        external
        returns (bool)
    {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) external returns (bool) {
        if (allowances[_sender][msg.sender] < _amount) {
            revert InsufficientAllowance();
        }
        unchecked {
            uint256 nextAllowance = allowances[_sender][msg.sender] - _amount;
            _approve(_sender, msg.sender, nextAllowance);
        }
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    function allowance(address _owner, address _spender)
        external
        view
        returns (uint256)
    {
        return allowances[_owner][_spender];
    }

    function balanceOf(address _account) external view returns (uint256) {
        return IRewardTracker(stakedVlpTracker).depositBalances(_account, vlp);
    }

    function totalSupply() external view returns (uint256) {
        return IERC20(stakedVlpTracker).totalSupply();
    }

    function _approve(
        address _owner,
        address _spender,
        uint256 _amount
    ) private {
        if (_owner == address(0) || _spender == address(0)) {
            revert ZeroAddress();
        }

        allowances[_owner][_spender] = _amount;

        emit Approval(_owner, _spender, _amount);
    }

    function _transfer(
        address _sender,
        address _recipient,
        uint256 _amount
    ) private {
        if (_sender == address(0) || _recipient == address(0)) {
            revert ZeroAddress();
        }

        require(
            vlpManager.lastAddedAt(_sender) + vlpManager.cooldownDuration() <=
                block.timestamp,
            "StakedVlp: cooldown duration not yet passed"
        );

        IRewardTracker(stakedVlpTracker).unstakeForAccount(
            _sender,
            feeVlpTracker,
            _amount,
            _sender
        );
        IRewardTracker(feeVlpTracker).unstakeForAccount(
            _sender,
            vlp,
            _amount,
            _sender
        );

        IRewardTracker(feeVlpTracker).stakeForAccount(
            _sender,
            _recipient,
            vlp,
            _amount
        );
        IRewardTracker(stakedVlpTracker).stakeForAccount(
            _recipient,
            _recipient,
            feeVlpTracker,
            _amount
        );
    }
}
