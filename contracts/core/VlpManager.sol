// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IVlpManager.sol";
import "../tokens/interfaces/IUSDV.sol";
import "../tokens/interfaces/IMintable.sol";
import "../access/Governable.sol";

error InvalidCooldownDuration();
error PrivateMode();

/// @title Vaporwave VLP Manager
contract VlpManager is ReentrancyGuard, Governable, IVlpManager {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_PRECISION = 10**30;
    uint256 public constant USDV_DECIMALS = 18;
    uint256 public constant MAX_COOLDOWN_DURATION = 48 hours;

    IVault public vault;
    address public usdv;
    address public vlp;

    uint256 public override cooldownDuration;
    mapping(address => uint256) public override lastAddedAt;

    uint256 public aumAddition;
    uint256 public aumDeduction;

    bool public inPrivateMode;
    mapping(address => bool) public isHandler;

    event AddLiquidity(
        address account,
        address token,
        uint256 amount,
        uint256 aumInUsdv,
        uint256 vlpSupply,
        uint256 usdvAmount,
        uint256 mintAmount
    );

    event RemoveLiquidity(
        address account,
        address token,
        uint256 vlpAmount,
        uint256 aumInUsdv,
        uint256 vlpSupply,
        uint256 usdvAmount,
        uint256 amountOut
    );

    constructor(
        address _vault,
        address _usdv,
        address _vlp,
        uint256 _cooldownDuration
    ) {
        gov = msg.sender;
        vault = IVault(_vault);
        usdv = _usdv;
        vlp = _vlp;
        cooldownDuration = _cooldownDuration;
    }

    /// @notice Set the inPrivateMode flag
    /// @param _inPrivateMode True if the VLP Manager is in private mode, false otherwise
    function setInPrivateMode(bool _inPrivateMode) external onlyGov {
        inPrivateMode = _inPrivateMode;
    }

    /// @notice Set the address of a handler
    /// @param _handler Address of the handler to set
    /// @param _isActive True if the address is a handler, false otherwise
    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    /// @notice Set the cooldown duration
    /// @param _cooldownDuration Cooldown duration in seconds
    function setCooldownDuration(uint256 _cooldownDuration) external onlyGov {
        if (_cooldownDuration > MAX_COOLDOWN_DURATION) {
            revert InvalidCooldownDuration();
        }
        cooldownDuration = _cooldownDuration;
    }

    /// @notice Set the Assets Under Management (AUM) adjustment
    /// @param _aumAddition AUM addition in USDV
    /// @param _aumDeduction AUM deduction in USDV
    function setAumAdjustment(uint256 _aumAddition, uint256 _aumDeduction)
        external
        onlyGov
    {
        aumAddition = _aumAddition;
        aumDeduction = _aumDeduction;
    }

    /// @notice Add liquidity to the VLP
    /// @param _token Address of the token to add liquidity to
    /// @param _amount Amount of tokens to add to the VLP
    /// @param _minUsdv Minimum amount of USDV to add to the VLP
    /// @param _minVlp Minimum amount of VLP to add
    function addLiquidity(
        address _token,
        uint256 _amount,
        uint256 _minUsdv,
        uint256 _minVlp
    ) external override nonReentrant returns (uint256) {
        if (inPrivateMode) {
            revert PrivateMode();
        }
        return
            _addLiquidity(
                msg.sender,
                msg.sender,
                _token,
                _amount,
                _minUsdv,
                _minVlp
            );
    }

    /// @notice Add liquidity for a third-party account
    /// @param _fundingAccount Address of the funding account
    /// @param _account Address of the liquidity account
    /// @param _token Address of the token to add liquidity to
    /// @param _amount Amount of tokens to add to the VLP
    /// @param _minUsdv Minimum amount of USDV to add to the VLP
    /// @param _minVlp Minimum amount of VLP to add
    function addLiquidityForAccount(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount,
        uint256 _minUsdv,
        uint256 _minVlp
    ) external override nonReentrant returns (uint256) {
        _validateHandler();
        return
            _addLiquidity(
                _fundingAccount,
                _account,
                _token,
                _amount,
                _minUsdv,
                _minVlp
            );
    }

    /// @notice Remove liquidity from the VLP
    /// @param _tokenOut Address of the token to remove
    /// @param _vlpAmount Amount of VLP to remove
    /// @param _minOut Minimum amount of tokens to remove from the VLP
    /// @param _receiver Address to receive the withdrawn tokens
    function removeLiquidity(
        address _tokenOut,
        uint256 _vlpAmount,
        uint256 _minOut,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        if (inPrivateMode) {
            revert PrivateMode();
        }
        return
            _removeLiquidity(
                msg.sender,
                _tokenOut,
                _vlpAmount,
                _minOut,
                _receiver
            );
    }

    /// @notice Remove liquidity for a third-party account
    /// @param _account Address of the liquidity account
    /// @param _tokenOut Addrss of the token to remove
    /// @param _vlpAmount Amount of VLP to remove
    /// @param _minOut Minimum amount of tokens to remove from the VLP
    /// @param _receiver Address to receive the withdrawn tokens
    function removeLiquidityForAccount(
        address _account,
        address _tokenOut,
        uint256 _vlpAmount,
        uint256 _minOut,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateHandler();
        return
            _removeLiquidity(
                _account,
                _tokenOut,
                _vlpAmount,
                _minOut,
                _receiver
            );
    }

    /// @notice Get assets under management (AUM)
    /// @return Array with 2 values, min AUM and max AUm
    function getAums() public view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = getAum(true);
        amounts[1] = getAum(false);
        return amounts;
    }

    /// @notice Get assets under management (AUM) denominated in USDV
    /// @param maximise True if the maximum AUM should be returned, false otherwise
    /// @return AUM in USDV
    function getAumInUsdv(bool maximise) public view returns (uint256) {
        uint256 aum = getAum(maximise);
        return aum.mul(10**USDV_DECIMALS).div(PRICE_PRECISION);
    }

    /// @notice Get Assets Under Management(AUM)
    /// @param maximise True if the maximum AUM should be returned, false otherwise
    /// @return AUM
    function getAum(bool maximise) public view returns (uint256) {
        uint256 length = vault.allWhitelistedTokensLength();
        uint256 aum = aumAddition;
        uint256 shortProfits = 0;

        for (uint256 i = 0; i < length; i++) {
            address token = vault.allWhitelistedTokens(i);
            bool isWhitelisted = vault.whitelistedTokens(token);

            if (!isWhitelisted) {
                continue;
            }

            uint256 price = maximise
                ? vault.getMaxPrice(token)
                : vault.getMinPrice(token);
            uint256 poolAmount = vault.poolAmounts(token);
            uint256 decimals = vault.tokenDecimals(token);

            if (vault.stableTokens(token)) {
                aum = aum.add(poolAmount.mul(price).div(10**decimals));
            } else {
                // add global short profit / loss
                uint256 size = vault.globalShortSizes(token);
                if (size > 0) {
                    uint256 averagePrice = vault.globalShortAveragePrices(
                        token
                    );
                    uint256 priceDelta = averagePrice > price
                        ? averagePrice.sub(price)
                        : price.sub(averagePrice);
                    uint256 delta = size.mul(priceDelta).div(averagePrice);
                    if (price > averagePrice) {
                        // add losses from shorts
                        aum = aum.add(delta);
                    } else {
                        shortProfits = shortProfits.add(delta);
                    }
                }

                aum = aum.add(vault.guaranteedUsd(token));

                uint256 reservedAmount = vault.reservedAmounts(token);
                aum = aum.add(
                    poolAmount.sub(reservedAmount).mul(price).div(10**decimals)
                );
            }
        }

        aum = shortProfits > aum ? 0 : aum.sub(shortProfits);
        return aumDeduction > aum ? 0 : aum.sub(aumDeduction);
    }

    function _addLiquidity(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount,
        uint256 _minUsdv,
        uint256 _minVlp
    ) private returns (uint256) {
        require(_amount > 0, "VlpManager: invalid _amount");

        // calculate aum before buyUSDV
        uint256 aumInUsdv = getAumInUsdv(true);
        uint256 vlpSupply = IERC20(vlp).totalSupply();

        IERC20(_token).safeTransferFrom(
            _fundingAccount,
            address(vault),
            _amount
        );
        uint256 usdvAmount = vault.buyUSDV(_token, address(this));
        require(usdvAmount >= _minUsdv, "VlpManager: insufficient USDV output");

        uint256 mintAmount = aumInUsdv == 0
            ? usdvAmount
            : usdvAmount.mul(vlpSupply).div(aumInUsdv);
        require(mintAmount >= _minVlp, "VlpManager: insufficient VLP output");

        IMintable(vlp).mint(_account, mintAmount);

        lastAddedAt[_account] = block.timestamp;

        emit AddLiquidity(
            _account,
            _token,
            _amount,
            aumInUsdv,
            vlpSupply,
            usdvAmount,
            mintAmount
        );

        return mintAmount;
    }

    function _removeLiquidity(
        address _account,
        address _tokenOut,
        uint256 _vlpAmount,
        uint256 _minOut,
        address _receiver
    ) private returns (uint256) {
        require(_vlpAmount > 0, "VlpManager: invalid _vlpAmount");
        require(
            lastAddedAt[_account].add(cooldownDuration) <= block.timestamp,
            "VlpManager: cooldown duration not yet passed"
        );

        // calculate aum before sellUSDV
        uint256 aumInUsdv = getAumInUsdv(false);
        uint256 vlpSupply = IERC20(vlp).totalSupply();

        uint256 usdvAmount = _vlpAmount.mul(aumInUsdv).div(vlpSupply);
        uint256 usdvBalance = IERC20(usdv).balanceOf(address(this));
        if (usdvAmount > usdvBalance) {
            IUSDV(usdv).mint(address(this), usdvAmount.sub(usdvBalance));
        }

        IMintable(vlp).burn(_account, _vlpAmount);

        IERC20(usdv).transfer(address(vault), usdvAmount);
        uint256 amountOut = vault.sellUSDV(_tokenOut, _receiver);
        require(amountOut >= _minOut, "VlpManager: insufficient output");

        emit RemoveLiquidity(
            _account,
            _tokenOut,
            _vlpAmount,
            aumInUsdv,
            vlpSupply,
            usdvAmount,
            amountOut
        );

        return amountOut;
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "VlpManager: forbidden");
    }
}
