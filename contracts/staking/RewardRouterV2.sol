// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../libraries/utils/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/security/ReentrancyGuard.sol";
import "../libraries/utils/Address.sol";

import "./interfaces/IRewardTracker.sol";
import "./interfaces/IVester.sol";
import "../tokens/interfaces/IMintable.sol";
import "../tokens/interfaces/IWETH.sol";
import "../core/interfaces/IVlpManager.sol";
import "../access/Governable.sol";

// TODO: stack too deep error

contract RewardRouterV2 is ReentrancyGuard, Governable {
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

    address public vwaveVester;
    address public vlpVester;

    mapping (address => address) public pendingReceivers;

    event StakeVwave(address account, address token, uint256 amount);
    event UnstakeVwave(address account, address token, uint256 amount);

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
        address _vlpManager,
        address _vwaveVester,
        address _vlpVester
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

        vwaveVester = _vwaveVester;
        vlpVester = _vlpVester;
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
        _unstakeVwave(msg.sender, vwave, _amount, true);
    }

    function unstakeEsVwave(uint256 _amount) external nonReentrant {
        _unstakeVwave(msg.sender, esVwave, _amount, true);
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

    function handleRewards(
        bool _shouldClaimVwave,
        bool _shouldStakeVwave,
        bool _shouldClaimEsVwave,
        bool _shouldStakeEsVwave,
        bool _shouldStakeMultiplierPoints,
        bool _shouldClaimWeth,
        bool _shouldConvertWethToEth
    ) external nonReentrant {
        address account = msg.sender;

        uint256 vwaveAmount = 0;
        if (_shouldClaimVwave) {
            uint256 vwaveAmount0 = IVester(vwaveVester).claimForAccount(account, account);
            uint256 vwaveAmount1 = IVester(vlpVester).claimForAccount(account, account);
            vwaveAmount = vwaveAmount0.add(vwaveAmount1);
        }

        if (_shouldStakeVwave && vwaveAmount > 0) {
            _stakeVwave(account, account, vwave, vwaveAmount);
        }

        uint256 esVwaveAmount = 0;
        if (_shouldClaimEsVwave) {
            uint256 esVwaveAmount0 = IRewardTracker(stakedVwaveTracker).claimForAccount(account, account);
            uint256 esVwaveAmount1 = IRewardTracker(stakedVlpTracker).claimForAccount(account, account);
            esVwaveAmount = esVwaveAmount0.add(esVwaveAmount1);
        }

        if (_shouldStakeEsVwave && esVwaveAmount > 0) {
            _stakeVwave(account, account, esVwave, esVwaveAmount);
        }

        if (_shouldStakeMultiplierPoints) {
            uint256 bnVwaveAmount = IRewardTracker(bonusVwaveTracker).claimForAccount(account, account);
            if (bnVwaveAmount > 0) {
                IRewardTracker(feeVwaveTracker).stakeForAccount(account, account, bnVwave, bnVwaveAmount);
            }
        }

        if (_shouldClaimWeth) {
            if (_shouldConvertWethToEth) {
                uint256 weth0 = IRewardTracker(feeVwaveTracker).claimForAccount(account, address(this));
                uint256 weth1 = IRewardTracker(feeVlpTracker).claimForAccount(account, address(this));

                uint256 wethAmount = weth0.add(weth1);
                IWETH(weth).withdraw(wethAmount);

                payable(account).sendValue(wethAmount);
            } else {
                IRewardTracker(feeVwaveTracker).claimForAccount(account, account);
                IRewardTracker(feeVlpTracker).claimForAccount(account, account);
            }
        }
    }

    function batchCompoundForAccounts(address[] memory _accounts) external nonReentrant onlyGov {
        for (uint256 i = 0; i < _accounts.length; i++) {
            _compound(_accounts[i]);
        }
    }

    function signalTransfer(address _receiver) external nonReentrant {
        require(IERC20(vwaveVester).balanceOf(msg.sender) == 0, "RewardRouter: sender has vested tokens");
        require(IERC20(vlpVester).balanceOf(msg.sender) == 0, "RewardRouter: sender has vested tokens");

        _validateReceiver(_receiver);
        pendingReceivers[msg.sender] = _receiver;
    }

    function acceptTransfer(address _sender) external nonReentrant {
        require(IERC20(vwaveVester).balanceOf(_sender) == 0, "RewardRouter: sender has vested tokens");
        require(IERC20(vlpVester).balanceOf(_sender) == 0, "RewardRouter: sender has vested tokens");

        address receiver = msg.sender;
        require(pendingReceivers[_sender] == receiver, "RewardRouter: transfer not signalled");
        delete pendingReceivers[_sender];

        _validateReceiver(receiver);
        _compound(_sender);

        uint256 stakedVwave = IRewardTracker(stakedVwaveTracker).depositBalances(_sender, vwave);
        if (stakedVwave > 0) {
            _unstakeVwave(_sender, vwave, stakedVwave, false);
            _stakeVwave(_sender, receiver, vwave, stakedVwave);
        }

        uint256 stakedEsVwave = IRewardTracker(stakedVwaveTracker).depositBalances(_sender, esVwave);
        if (stakedEsVwave > 0) {
            _unstakeVwave(_sender, esVwave, stakedEsVwave, false);
            _stakeVwave(_sender, receiver, esVwave, stakedEsVwave);
        }

        uint256 stakedBnVwave = IRewardTracker(feeVwaveTracker).depositBalances(_sender, bnVwave);
        if (stakedBnVwave > 0) {
            IRewardTracker(feeVwaveTracker).unstakeForAccount(_sender, bnVwave, stakedBnVwave, _sender);
            IRewardTracker(feeVwaveTracker).stakeForAccount(_sender, receiver, bnVwave, stakedBnVwave);
        }

        uint256 esVwaveBalance = IERC20(esVwave).balanceOf(_sender);
        if (esVwaveBalance > 0) {
            IERC20(esVwave).transferFrom(_sender, receiver, esVwaveBalance);
        }

        uint256 vlpAmount = IRewardTracker(feeVlpTracker).depositBalances(_sender, vlp);
        if (vlpAmount > 0) {
            IRewardTracker(stakedVlpTracker).unstakeForAccount(_sender, feeVlpTracker, vlpAmount, _sender);
            IRewardTracker(feeVlpTracker).unstakeForAccount(_sender, vlp, vlpAmount, _sender);

            IRewardTracker(feeVlpTracker).stakeForAccount(_sender, receiver, vlp, vlpAmount);
            IRewardTracker(stakedVlpTracker).stakeForAccount(receiver, receiver, feeVlpTracker, vlpAmount);
        }

        IVester(vwaveVester).transferStakeValues(_sender, receiver);
        IVester(vlpVester).transferStakeValues(_sender, receiver);
    }

    function _validateReceiver(address _receiver) private view {
        require(IRewardTracker(stakedVwaveTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: stakedVwaveTracker.averageStakedAmounts > 0");
        require(IRewardTracker(stakedVwaveTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: stakedVwaveTracker.cumulativeRewards > 0");

        require(IRewardTracker(bonusVwaveTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: bonusVwaveTracker.averageStakedAmounts > 0");
        require(IRewardTracker(bonusVwaveTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: bonusVwaveTracker.cumulativeRewards > 0");

        require(IRewardTracker(feeVwaveTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: feeVwaveTracker.averageStakedAmounts > 0");
        require(IRewardTracker(feeVwaveTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: feeVwaveTracker.cumulativeRewards > 0");

        require(IVester(vwaveVester).transferredAverageStakedAmounts(_receiver) == 0, "RewardRouter: vwaveVester.transferredAverageStakedAmounts > 0");
        require(IVester(vwaveVester).transferredCumulativeRewards(_receiver) == 0, "RewardRouter: vwaveVester.transferredCumulativeRewards > 0");

        require(IRewardTracker(stakedVlpTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: stakedVlpTracker.averageStakedAmounts > 0");
        require(IRewardTracker(stakedVlpTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: stakedVlpTracker.cumulativeRewards > 0");

        require(IRewardTracker(feeVlpTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: feeVlpTracker.averageStakedAmounts > 0");
        require(IRewardTracker(feeVlpTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: feeVlpTracker.cumulativeRewards > 0");

        require(IVester(vlpVester).transferredAverageStakedAmounts(_receiver) == 0, "RewardRouter: vwaveVester.transferredAverageStakedAmounts > 0");
        require(IVester(vlpVester).transferredCumulativeRewards(_receiver) == 0, "RewardRouter: vwaveVester.transferredCumulativeRewards > 0");

        require(IERC20(vwaveVester).balanceOf(_receiver) == 0, "RewardRouter: vwaveVester.balance > 0");
        require(IERC20(vlpVester).balanceOf(_receiver) == 0, "RewardRouter: vlpVester.balance > 0");
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

        emit StakeVwave(_account, _token, _amount);
    }

    function _unstakeVwave(address _account, address _token, uint256 _amount, bool _shouldReduceBnVwave) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        uint256 balance = IRewardTracker(stakedVwaveTracker).stakedAmounts(_account);

        IRewardTracker(feeVwaveTracker).unstakeForAccount(_account, bonusVwaveTracker, _amount, _account);
        IRewardTracker(bonusVwaveTracker).unstakeForAccount(_account, stakedVwaveTracker, _amount, _account);
        IRewardTracker(stakedVwaveTracker).unstakeForAccount(_account, _token, _amount, _account);

        if (_shouldReduceBnVwave) {
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
        }

        emit UnstakeVwave(_account, _token, _amount);
    }
}
