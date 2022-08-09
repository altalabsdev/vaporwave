// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../core/interfaces/IVault.sol";
import "../core/interfaces/IVaultPriceFeed.sol";
import "../tokens/interfaces/IYieldTracker.sol";
import "../tokens/interfaces/IYieldToken.sol";
import "../amm/interfaces/IPancakeFactory.sol";

import "../staking/interfaces/IVester.sol";

/// @title Vaporwave Reader
contract Reader is Ownable {
    /// USDV decimals
    uint8 public constant USDV_DECIMALS = 18;
    /// Number of properties for a position
    uint8 public constant POSITION_PROPS_LENGTH = 9;
    /// Helper to avoid truncation errors in basis points calculations
    uint16 public constant BASIS_POINTS_DIVISOR = 10000;
    /// Helper to avoid truncation errors in price calculations
    uint128 public constant PRICE_PRECISION = 1e30;

    /// True if there is a max global short size
    bool public hasMaxGlobalShortSizes;

    /// @notice Set if the contract has max global short sizes to `_hasMaxGlobalShortSizes`
    /// @param _hasMaxGlobalShortSizes True if the contract has max global short sizes
    function setConfig(bool _hasMaxGlobalShortSizes) public onlyOwner {
        hasMaxGlobalShortSizes = _hasMaxGlobalShortSizes;
    }

    /// @notice Get the max amount in
    /// @param _vault The vault address
    /// @param _tokenIn The address of the token to swap in
    /// @param _tokenOut The address of the token to swap out
    /// @return The max amount in
    function getMaxAmountIn(
        IVault _vault,
        address _tokenIn,
        address _tokenOut
    ) public view returns (uint256) {
        uint256 priceIn = _vault.getMinPrice(_tokenIn);
        uint256 priceOut = _vault.getMaxPrice(_tokenOut);

        uint256 tokenInDecimals = _vault.tokenDecimals(_tokenIn);
        uint256 tokenOutDecimals = _vault.tokenDecimals(_tokenOut);

        uint256 amountIn;

        {
            uint256 poolAmount = _vault.poolAmounts(_tokenOut);
            uint256 reservedAmount = _vault.reservedAmounts(_tokenOut);
            uint256 bufferAmount = _vault.bufferAmounts(_tokenOut);
            uint256 subAmount = reservedAmount > bufferAmount
                ? reservedAmount
                : bufferAmount;
            if (subAmount >= poolAmount) {
                return 0;
            }
            uint256 availableAmount = poolAmount - subAmount;
            amountIn =
                (((availableAmount * priceOut) / priceIn) *
                    (10**tokenInDecimals)) /
                (10**tokenOutDecimals);
        }

        uint256 maxUsdvAmount = _vault.maxUsdvAmounts(_tokenIn);

        if (maxUsdvAmount != 0) {
            if (maxUsdvAmount < _vault.usdvAmounts(_tokenIn)) {
                return 0;
            }

            uint256 maxAmountIn = maxUsdvAmount - _vault.usdvAmounts(_tokenIn);
            maxAmountIn =
                (maxAmountIn * (10**tokenInDecimals)) /
                (10**USDV_DECIMALS);
            maxAmountIn = (maxAmountIn * PRICE_PRECISION) / priceIn;

            if (amountIn > maxAmountIn) {
                return maxAmountIn;
            }
        }

        return amountIn;
    }

    /// @notice Get the amount out
    /// @param _vault The vault address
    /// @param _tokenIn The address of the token to swap in
    /// @param _tokenOut The address of the token to swap out
    /// @param _amountIn The amount in
    /// @return A tuple (amount out after fees, fee amount)
    function getAmountOut(
        IVault _vault,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) public view returns (uint256, uint256) {
        uint256 priceIn = _vault.getMinPrice(_tokenIn);

        uint256 tokenInDecimals = _vault.tokenDecimals(_tokenIn);
        uint256 tokenOutDecimals = _vault.tokenDecimals(_tokenOut);

        uint256 feeBasisPoints;
        {
            uint256 usdvAmount = (_amountIn * priceIn) / PRICE_PRECISION;
            usdvAmount =
                (usdvAmount * (10**USDV_DECIMALS)) /
                (10**tokenInDecimals);

            bool isStableSwap = _vault.stableTokens(_tokenIn) &&
                _vault.stableTokens(_tokenOut);
            uint256 baseBps = isStableSwap
                ? _vault.stableSwapFeeBasisPoints()
                : _vault.swapFeeBasisPoints();
            uint256 taxBps = isStableSwap
                ? _vault.stableTaxBasisPoints()
                : _vault.taxBasisPoints();
            uint256 feesBasisPoints0 = _vault.getFeeBasisPoints(
                _tokenIn,
                usdvAmount,
                baseBps,
                taxBps,
                true
            );
            uint256 feesBasisPoints1 = _vault.getFeeBasisPoints(
                _tokenOut,
                usdvAmount,
                baseBps,
                taxBps,
                false
            );
            // use the higher of the two fee basis points
            feeBasisPoints = feesBasisPoints0 > feesBasisPoints1
                ? feesBasisPoints0
                : feesBasisPoints1;
        }

        uint256 priceOut = _vault.getMaxPrice(_tokenOut);
        uint256 amountOut = (_amountIn * priceIn) / priceOut;
        amountOut =
            (amountOut * (10**tokenOutDecimals)) /
            (10**tokenInDecimals);

        uint256 amountOutAfterFees = (amountOut *
            (BASIS_POINTS_DIVISOR - feeBasisPoints)) / BASIS_POINTS_DIVISOR;
        uint256 feeAmount = amountOut - amountOutAfterFees;

        return (amountOutAfterFees, feeAmount);
    }

    /// @notice Get the fee basis points
    /// @param _vault The vault address
    /// @param _tokenIn The token to swap in
    /// @param _tokenOut The token to swap out
    /// @param _amountIn The amount in
    /// @return A tuple (fee basis points, feeBasisPoints0, feeBasisPoints1)
    function getFeeBasisPoints(
        IVault _vault,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    )
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 priceIn = _vault.getMinPrice(_tokenIn);
        uint256 tokenInDecimals = _vault.tokenDecimals(_tokenIn);

        uint256 usdvAmount = (_amountIn * priceIn) / PRICE_PRECISION;
        usdvAmount = (usdvAmount * (10**USDV_DECIMALS)) / (10**tokenInDecimals);

        bool isStableSwap = _vault.stableTokens(_tokenIn) &&
            _vault.stableTokens(_tokenOut);
        uint256 baseBps = isStableSwap
            ? _vault.stableSwapFeeBasisPoints()
            : _vault.swapFeeBasisPoints();
        uint256 taxBps = isStableSwap
            ? _vault.stableTaxBasisPoints()
            : _vault.taxBasisPoints();
        uint256 feesBasisPoints0 = _vault.getFeeBasisPoints(
            _tokenIn,
            usdvAmount,
            baseBps,
            taxBps,
            true
        );
        uint256 feesBasisPoints1 = _vault.getFeeBasisPoints(
            _tokenOut,
            usdvAmount,
            baseBps,
            taxBps,
            false
        );
        // use the higher of the two fee basis points
        uint256 feeBasisPoints = feesBasisPoints0 > feesBasisPoints1
            ? feesBasisPoints0
            : feesBasisPoints1;

        return (feeBasisPoints, feesBasisPoints0, feesBasisPoints1);
    }

    /// @notice Get the fee amounts
    /// @param _vault The vault address
    /// @param _tokens An array of tokens to query for fees
    /// @return An array of fee amounts
    function getFees(address _vault, address[] memory _tokens)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory amounts = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            amounts[i] = IVault(_vault).feeReserves(_tokens[i]);
        }
        return amounts;
    }

    /// @notice Get the total staked amounts
    /// @param _yieldTokens An array of tokens to query for staked amounts
    /// @return An array of total staked amounts
    function getTotalStaked(address[] memory _yieldTokens)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory amounts = new uint256[](_yieldTokens.length);
        for (uint256 i = 0; i < _yieldTokens.length; i++) {
            IYieldToken yieldToken = IYieldToken(_yieldTokens[i]);
            amounts[i] = yieldToken.totalStaked();
        }
        return amounts;
    }

    /// @notice Get the staking info for `_account`
    /// @param _account The address to query for staking info
    /// @param _yieldTrackers An array of yield trackers to query for staking info
    /// @return An array of staking info (even index = claimable amounts, odd index = tokens per interval)
    function getStakingInfo(address _account, address[] memory _yieldTrackers)
        public
        view
        returns (uint256[] memory)
    {
        uint256 propsLength = 2;
        uint256[] memory amounts = new uint256[](
            _yieldTrackers.length * propsLength
        );
        for (uint256 i = 0; i < _yieldTrackers.length; i++) {
            IYieldTracker yieldTracker = IYieldTracker(_yieldTrackers[i]);
            amounts[i * propsLength] = yieldTracker.claimable(_account);
            amounts[i * propsLength + 1] = yieldTracker.getTokensPerInterval();
        }
        return amounts;
    }

    /// @notice Get the vesting info for `_account`
    /// @param _account The address to query for vesting info
    /// @param _vesters An array of vesters to query for vesting info
    /// @return An array of vesting info
    function getVestingInfo(address _account, address[] memory _vesters)
        public
        view
        returns (uint256[] memory)
    {
        uint256 propsLength = 7;
        uint256[] memory amounts = new uint256[](_vesters.length * propsLength);
        for (uint256 i = 0; i < _vesters.length; i++) {
            IVester vester = IVester(_vesters[i]);
            amounts[i * propsLength] = vester.pairAmounts(_account);
            amounts[i * propsLength + 1] = vester.getVestedAmount(_account);
            amounts[i * propsLength + 2] = IERC20(_vesters[i]).balanceOf(
                _account
            );
            amounts[i * propsLength + 3] = vester.claimedAmounts(_account);
            amounts[i * propsLength + 4] = vester.claimable(_account);
            amounts[i * propsLength + 5] = vester.getMaxVestableAmount(
                _account
            );
            amounts[i * propsLength + 6] = vester
                .getCombinedAverageStakedAmount(_account);
        }
        return amounts;
    }

    /// @notice Get token pair info from `_factory`
    /// @param _factory The AMM factory address
    /// @param _tokens An array of tokens to query for token pair info
    /// @return An array of token pair info
    function getPairInfo(address _factory, address[] memory _tokens)
        public
        view
        returns (uint256[] memory)
    {
        uint256 inputLength = 2;
        uint256 propsLength = 2;
        uint256[] memory amounts = new uint256[](
            (_tokens.length / inputLength) * propsLength
        );
        for (uint256 i = 0; i < _tokens.length / inputLength; i++) {
            address token0 = _tokens[i * inputLength];
            address token1 = _tokens[i * inputLength + 1];
            address pair = IPancakeFactory(_factory).getPair(token0, token1);

            amounts[i * propsLength] = IERC20(token0).balanceOf(pair);
            amounts[i * propsLength + 1] = IERC20(token1).balanceOf(pair);
        }
        return amounts;
    }

    /// @notice Get funding rates for an array of tokens
    /// @param _vault The vault address
    /// @param _weth The WETH address
    /// @param _tokens An array of tokens to query for funding rates
    /// @return An array of funding rates
    function getFundingRates(
        address _vault,
        address _weth,
        address[] memory _tokens
    ) public view returns (uint256[] memory) {
        uint256 propsLength = 2;
        uint256[] memory fundingRates = new uint256[](
            _tokens.length * propsLength
        );
        IVault vault = IVault(_vault);

        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                token = _weth;
            }

            uint256 fundingRateFactor = vault.stableTokens(token)
                ? vault.stableFundingRateFactor()
                : vault.fundingRateFactor();
            uint256 reservedAmount = vault.reservedAmounts(token);
            uint256 poolAmount = vault.poolAmounts(token);

            if (poolAmount > 0) {
                fundingRates[i * propsLength] =
                    (fundingRateFactor * reservedAmount) /
                    poolAmount;
            }

            if (vault.cumulativeFundingRates(token) > 0) {
                uint256 nextRate = vault.getNextFundingRate(token);
                uint256 baseRate = vault.cumulativeFundingRates(token);
                fundingRates[i * propsLength + 1] = baseRate + nextRate;
            }
        }

        return fundingRates;
    }

    /// @notice Get the token supply of `_token`
    /// @dev Calculates the total supply minus the balance of `_excludedAccounts`
    /// @param _token The token address
    /// @param _excludedAccounts An array of accounts to exclude from the supply calculation
    /// @return The token supply
    function getTokenSupply(IERC20 _token, address[] memory _excludedAccounts)
        public
        view
        returns (uint256)
    {
        uint256 supply = _token.totalSupply();
        for (uint256 i = 0; i < _excludedAccounts.length; i++) {
            address account = _excludedAccounts[i];
            uint256 balance = _token.balanceOf(account);
            supply -= balance;
        }
        return supply;
    }

    /// @notice Get the total balance of `_token` for `_accounts`
    /// @param _token The token address
    /// @param _accounts An array of accounts to query for balance
    /// @return The total balance of `_token` for `_accounts`
    function getTotalBalance(IERC20 _token, address[] memory _accounts)
        public
        view
        returns (uint256)
    {
        uint256 totalBalance = 0;
        for (uint256 i = 0; i < _accounts.length; i++) {
            address account = _accounts[i];
            uint256 balance = _token.balanceOf(account);
            totalBalance += balance;
        }
        return totalBalance;
    }

    /// @notice Get the token balances for `_account`
    /// @dev Address(0) is used for the native currency
    /// @param _account The account to query for token balances
    /// @param _tokens An array of tokens to query for balances
    /// @return An array of token balances
    function getTokenBalances(address _account, address[] memory _tokens)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory balances = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                balances[i] = _account.balance;
                continue;
            }
            balances[i] = IERC20(token).balanceOf(_account);
        }
        return balances;
    }

    /// @notice Get the token balances for `_account` + total supplies
    /// @dev Address(0) is used for the native currency
    /// @param _account The account to query for token balances
    /// @param _tokens An array of tokens to query for balances
    function getTokenBalancesWithSupplies(
        address _account,
        address[] memory _tokens
    ) public view returns (uint256[] memory) {
        uint256 propsLength = 2;
        uint256[] memory balances = new uint256[](_tokens.length * propsLength);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                balances[i * propsLength] = _account.balance;
                balances[i * propsLength + 1] = 0;
                continue;
            }
            balances[i * propsLength] = IERC20(token).balanceOf(_account);
            balances[i * propsLength + 1] = IERC20(token).totalSupply();
        }
        return balances;
    }

    /// @notice Get the prices for an array of tokens
    /// @param _priceFeed The price feed address
    /// @param _tokens An array of tokens to query for prices
    /// @return An array of token prices
    function getPrices(IVaultPriceFeed _priceFeed, address[] memory _tokens)
        public
        view
        returns (uint256[] memory)
    {
        uint256 propsLength = 6;

        uint256[] memory amounts = new uint256[](_tokens.length * propsLength);

        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            amounts[i * propsLength] = _priceFeed.getPrice(
                token,
                true,
                true,
                false
            );
            amounts[i * propsLength + 1] = _priceFeed.getPrice(
                token,
                false,
                true,
                false
            );
            amounts[i * propsLength + 2] = _priceFeed.getPrimaryPrice(
                token,
                true
            );
            amounts[i * propsLength + 3] = _priceFeed.getPrimaryPrice(
                token,
                false
            );
            amounts[i * propsLength + 4] = _priceFeed.isAdjustmentAdditive(
                token
            )
                ? 1
                : 0;
            amounts[i * propsLength + 5] = _priceFeed.adjustmentBasisPoints(
                token
            );
        }

        return amounts;
    }

    /// @notice Get the vault token info
    /// @param _vault The vault address
    /// @param _weth The WETH address
    /// @param _usdvAmount The USDV amount
    /// @param _tokens An array of tokens to query for info
    /* @return An array of vault token info
     * (pool amounts, usdv amounts, redemption amounts, token weights, min prices, max prices, guaranteed usd, min primary prices, max primary prices)
     */
    function getVaultTokenInfo(
        address _vault,
        address _weth,
        uint256 _usdvAmount,
        address[] memory _tokens
    ) public view returns (uint256[] memory) {
        uint256 propsLength = 10;

        IVault vault = IVault(_vault);
        IVaultPriceFeed priceFeed = IVaultPriceFeed(vault.priceFeed());

        uint256[] memory amounts = new uint256[](_tokens.length * propsLength);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                token = _weth;
            }
            amounts[i * propsLength] = vault.poolAmounts(token);
            amounts[i * propsLength + 1] = vault.reservedAmounts(token);
            amounts[i * propsLength + 2] = vault.usdvAmounts(token);
            amounts[i * propsLength + 3] = vault.getRedemptionAmount(
                token,
                _usdvAmount
            );
            amounts[i * propsLength + 4] = vault.tokenWeights(token);
            amounts[i * propsLength + 5] = vault.getMinPrice(token);
            amounts[i * propsLength + 6] = vault.getMaxPrice(token);
            amounts[i * propsLength + 7] = vault.guaranteedUsd(token);
            amounts[i * propsLength + 8] = priceFeed.getPrimaryPrice(
                token,
                false
            );
            amounts[i * propsLength + 9] = priceFeed.getPrimaryPrice(
                token,
                true
            );
        }

        return amounts;
    }

    /// @notice Get the full vault token info
    /// @param _vault The vault address
    /// @param _weth The WETH address
    /// @param _usdvAmount The USDV amount
    /// @param _tokens An array of tokens to query for info
    /* @return An array of full vault token info
     * (pool amounts, reserved amounts, usdv amounts, redemption amounts, token weights,
     * min prices, max prices, guaranteed usd, max primary prices, min primary prices)
     */
    function getFullVaultTokenInfo(
        address _vault,
        address _weth,
        uint256 _usdvAmount,
        address[] memory _tokens
    ) public view returns (uint256[] memory) {
        uint256 propsLength = 12;

        IVault vault = IVault(_vault);
        IVaultPriceFeed priceFeed = IVaultPriceFeed(vault.priceFeed());

        uint256[] memory amounts = new uint256[](_tokens.length * propsLength);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                token = _weth;
            }
            amounts[i * propsLength] = vault.poolAmounts(token);
            amounts[i * propsLength + 1] = vault.reservedAmounts(token);
            amounts[i * propsLength + 2] = vault.usdvAmounts(token);
            amounts[i * propsLength + 3] = vault.getRedemptionAmount(
                token,
                _usdvAmount
            );
            amounts[i * propsLength + 4] = vault.tokenWeights(token);
            amounts[i * propsLength + 5] = vault.bufferAmounts(token);
            amounts[i * propsLength + 6] = vault.maxUsdvAmounts(token);
            amounts[i * propsLength + 7] = vault.getMinPrice(token);
            amounts[i * propsLength + 8] = vault.getMaxPrice(token);
            amounts[i * propsLength + 9] = vault.guaranteedUsd(token);
            amounts[i * propsLength + 10] = priceFeed.getPrimaryPrice(
                token,
                false
            );
            amounts[i * propsLength + 11] = priceFeed.getPrimaryPrice(
                token,
                true
            );
        }

        return amounts;
    }

    /// @notice Get the vault token info
    /// @param _vault The vault address
    /// @param _weth The WETH address
    /// @param _usdvAmount The USDV amount
    /// @param _tokens An array of tokens to query for info
    /* @return An array of vault token info
     * (pool amounts, reserved amounts, usdv amounts, redemption amounts, token weights, buffer amounts, max usdv amounts, global short sizes, min prices, max prices, guaranteed usd, min primary prices, max primary prices)
     */
    function getVaultTokenInfoV2(
        address _vault,
        address _weth,
        uint256 _usdvAmount,
        address[] memory _tokens
    ) public view returns (uint256[] memory) {
        uint256 propsLength = 14;

        IVault vault = IVault(_vault);
        IVaultPriceFeed priceFeed = IVaultPriceFeed(vault.priceFeed());

        uint256[] memory amounts = new uint256[](_tokens.length * propsLength);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                token = _weth;
            }

            uint256 maxGlobalShortSize = hasMaxGlobalShortSizes
                ? vault.maxGlobalShortSizes(token)
                : 0;
            amounts[i * propsLength] = vault.poolAmounts(token);
            amounts[i * propsLength + 1] = vault.reservedAmounts(token);
            amounts[i * propsLength + 2] = vault.usdvAmounts(token);
            amounts[i * propsLength + 3] = vault.getRedemptionAmount(
                token,
                _usdvAmount
            );
            amounts[i * propsLength + 4] = vault.tokenWeights(token);
            amounts[i * propsLength + 5] = vault.bufferAmounts(token);
            amounts[i * propsLength + 6] = vault.maxUsdvAmounts(token);
            amounts[i * propsLength + 7] = vault.globalShortSizes(token);
            amounts[i * propsLength + 8] = maxGlobalShortSize;
            amounts[i * propsLength + 9] = vault.getMinPrice(token);
            amounts[i * propsLength + 10] = vault.getMaxPrice(token);
            amounts[i * propsLength + 11] = vault.guaranteedUsd(token);
            amounts[i * propsLength + 12] = priceFeed.getPrimaryPrice(
                token,
                false
            );
            amounts[i * propsLength + 13] = priceFeed.getPrimaryPrice(
                token,
                true
            );
        }

        return amounts;
    }

    /// @notice Get the positions for `_account`
    /// @param _vault The vault address
    /// @param _account The account to query for positions
    /// @param _collateralTokens An array of collateral tokens
    /// @param _indexTokens An array of index tokens
    /// @param _isLong An array of booleans indicating whether the position is long or short
    /* @return An array of positions
    * (size, collateral, average prirce, entry funding rate, 
    has realized profit (bool), realized PnL, last increased time, has profit (bool), delta)
    */
    function getPositions(
        address _vault,
        address _account,
        address[] memory _collateralTokens,
        address[] memory _indexTokens,
        bool[] memory _isLong
    ) public view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](
            _collateralTokens.length * POSITION_PROPS_LENGTH
        );

        for (uint256 i = 0; i < _collateralTokens.length; i++) {
            {
                (
                    uint256 size,
                    uint256 collateral,
                    uint256 averagePrice,
                    uint256 entryFundingRate,
                    ,
                    /* reserveAmount */
                    uint256 realisedPnl,
                    bool hasRealisedProfit,
                    uint256 lastIncreasedTime
                ) = IVault(_vault).getPosition(
                        _account,
                        _collateralTokens[i],
                        _indexTokens[i],
                        _isLong[i]
                    );

                amounts[i * POSITION_PROPS_LENGTH] = size;
                amounts[i * POSITION_PROPS_LENGTH + 1] = collateral;
                amounts[i * POSITION_PROPS_LENGTH + 2] = averagePrice;
                amounts[i * POSITION_PROPS_LENGTH + 3] = entryFundingRate;
                amounts[i * POSITION_PROPS_LENGTH + 4] = hasRealisedProfit
                    ? 1
                    : 0;
                amounts[i * POSITION_PROPS_LENGTH + 5] = realisedPnl;
                amounts[i * POSITION_PROPS_LENGTH + 6] = lastIncreasedTime;
            }

            uint256 size = amounts[i * POSITION_PROPS_LENGTH];
            uint256 averagePrice = amounts[i * POSITION_PROPS_LENGTH + 2];
            uint256 lastIncreasedTime = amounts[i * POSITION_PROPS_LENGTH + 6];
            if (averagePrice > 0) {
                (bool hasProfit, uint256 delta) = IVault(_vault).getDelta(
                    _indexTokens[i],
                    size,
                    averagePrice,
                    _isLong[i],
                    lastIncreasedTime
                );
                amounts[i * POSITION_PROPS_LENGTH + 7] = hasProfit ? 1 : 0;
                amounts[i * POSITION_PROPS_LENGTH + 8] = delta;
            }
        }

        return amounts;
    }
}
