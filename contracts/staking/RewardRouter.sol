// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../libraries/utils/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/security/ReentrancyGuard.sol";
import "../libraries/utils/Address.sol";

import "./interfaces/IRewardTracker.sol";
import "../tokens/interfaces/IMintable.sol";
import "../tokens/interfaces/IWETH.sol";
import "../core/interfaces/IVlpManager.sol";
import "../access/Governable.sol";

// TODO: stack too deep error

contract RewardRouter is ReentrancyGuard, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    bool public isInitialized;

    address public weth;

    address public vwave;
    address public esVwave;
    address public bnVwave;

    address public vlp; // VWAVE Liquidity Provider token

    address public stakedVwaveTracker;
    address public bonusVwaveTracker;
    address public feeVwaveTracker;

    address public stakedVlpTracker;
    address public feeVlpTracker;

    address public vlpManager;

    event StakeVwave(address account, uint256 amount);
    event UnstakeVwave(address account, uint256 amount);

    event StakeVlp(address account, uint256 amount);
    event UnstakeVlp(address account, uint256 amount);

    receive() external payable {
        require(msg.sender == weth, "Router: invalid sender");
    }

    function initialize(
        address _weth,
        address _vwave,
        address _esVwave,
        address _bnVwave,
        address _vlp,
        address _stakedVwaveTracker,
        address _bonusVwaveTracker,
        address _feeVwaveTracker,
        address _feeVlpTracker,
        address _stakedVlpTracker,
        address _vlpManager
    ) external onlyGov {
        require(!isInitialized, "RewardRouter: already initialized");
        isInitialized = true;

        weth = _weth;

        vwave = _vwave;
        esVwave = _esVwave;
        bnVwave = _bnVwave;

        vlp = _vlp;

        stakedVwaveTracker = _stakedVwaveTracker;
        bonusVwaveTracker = _bonusVwaveTracker;
        feeVwaveTracker = _feeVwaveTracker;

        feeVlpTracker = _feeVlpTracker;
        stakedVlpTracker = _stakedVlpTracker;

        vlpManager = _vlpManager;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function batchStakeVwaveForAccount(address[] memory _accounts, uint256[] memory _amounts) external nonReentrant onlyGov {
        address _vwave = vwave;
        for (uint256 i = 0; i < _accounts.length; i++) {
            _stakeVwave(msg.sender, _accounts[i], _vwave, _amounts[i]);
        }
    }

    function stakeVwaveForAccount(address _account, uint256 _amount) external nonReentrant onlyGov {
        _stakeVwave(msg.sender, _account, vwave, _amount);
    }

    function stakeVwave(uint256 _amount) external nonReentrant {
        _stakeVwave(msg.sender, msg.sender, vwave, _amount);
    }

    function stakeEsVwave(uint256 _amount) external nonReentrant {
        _stakeVwave(msg.sender, msg.sender, esVwave, _amount);
    }

    function unstakeVwave(uint256 _amount) external nonReentrant {
        _unstakeVwave(msg.sender, vwave, _amount);
    }

    function unstakeEsVwave(uint256 _amount) external nonReentrant {
        _unstakeVwave(msg.sender, esVwave, _amount);
    }

    function mintAndStakeVlp(address _token, uint256 _amount, uint256 _minUsdg, uint256 _minVlp) external nonReentrant returns (uint256) {
        require(_amount > 0, "RewardRouter: invalid _amount");

        address account = msg.sender;
        uint256 vlpAmount = IVlpManager(vlpManager).addLiquidityForAccount(account, account, _token, _amount, _minUsdg, _minVlp);
        IRewardTracker(feeVlpTracker).stakeForAccount(account, account, vlp, vlpAmount);
        IRewardTracker(stakedVlpTracker).stakeForAccount(account, account, feeVlpTracker, vlpAmount);

        emit StakeVlp(account, vlpAmount);

        return vlpAmount;
    }

    function mintAndStakeVlpETH(uint256 _minUsdg, uint256 _minVlp) external payable nonReentrant returns (uint256) {
        require(msg.value > 0, "RewardRouter: invalid msg.value");

        IWETH(weth).deposit{value: msg.value}();
        IERC20(weth).approve(vlpManager, msg.value);

        address account = msg.sender;
        uint256 vlpAmount = IVlpManager(vlpManager).addLiquidityForAccount(address(this), account, weth, msg.value, _minUsdg, _minVlp);

        IRewardTracker(feeVlpTracker).stakeForAccount(account, account, vlp, vlpAmount);
        IRewardTracker(stakedVlpTracker).stakeForAccount(account, account, feeVlpTracker, vlpAmount);

        emit StakeVlp(account, vlpAmount);

        return vlpAmount;
    }

    function unstakeAndRedeemVlp(address _tokenOut, uint256 _vlpAmount, uint256 _minOut, address _receiver) external nonReentrant returns (uint256) {
        require(_vlpAmount > 0, "RewardRouter: invalid _vlpAmount");

        address account = msg.sender;
        IRewardTracker(stakedVlpTracker).unstakeForAccount(account, feeVlpTracker, _vlpAmount, account);
        IRewardTracker(feeVlpTracker).unstakeForAccount(account, vlp, _vlpAmount, account);
        uint256 amountOut = IVlpManager(vlpManager).removeLiquidityForAccount(account, _tokenOut, _vlpAmount, _minOut, _receiver);

        emit UnstakeVlp(account, _vlpAmount);

        return amountOut;
    }

    function unstakeAndRedeemVlpETH(uint256 _vlpAmount, uint256 _minOut, address payable _receiver) external nonReentrant returns (uint256) {
        require(_vlpAmount > 0, "RewardRouter: invalid _vlpAmount");

        address account = msg.sender;
        IRewardTracker(stakedVlpTracker).unstakeForAccount(account, feeVlpTracker, _vlpAmount, account);
        IRewardTracker(feeVlpTracker).unstakeForAccount(account, vlp, _vlpAmount, account);
        uint256 amountOut = IVlpManager(vlpManager).removeLiquidityForAccount(account, weth, _vlpAmount, _minOut, address(this));

        IWETH(weth).withdraw(amountOut);

        _receiver.sendValue(amountOut);

        emit UnstakeVlp(account, _vlpAmount);

        return amountOut;
    }

    function claim() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeVwaveTracker).claimForAccount(account, account);
        IRewardTracker(feeVlpTracker).claimForAccount(account, account);

        IRewardTracker(stakedVwaveTracker).claimForAccount(account, account);
        IRewardTracker(stakedVlpTracker).claimForAccount(account, account);
    }

    function claimEsVwave() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(stakedVwaveTracker).claimForAccount(account, account);
        IRewardTracker(stakedVlpTracker).claimForAccount(account, account);
    }

    function claimFees() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeVwaveTracker).claimForAccount(account, account);
        IRewardTracker(feeVlpTracker).claimForAccount(account, account);
    }

    function compound() external nonReentrant {
        _compound(msg.sender);
    }

    function compoundForAccount(address _account) external nonReentrant onlyGov {
        _compound(_account);
    }

    function batchCompoundForAccounts(address[] memory _accounts) external nonReentrant onlyGov {
        for (uint256 i = 0; i < _accounts.length; i++) {
            _compound(_accounts[i]);
        }
    }

    function _compound(address _account) private {
        _compoundVwave(_account);
        _compoundVlp(_account);
    }

    function _compoundVwave(address _account) private {
        uint256 esVwaveAmount = IRewardTracker(stakedVwaveTracker).claimForAccount(_account, _account);
        if (esVwaveAmount > 0) {
            _stakeVwave(_account, _account, esVwave, esVwaveAmount);
        }

        uint256 bnVwaveAmount = IRewardTracker(bonusVwaveTracker).claimForAccount(_account, _account);
        if (bnVwaveAmount > 0) {
            IRewardTracker(feeVwaveTracker).stakeForAccount(_account, _account, bnVwave, bnVwaveAmount);
        }
    }

    function _compoundVlp(address _account) private {
        uint256 esVwaveAmount = IRewardTracker(stakedVlpTracker).claimForAccount(_account, _account);
        if (esVwaveAmount > 0) {
            _stakeVwave(_account, _account, esVwave, esVwaveAmount);
        }
    }

    function _stakeVwave(address _fundingAccount, address _account, address _token, uint256 _amount) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        IRewardTracker(stakedVwaveTracker).stakeForAccount(_fundingAccount, _account, _token, _amount);
        IRewardTracker(bonusVwaveTracker).stakeForAccount(_account, _account, stakedVwaveTracker, _amount);
        IRewardTracker(feeVwaveTracker).stakeForAccount(_account, _account, bonusVwaveTracker, _amount);

        emit StakeVwave(_account, _amount);
    }

    function _unstakeVwave(address _account, address _token, uint256 _amount) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        uint256 balance = IRewardTracker(stakedVwaveTracker).stakedAmounts(_account);

        IRewardTracker(feeVwaveTracker).unstakeForAccount(_account, bonusVwaveTracker, _amount, _account);
        IRewardTracker(bonusVwaveTracker).unstakeForAccount(_account, stakedVwaveTracker, _amount, _account);
        IRewardTracker(stakedVwaveTracker).unstakeForAccount(_account, _token, _amount, _account);

        uint256 bnVwaveAmount = IRewardTracker(bonusVwaveTracker).claimForAccount(_account, _account);
        if (bnVwaveAmount > 0) {
            IRewardTracker(feeVwaveTracker).stakeForAccount(_account, _account, bnVwave, bnVwaveAmount);
        }

        uint256 stakedBnVwave = IRewardTracker(feeVwaveTracker).depositBalances(_account, bnVwave);
        if (stakedBnVwave > 0) {
            uint256 reductionAmount = stakedBnVwave.mul(_amount).div(balance);
            IRewardTracker(feeVwaveTracker).unstakeForAccount(_account, bnVwave, reductionAmount, _account);
            IMintable(bnVwave).burn(_account, reductionAmount);
        }

        emit UnstakeVwave(_account, _amount);
    }
}
