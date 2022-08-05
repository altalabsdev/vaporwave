// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultUtils.sol";

import "../access/Governable.sol";

/// @title Vaporwave Vault Utils
contract VaultUtils is IVaultUtils, Governable {
    using SafeMath for uint256;

    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    IVault public vault;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;

    constructor(IVault _vault) {
        vault = _vault;
    }

    /// @dev Function does nothing, included to satisfy the IVaultUtils interface
    function validateIncreasePosition(
        address, /* _account */
        address, /* _collateralToken */
        address, /* _indexToken */
        uint256, /* _sizeDelta */
        bool /* _isLong */
    ) external view override {
        // no additional validations
    }

    /// @dev Function does nothing, included to satisfy the IVaultUtils interface
    function validateDecreasePosition(
        address, /* _account */
        address, /* _collateralToken */
        address, /* _indexToken */
        uint256, /* _collateralDelta */
        uint256, /* _sizeDelta */
        bool, /* _isLong */
        address /* _receiver */
    ) external view override {
        // no additional validations
    }

    function validateLiquidation(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        bool _raise
    ) public view override returns (uint256, uint256) {
        Position memory position = _getPosition(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        IVault _vault = vault;

        (bool hasProfit, uint256 delta) = _vault.getDelta(
            _indexToken,
            position.size,
            position.averagePrice,
            _isLong,
            position.lastIncreasedTime
        );
        uint256 marginFees = getFundingFee(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            position.size,
            position.entryFundingRate
        );
        marginFees = marginFees.add(
            getPositionFee(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                position.size
            )
        );

        if (!hasProfit && position.collateral < delta) {
            if (_raise) {
                revert("Vault: losses exceed collateral");
            }
            return (1, marginFees);
        }

        uint256 remainingCollateral = position.collateral;
        if (!hasProfit) {
            remainingCollateral = position.collateral.sub(delta);
        }

        if (remainingCollateral < marginFees) {
            if (_raise) {
                revert("Vault: fees exceed collateral");
            }
            // cap the fees to the remainingCollateral
            return (1, remainingCollateral);
        }

        if (remainingCollateral < marginFees.add(_vault.liquidationFeeUsd())) {
            if (_raise) {
                revert("Vault: liquidation fees exceed collateral");
            }
            return (1, marginFees);
        }

        if (
            remainingCollateral.mul(_vault.maxLeverage()) <
            position.size.mul(BASIS_POINTS_DIVISOR)
        ) {
            if (_raise) {
                revert("Vault: maxLeverage exceeded");
            }
            return (2, marginFees);
        }

        return (0, marginFees);
    }

    function getEntryFundingRate(
        address _collateralToken,
        address, /* _indexToken */
        bool /* _isLong */
    ) public view override returns (uint256) {
        return vault.cumulativeFundingRates(_collateralToken);
    }

    /// @notice Get the position fee
    /// @param _sizeDelta The change in the position size
    /// @return The position fee
    function getPositionFee(
        address, /* _account */
        address, /* _collateralToken */
        address, /* _indexToken */
        bool, /* _isLong */
        uint256 _sizeDelta
    ) public view override returns (uint256) {
        if (_sizeDelta == 0) {
            return 0;
        }
        uint256 afterFeeUsd = _sizeDelta
            .mul(BASIS_POINTS_DIVISOR.sub(vault.marginFeeBasisPoints()))
            .div(BASIS_POINTS_DIVISOR);
        return _sizeDelta.sub(afterFeeUsd);
    }

    function getFundingFee(
        address, /* _account */
        address _collateralToken,
        address, /* _indexToken */
        bool, /* _isLong */
        uint256 _size,
        uint256 _entryFundingRate
    ) public view override returns (uint256) {
        if (_size == 0) {
            return 0;
        }

        uint256 fundingRate = vault
            .cumulativeFundingRates(_collateralToken)
            .sub(_entryFundingRate);
        if (fundingRate == 0) {
            return 0;
        }

        return _size.mul(fundingRate).div(FUNDING_RATE_PRECISION);
    }

    function getBuyUsdvFeeBasisPoints(address _token, uint256 _usdvAmount)
        public
        view
        override
        returns (uint256)
    {
        return
            getFeeBasisPoints(
                _token,
                _usdvAmount,
                vault.mintBurnFeeBasisPoints(),
                vault.taxBasisPoints(),
                true
            );
    }

    function getSellUsdvFeeBasisPoints(address _token, uint256 _usdvAmount)
        public
        view
        override
        returns (uint256)
    {
        return
            getFeeBasisPoints(
                _token,
                _usdvAmount,
                vault.mintBurnFeeBasisPoints(),
                vault.taxBasisPoints(),
                false
            );
    }

    function getSwapFeeBasisPoints(
        address _tokenIn,
        address _tokenOut,
        uint256 _usdvAmount
    ) public view override returns (uint256) {
        bool isStableSwap = vault.stableTokens(_tokenIn) &&
            vault.stableTokens(_tokenOut);
        uint256 baseBps = isStableSwap
            ? vault.stableSwapFeeBasisPoints()
            : vault.swapFeeBasisPoints();
        uint256 taxBps = isStableSwap
            ? vault.stableTaxBasisPoints()
            : vault.taxBasisPoints();
        uint256 feesBasisPoints0 = getFeeBasisPoints(
            _tokenIn,
            _usdvAmount,
            baseBps,
            taxBps,
            true
        );
        uint256 feesBasisPoints1 = getFeeBasisPoints(
            _tokenOut,
            _usdvAmount,
            baseBps,
            taxBps,
            false
        );
        // use the higher of the two fee basis points
        return
            feesBasisPoints0 > feesBasisPoints1
                ? feesBasisPoints0
                : feesBasisPoints1;
    }

    // cases to consider
    // 1. initialAmount is far from targetAmount, action increases balance slightly => high rebate
    // 2. initialAmount is far from targetAmount, action increases balance largely => high rebate
    // 3. initialAmount is close to targetAmount, action increases balance slightly => low rebate
    // 4. initialAmount is far from targetAmount, action reduces balance slightly => high tax
    // 5. initialAmount is far from targetAmount, action reduces balance largely => high tax
    // 6. initialAmount is close to targetAmount, action reduces balance largely => low tax
    // 7. initialAmount is above targetAmount, nextAmount is below targetAmount and vice versa
    // 8. a large swap should have similar fees as the same trade split into multiple smaller swaps
    function getFeeBasisPoints(
        address _token,
        uint256 _usdvDelta,
        uint256 _feeBasisPoints,
        uint256 _taxBasisPoints,
        bool _increment
    ) public view override returns (uint256) {
        if (!vault.hasDynamicFees()) {
            return _feeBasisPoints;
        }

        uint256 initialAmount = vault.usdvAmounts(_token);
        uint256 nextAmount = initialAmount.add(_usdvDelta);
        if (!_increment) {
            nextAmount = _usdvDelta > initialAmount
                ? 0
                : initialAmount.sub(_usdvDelta);
        }

        uint256 targetAmount = vault.getTargetUsdvAmount(_token);
        if (targetAmount == 0) {
            return _feeBasisPoints;
        }

        uint256 initialDiff = initialAmount > targetAmount
            ? initialAmount.sub(targetAmount)
            : targetAmount.sub(initialAmount);
        uint256 nextDiff = nextAmount > targetAmount
            ? nextAmount.sub(targetAmount)
            : targetAmount.sub(nextAmount);

        // action improves relative asset balance
        if (nextDiff < initialDiff) {
            uint256 rebateBps = _taxBasisPoints.mul(initialDiff).div(
                targetAmount
            );
            return
                rebateBps > _feeBasisPoints
                    ? 0
                    : _feeBasisPoints.sub(rebateBps);
        }

        uint256 averageDiff = initialDiff.add(nextDiff).div(2);
        if (averageDiff > targetAmount) {
            averageDiff = targetAmount;
        }
        uint256 taxBps = _taxBasisPoints.mul(averageDiff).div(targetAmount);
        return _feeBasisPoints.add(taxBps);
    }

    /// @dev Always returns true, included to satisfy the IVaultUtils interface
    function updateCumulativeFundingRate(
        address, /* _collateralToken */
        address /* _indexToken */
    ) public pure override returns (bool) {
        return true;
    }

    function _getPosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) internal view returns (Position memory) {
        IVault _vault = vault;
        Position memory position;
        {
            (
                uint256 size,
                uint256 collateral,
                uint256 averagePrice,
                uint256 entryFundingRate, /* reserveAmount */ /* realisedPnl */ /* hasProfit */
                ,
                ,
                ,
                uint256 lastIncreasedTime
            ) = _vault.getPosition(
                    _account,
                    _collateralToken,
                    _indexToken,
                    _isLong
                );
            position.size = size;
            position.collateral = collateral;
            position.averagePrice = averagePrice;
            position.entryFundingRate = entryFundingRate;
            position.lastIncreasedTime = lastIncreasedTime;
        }
        return position;
    }
}
