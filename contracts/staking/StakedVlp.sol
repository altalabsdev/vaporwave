// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../libraries/utils/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";

import "../core/interfaces/IVlpManager.sol";

import "./interfaces/IRewardTracker.sol";
import "./interfaces/IRewardTracker.sol";

// provide a way to transfer staked VLP tokens by unstaking from the sender
// and staking for the receiver
// tests in RewardRouterV2.js
contract StakedVlp {
    using SafeMath for uint256;

    string public constant name = "StakedVlp";
    string public constant symbol = "sVLP";
    uint8 public constant decimals = 18;

    address public vlp;
    IVlpManager public vlpManager;
    address public stakedVlpTracker;
    address public feeVlpTracker;

    mapping (address => mapping (address => uint256)) public allowances;

    event Approval(address indexed owner, address indexed spender, uint256 value);

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

    function allowance(address _owner, address _spender) external view returns (uint256) {
        return allowances[_owner][_spender];
    }

    function approve(address _spender, uint256 _amount) external returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function transfer(address _recipient, uint256 _amount) external returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function transferFrom(address _sender, address _recipient, uint256 _amount) external returns (bool) {
        uint256 nextAllowance = allowances[_sender][msg.sender].sub(_amount, "StakedVlp: transfer amount exceeds allowance");
        _approve(_sender, msg.sender, nextAllowance);
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    function balanceOf(address _account) external view returns (uint256) {
        return IRewardTracker(stakedVlpTracker).depositBalances(_account, vlp);
    }

    function totalSupply() external view returns (uint256) {
        return IERC20(stakedVlpTracker).totalSupply();
    }

    function _approve(address _owner, address _spender, uint256 _amount) private {
        require(_owner != address(0), "StakedVlp: approve from the zero address");
        require(_spender != address(0), "StakedVlp: approve to the zero address");

        allowances[_owner][_spender] = _amount;

        emit Approval(_owner, _spender, _amount);
    }

    function _transfer(address _sender, address _recipient, uint256 _amount) private {
        require(_sender != address(0), "StakedVlp: transfer from the zero address");
        require(_recipient != address(0), "StakedVlp: transfer to the zero address");

        require(
            vlpManager.lastAddedAt(_sender).add(vlpManager.cooldownDuration()) <= block.timestamp,
            "StakedVlp: cooldown duration not yet passed"
        );

        IRewardTracker(stakedVlpTracker).unstakeForAccount(_sender, feeVlpTracker, _amount, _sender);
        IRewardTracker(feeVlpTracker).unstakeForAccount(_sender, vlp, _amount, _sender);

        IRewardTracker(feeVlpTracker).stakeForAccount(_sender, _recipient, vlp, _amount);
        IRewardTracker(stakedVlpTracker).stakeForAccount(_recipient, _recipient, feeVlpTracker, _amount);
    }
}
