// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../tokens/interfaces/IUSDV.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultUtils.sol";
import "./interfaces/IVaultPriceFeed.sol";

/// Contract is already initialized
error AlreadyInitialized();
/// Sender is not a liquidator
error InvalidLiquidator();
/// Average price must be greater than 0
error InvalidAveragePrice();
/// Token amount must be greater than 0
error InvalidTokenAmount();
/// Invalid USDV amount
error InvalidUsdvAmount();
/// Invalid collateral amount
error InvalidCollateral();
/// Position size must be greater than 0
error InvalidPositionSize();
/// Liquidation state cannot be 0
error InvalidLiquidationState();
/// Token not on whitelist
error TokenNotWhitelisted();
/// Amount out must be greater than 0
error InsufficientAmountOut();
/// Leverage must be greater than `MIN_LEVERAGE`
error InsufficientLeverage();
/// Insufficent pool amount
error InsufficientPoolAmount();
/// Insufficient reserves
error InsufficientReserve();
/// Swaps are not enabled
error SwapDisabled();
/// Leverage is not enabled
error LeverageDisabled();
/// Token in and token out cannot be the same
error SameToken();
/// Transaction gas price is greater than max gas price
error InvalidGasPrice();
/// Sender is not a valid manager
error InvalidManager();
/// Sender is not the owner
error InvalidOwner();
/// Sender is not a valid router
error InvalidRouter();
/// Max global short size will be exceeded
error MaxShortsExceeded();

/// @title Vaporwave Vault
contract Vault is ReentrancyGuard, IVault {
    using SafeERC20 for IERC20;

    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;
    uint256 public constant PRICE_PRECISION = 1e30;
    uint256 public constant MIN_LEVERAGE = 10000; // 1x
    uint256 public constant USDV_DECIMALS = 18;
    uint256 public constant MAX_FEE_BASIS_POINTS = 500; // 5%
    uint256 public constant MAX_LIQUIDATION_FEE_USD = 100 * PRICE_PRECISION; // 100 USD
    uint256 public constant MIN_FUNDING_RATE_INTERVAL = 1 hours;
    uint256 public constant MAX_FUNDING_RATE_FACTOR = 10000; // 1%

    bool public override isInitialized;
    bool public override isSwapEnabled = true;
    bool public override isLeverageEnabled = true;

    IVaultUtils public vaultUtils;

    address public errorController;

    address public override router;
    address public override priceFeed;

    address public override usdv;
    address public override owner;

    uint256 public override whitelistedTokenCount; // TODO change to counter

    uint256 public override maxLeverage = 50 * 10000; // 50x

    uint256 public override liquidationFeeUsd;
    uint256 public override taxBasisPoints = 50; // 0.5%
    uint256 public override stableTaxBasisPoints = 20; // 0.2%
    uint256 public override mintBurnFeeBasisPoints = 30; // 0.3%
    uint256 public override swapFeeBasisPoints = 30; // 0.3%
    uint256 public override stableSwapFeeBasisPoints = 4; // 0.04%
    uint256 public override marginFeeBasisPoints = 10; // 0.1%

    uint256 public override minProfitTime;
    bool public override hasDynamicFees = false;

    uint256 public override fundingInterval = 8 hours;
    uint256 public override fundingRateFactor;
    uint256 public override stableFundingRateFactor;
    uint256 public override totalTokenWeights;

    bool public includeAmmPrice = true;
    bool public useSwapPricing = false;

    bool public override inManagerMode = false;
    bool public override inPrivateLiquidationMode = false;

    uint256 public override maxGasPrice;

    mapping(address => mapping(address => bool))
        public
        override approvedRouters;
    mapping(address => bool) public override isLiquidator;
    mapping(address => bool) public override isManager;

    address[] public override allWhitelistedTokens;

    mapping(address => bool) public override whitelistedTokens;
    mapping(address => uint256) public override tokenDecimals;
    mapping(address => uint256) public override minProfitBasisPoints;
    mapping(address => bool) public override stableTokens;
    mapping(address => bool) public override shortableTokens;

    // tokenBalances is used only to determine _transferIn values
    mapping(address => uint256) public override tokenBalances;

    // tokenWeights allows customisation of index composition
    mapping(address => uint256) public override tokenWeights;

    // usdvAmounts tracks the amount of USDV debt for each whitelisted token
    mapping(address => uint256) public override usdvAmounts;

    // maxUsdvAmounts allows setting a max amount of USDV debt for a token
    mapping(address => uint256) public override maxUsdvAmounts;

    // poolAmounts tracks the number of received tokens that can be used for leverage
    // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
    mapping(address => uint256) public override poolAmounts;

    // reservedAmounts tracks the number of tokens reserved for open leverage positions
    mapping(address => uint256) public override reservedAmounts;

    // bufferAmounts allows specification of an amount to exclude from swaps
    // this can be used to ensure a certain amount of liquidity is available for leverage positions
    mapping(address => uint256) public override bufferAmounts;

    // guaranteedUsd tracks the amount of USD that is "guaranteed" by opened leverage positions
    // this value is used to calculate the redemption values for selling of USDV
    // this is an estimated amount, it is possible for the actual guaranteed value to be lower
    // in the case of sudden price decreases, the guaranteed value should be corrected
    // after liquidations are carried out
    mapping(address => uint256) public override guaranteedUsd;

    // cumulativeFundingRates tracks the funding rates based on utilization
    mapping(address => uint256) public override cumulativeFundingRates;
    // lastFundingTimes tracks the last time funding was updated for a token
    mapping(address => uint256) public override lastFundingTimes;

    // positions tracks all open positions
    mapping(bytes32 => Position) public positions;

    // feeReserves tracks the amount of fees per token
    mapping(address => uint256) public override feeReserves;

    mapping(address => uint256) public override globalShortSizes;
    mapping(address => uint256) public override globalShortAveragePrices;
    mapping(address => uint256) public override maxGlobalShortSizes;

    event BuyUSDV(
        address account,
        address token,
        uint256 tokenAmount,
        uint256 usdvAmount,
        uint256 feeBasisPoints
    );
    event SellUSDV(
        address account,
        address token,
        uint256 usdvAmount,
        uint256 tokenAmount,
        uint256 feeBasisPoints
    );
    event Swap(
        address account,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountOutAfterFees,
        uint256 feeBasisPoints
    );

    event IncreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event DecreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event LiquidatePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event UpdatePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event ClosePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl
    );

    event UpdateFundingRate(address token, uint256 fundingRate);
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);

    event CollectSwapFees(address token, uint256 feeUsd, uint256 feeTokens);
    event CollectMarginFees(address token, uint256 feeUsd, uint256 feeTokens);

    event DirectPoolDeposit(address token, uint256 amount);
    event IncreasePoolAmount(address token, uint256 amount);
    event DecreasePoolAmount(address token, uint256 amount);
    event IncreaseUsdvAmount(address token, uint256 amount);
    event DecreaseUsdvAmount(address token, uint256 amount);
    event IncreaseReservedAmount(address token, uint256 amount);
    event DecreaseReservedAmount(address token, uint256 amount);
    event IncreaseGuaranteedUsd(address token, uint256 amount);
    event DecreaseGuaranteedUsd(address token, uint256 amount);

    // once the parameters are verified to be working correctly,
    // gov should be set to a timelock contract or a governance contract
    constructor() {
        owner = msg.sender;
    }

    /// @notice Initialize the contract
    /// @param _router The address of the router contract
    /// @param _usdv The address of the USDV contract
    /// @param _priceFeed The address of the price feed contract
    /// @param _liquidationFeeUsd The fee charged for liquidation
    /// @param _fundingRateFactor The factor used to calculate the funding rate
    /// @param _stableFundingRateFactor The stable funding rate factor
    function initialize(
        address _router,
        address _usdv,
        address _priceFeed,
        uint256 _liquidationFeeUsd,
        uint256 _fundingRateFactor,
        uint256 _stableFundingRateFactor
    ) external {
        _onlyOwner();
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        isInitialized = true;

        router = _router;
        usdv = _usdv;
        priceFeed = _priceFeed;
        liquidationFeeUsd = _liquidationFeeUsd;
        fundingRateFactor = _fundingRateFactor;
        stableFundingRateFactor = _stableFundingRateFactor;
    }

    /// @notice Set the vault utils contract
    /// @dev Can only be called by the contract governor
    /// @param _vaultUtils The vault utils contract
    function setVaultUtils(IVaultUtils _vaultUtils) external override {
        _onlyOwner();
        vaultUtils = _vaultUtils;
    }

    /// @notice Toggle manager mode
    /// @dev Can only be called by the contract governor
    function setInManagerMode(bool _inManagerMode) external override {
        _onlyOwner();
        inManagerMode = _inManagerMode;
    }

    /// @notice Set a manager address
    /// @dev Can only be called by the contract governor
    /// @param _manager Address to be added or removed from the manager list
    /// @param _isManager True if the address should be added to the manager list, false if it should be removed
    function setManager(address _manager, bool _isManager) external override {
        _onlyOwner();
        isManager[_manager] = _isManager;
    }

    /// @notice Toggle private liquidation mode
    /// @dev Can only be called by the contract governor
    /// @param _inPrivateLiquidationMode True if the contract should be in private liquidation mode, false otherwise
    function setInPrivateLiquidationMode(bool _inPrivateLiquidationMode)
        external
        override
    {
        _onlyOwner();
        inPrivateLiquidationMode = _inPrivateLiquidationMode;
    }

    /// @notice Set a liquidator address
    /// @dev Can only be called by the contract governor
    /// @param _liquidator Address to be added or removed from the liquidator list
    /// @param _isActive True if the address should be added to the liquidator list, false if it should be removed
    function setLiquidator(address _liquidator, bool _isActive)
        external
        override
    {
        _onlyOwner();
        isLiquidator[_liquidator] = _isActive;
    }

    /// @notice Toggle swap enabled
    /// @dev Can only be called by the contract governor
    /// @param _isSwapEnabled True if the contract should be in swap enabled mode, false otherwise
    function setIsSwapEnabled(bool _isSwapEnabled) external override {
        _onlyOwner();
        isSwapEnabled = _isSwapEnabled;
    }

    /// @notice Enable or disable `_isLeverageEnabled` leverage
    /// @param _isLeverageEnabled Whether to enable or disable leverage
    function setIsLeverageEnabled(bool _isLeverageEnabled) external override {
        _onlyOwner();
        isLeverageEnabled = _isLeverageEnabled;
    }

    /// @notice Set the max gas price
    /// @param _maxGasPrice The max gas price
    function setMaxGasPrice(uint256 _maxGasPrice) external override {
        _onlyOwner();
        maxGasPrice = _maxGasPrice;
    }

    /// @notice Set the price feed address
    /// @param _priceFeed The address of the price feed
    function setPriceFeed(address _priceFeed) external override {
        _onlyOwner();
        priceFeed = _priceFeed;
    }

    /// @notice Set the maximum leverage
    /// @param _maxLeverage The maximum leverage
    function setMaxLeverage(uint256 _maxLeverage) external override {
        _onlyOwner();
        if (_maxLeverage <= MIN_LEVERAGE) {
            // Question: should this be <= or <?
            revert InsufficientLeverage();
        }
        maxLeverage = _maxLeverage;
    }

    /// @notice Set the buffer amount
    /// @param _token The token to set the buffer amount for
    /// @param _amount The buffer amount to set
    function setBufferAmount(address _token, uint256 _amount)
        external
        override
    {
        _onlyOwner();
        bufferAmounts[_token] = _amount;
    }

    /// @notice Set Max Global Short Size
    /// @dev Called by the governor (timelock contract)
    /// @param _token The token to set the max short size for
    /// @param _amount The max short size for the token
    function setMaxGlobalShortSize(address _token, uint256 _amount)
        external
        override
    {
        _onlyOwner();
        maxGlobalShortSizes[_token] = _amount;
    }

    /// @notice Set Fees
    function setFees(
        uint256 _taxBasisPoints,
        uint256 _stableTaxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _swapFeeBasisPoints,
        uint256 _stableSwapFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime,
        bool _hasDynamicFees
    ) external override {
        _onlyOwner();
        require(
            _taxBasisPoints <= MAX_FEE_BASIS_POINTS &&
                _stableTaxBasisPoints <= MAX_FEE_BASIS_POINTS &&
                _mintBurnFeeBasisPoints <= MAX_FEE_BASIS_POINTS &&
                _swapFeeBasisPoints <= MAX_FEE_BASIS_POINTS &&
                _stableSwapFeeBasisPoints <= MAX_FEE_BASIS_POINTS &&
                _marginFeeBasisPoints <= MAX_FEE_BASIS_POINTS &&
                _liquidationFeeUsd <= MAX_FEE_BASIS_POINTS &&
                _minProfitTime <= MAX_FEE_BASIS_POINTS
        );
        taxBasisPoints = _taxBasisPoints;
        stableTaxBasisPoints = _stableTaxBasisPoints;
        mintBurnFeeBasisPoints = _mintBurnFeeBasisPoints;
        swapFeeBasisPoints = _swapFeeBasisPoints;
        stableSwapFeeBasisPoints = _stableSwapFeeBasisPoints;
        marginFeeBasisPoints = _marginFeeBasisPoints;
        liquidationFeeUsd = _liquidationFeeUsd;
        minProfitTime = _minProfitTime;
        hasDynamicFees = _hasDynamicFees;
    }

    /// @notice Set the funding rate
    /// @param _fundingInterval The funding interval
    /// @param _fundingRateFactor The funding rate factor
    /// @param _stableFundingRateFactor The stable funding rate factor
    function setFundingRate(
        uint256 _fundingInterval,
        uint256 _fundingRateFactor,
        uint256 _stableFundingRateFactor
    ) external override {
        _onlyOwner();
        require(
            _fundingInterval >= MIN_FUNDING_RATE_INTERVAL &&
                _fundingRateFactor <= MAX_FUNDING_RATE_FACTOR &&
                _stableFundingRateFactor <= MAX_FUNDING_RATE_FACTOR
        );

        fundingInterval = _fundingInterval;
        fundingRateFactor = _fundingRateFactor;
        stableFundingRateFactor = _stableFundingRateFactor;
    }

    /// @notice Set Token Configuration
    function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _tokenWeight,
        uint256 _minProfitBps,
        uint256 _maxUsdvAmount,
        bool _isStable,
        bool _isShortable
    ) external override {
        _onlyOwner();
        // increment token count for the first time
        if (!whitelistedTokens[_token]) {
            whitelistedTokenCount = whitelistedTokenCount++;
            allWhitelistedTokens.push(_token);
        }

        uint256 _totalTokenWeights = totalTokenWeights;
        _totalTokenWeights = _totalTokenWeights - tokenWeights[_token];

        whitelistedTokens[_token] = true;
        tokenDecimals[_token] = _tokenDecimals;
        tokenWeights[_token] = _tokenWeight;
        minProfitBasisPoints[_token] = _minProfitBps;
        maxUsdvAmounts[_token] = _maxUsdvAmount;
        stableTokens[_token] = _isStable;
        shortableTokens[_token] = _isShortable;

        totalTokenWeights = _totalTokenWeights + _tokenWeight;

        // validate price feed
        getMaxPrice(_token);
    }

    function clearTokenConfig(address _token) external {
        _onlyOwner();
        if (!whitelistedTokens[_token]) {
            revert TokenNotWhitelisted();
        }
        totalTokenWeights = totalTokenWeights - tokenWeights[_token];
        delete whitelistedTokens[_token];
        delete tokenDecimals[_token];
        delete tokenWeights[_token];
        delete minProfitBasisPoints[_token];
        delete maxUsdvAmounts[_token];
        delete stableTokens[_token];
        delete shortableTokens[_token];
        whitelistedTokenCount = whitelistedTokenCount--;
    }

    /// @notice Withdraw fees
    /// @param _token The token to withdraw
    /// @param _receiver The address to receive the fees
    /// @return The amount of fees transferred out
    function withdrawFees(address _token, address _receiver)
        external
        override
        returns (uint256)
    {
        _onlyOwner();
        uint256 amount = feeReserves[_token];
        if (amount == 0) {
            return 0;
        }
        feeReserves[_token] = 0;
        _transferOut(_token, amount, _receiver);
        return amount;
    }

    /// @notice Add `_router` as a router
    /// @param _router The address to add as a router
    function addRouter(address _router) external {
        approvedRouters[msg.sender][_router] = true;
    }

    /// @notice Remove `_router` as a router
    /// @param _router the address to remove as a router
    function removeRouter(address _router) external {
        approvedRouters[msg.sender][_router] = false;
    }

    /// @notice Set the USDV amount for `_token`
    /// @param _token The token to set
    /// @param _amount The amount to add or subtract from the token's usdvAmount
    function setUsdvAmount(address _token, uint256 _amount) external override {
        _onlyOwner();
        uint256 usdvAmount = usdvAmounts[_token];
        if (_amount > usdvAmount) {
            _increaseUsdvAmount(_token, _amount - usdvAmount);
            return;
        }

        _decreaseUsdvAmount(_token, usdvAmount - _amount);
    }

    // NOTE: discussion for function removal - timelock necessary
    /// @notice Upgrade the vault (Transfer tokens to a new vault)
    /// @dev The governance controlling this function should have a timelock
    /// @param _newVault The new vault contract address
    /// @param _token The token to transfer to the new vault
    /// @param _amount The amount of tokens to transfer to the new vault
    function upgradeVault(
        address _newVault,
        address _token,
        uint256 _amount
    ) external {
        _onlyOwner();
        IERC20(_token).safeTransfer(_newVault, _amount);
    }

    /// @notice Deposit `_token` directly to the pool
    /// @dev deposit into the pool without minting USDV tokens - useful in allowing the pool to become over-collaterised
    /// @dev Emits an event `DirectPoolDeposit`
    /// @param _token The token to deposit into the pool
    function directPoolDeposit(address _token) external override nonReentrant {
        if (!whitelistedTokens[_token]) {
            revert TokenNotWhitelisted();
        }
        uint256 tokenAmount = _transferIn(_token);
        if (tokenAmount == 0) {
            revert InvalidTokenAmount();
        }
        _increasePoolAmount(_token, tokenAmount);
        emit DirectPoolDeposit(_token, tokenAmount);
    }

    /// @notice Buy USDV tokens
    /// @dev Emits an event `BuyUSDV`
    /// @param _token The token used to buy USDV -- token must be whitelisted
    /// @param _receiver The receiver of the USDV tokens
    function buyUSDV(address _token, address _receiver)
        external
        override
        nonReentrant
        returns (uint256)
    {
        _validateManager();
        if (!whitelistedTokens[_token]) {
            revert TokenNotWhitelisted();
        }
        useSwapPricing = true;

        uint256 tokenAmount = _transferIn(_token);
        if (tokenAmount == 0) {
            revert InvalidTokenAmount();
        }

        updateCumulativeFundingRate(_token, _token);

        uint256 price = getMinPrice(_token);

        uint256 usdvAmount = (tokenAmount * price) / PRICE_PRECISION;
        usdvAmount = adjustForDecimals(usdvAmount, _token, usdv);
        if (usdvAmount == 0) {
            revert InvalidUsdvAmount();
        }

        uint256 feeBasisPoints = vaultUtils.getBuyUsdvFeeBasisPoints(
            _token,
            usdvAmount
        );
        uint256 amountAfterFees = _collectSwapFees(
            _token,
            tokenAmount,
            feeBasisPoints
        );
        uint256 mintAmount = (amountAfterFees * price) / PRICE_PRECISION;
        mintAmount = adjustForDecimals(mintAmount, _token, usdv);

        _increaseUsdvAmount(_token, mintAmount);
        _increasePoolAmount(_token, amountAfterFees);

        IUSDV(usdv).mint(_receiver, mintAmount);

        emit BuyUSDV(
            _receiver,
            _token,
            tokenAmount,
            mintAmount,
            feeBasisPoints
        );

        useSwapPricing = false;
        return mintAmount;
    }

    /// @notice Sell USDV tokens
    /// @dev Emits an event `SellUSDV`
    /// @param _token The token to sell USDV for -- token must be whitelisted
    /// @param _receiver The receiver of the tokens
    function sellUSDV(address _token, address _receiver)
        external
        override
        nonReentrant
        returns (uint256)
    {
        _validateManager();
        if (!whitelistedTokens[_token]) {
            revert TokenNotWhitelisted();
        }
        useSwapPricing = true;

        uint256 usdvAmount = _transferIn(usdv);
        if (usdvAmount == 0) {
            revert InvalidUsdvAmount();
        }

        updateCumulativeFundingRate(_token, _token);

        uint256 redemptionAmount = getRedemptionAmount(_token, usdvAmount);
        if (redemptionAmount == 0) {
            revert InvalidTokenAmount();
        }

        _decreaseUsdvAmount(_token, usdvAmount);
        _decreasePoolAmount(_token, redemptionAmount);

        IUSDV(usdv).burn(address(this), usdvAmount);

        // the _transferIn call increased the value of tokenBalances[usdv]
        // usually decreases in token balances are synced by calling _transferOut
        // however, for usdv, the tokens are burnt, so _updateTokenBalance should
        // be manually called to record the decrease in tokens
        _updateTokenBalance(usdv);

        uint256 feeBasisPoints = vaultUtils.getSellUsdvFeeBasisPoints(
            _token,
            usdvAmount
        );
        uint256 amountOut = _collectSwapFees(
            _token,
            redemptionAmount,
            feeBasisPoints
        );
        if (amountOut == 0) {
            revert InsufficientAmountOut();
        }

        _transferOut(_token, amountOut, _receiver);

        emit SellUSDV(_receiver, _token, usdvAmount, amountOut, feeBasisPoints);

        useSwapPricing = false;
        return amountOut;
    }

    /// @notice Swap `_tokenIn` for `_tokenOut`
    /// @dev Emit an event `Swap`
    /// @param _tokenIn The token to swap in
    /// @param _tokenOut The token to swap out
    /// @param _receiver The receiver of the tokens
    function swap(
        address _tokenIn,
        address _tokenOut,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        if (!isSwapEnabled) {
            revert SwapDisabled();
        }
        if (!whitelistedTokens[_tokenIn] || !whitelistedTokens[_tokenOut]) {
            revert TokenNotWhitelisted();
        }
        if (_tokenIn == _tokenOut) {
            revert SameToken();
        }

        useSwapPricing = true;

        updateCumulativeFundingRate(_tokenIn, _tokenIn);
        updateCumulativeFundingRate(_tokenOut, _tokenOut);

        uint256 amountIn = _transferIn(_tokenIn);
        if (amountIn == 0) {
            revert InvalidTokenAmount();
        }

        uint256 priceIn = getMinPrice(_tokenIn);
        uint256 priceOut = getMaxPrice(_tokenOut);

        uint256 amountOut = (amountIn * priceIn) / priceOut;
        amountOut = adjustForDecimals(amountOut, _tokenIn, _tokenOut);

        // adjust usdvAmounts by the same usdvAmount as debt is shifted between the assets
        uint256 usdvAmount = (amountIn * priceIn) / PRICE_PRECISION;
        usdvAmount = adjustForDecimals(usdvAmount, _tokenIn, usdv);

        uint256 feeBasisPoints = vaultUtils.getSwapFeeBasisPoints(
            _tokenIn,
            _tokenOut,
            usdvAmount
        );
        uint256 amountOutAfterFees = _collectSwapFees(
            _tokenOut,
            amountOut,
            feeBasisPoints
        );

        _increaseUsdvAmount(_tokenIn, usdvAmount);
        _decreaseUsdvAmount(_tokenOut, usdvAmount);

        _increasePoolAmount(_tokenIn, amountIn);
        _decreasePoolAmount(_tokenOut, amountOut);

        _validateBufferAmount(_tokenOut);

        _transferOut(_tokenOut, amountOutAfterFees, _receiver);

        emit Swap(
            _receiver,
            _tokenIn,
            _tokenOut,
            amountIn,
            amountOut,
            amountOutAfterFees,
            feeBasisPoints
        );

        useSwapPricing = false;
        return amountOutAfterFees;
    }

    /// @notice Increase position
    /// @dev Emits a `IncreasePosition` event
    /// @dev Emits a `UpdatePosition` event
    function increasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external override nonReentrant {
        if (!isLeverageEnabled) {
            revert LeverageDisabled();
        }
        _validateGasPrice();
        _validateRouter(_account);
        _validateTokens(_collateralToken, _indexToken, _isLong);
        vaultUtils.validateIncreasePosition(
            _account,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong
        );

        updateCumulativeFundingRate(_collateralToken, _indexToken);

        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        Position storage position = positions[key];

        uint256 price = _isLong
            ? getMaxPrice(_indexToken)
            : getMinPrice(_indexToken);

        if (position.size == 0) {
            position.averagePrice = price;
        }

        if (position.size > 0 && _sizeDelta > 0) {
            position.averagePrice = getNextAveragePrice(
                _indexToken,
                position.size,
                position.averagePrice,
                _isLong,
                price,
                _sizeDelta,
                position.lastIncreasedTime
            );
        }

        uint256 fee = _collectMarginFees(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _sizeDelta,
            position.size,
            position.entryFundingRate
        );
        uint256 collateralDelta = _transferIn(_collateralToken);
        uint256 collateralDeltaUsd = tokenToUsdMin(
            _collateralToken,
            collateralDelta
        );

        position.collateral += collateralDeltaUsd;
        if (position.collateral < fee) {
            revert InvalidCollateral();
        }

        position.collateral -= fee;
        position.entryFundingRate = getEntryFundingRate(
            _collateralToken,
            _indexToken,
            _isLong
        );
        position.size += _sizeDelta;
        position.lastIncreasedTime = block.timestamp;
        if (position.size == 0) {
            revert InvalidPositionSize();
        }
        _validatePosition(position.size, position.collateral);
        validateLiquidation(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            true
        );

        // reserve tokens to pay profits on the position
        uint256 reserveDelta = usdToTokenMax(_collateralToken, _sizeDelta);
        position.reserveAmount += reserveDelta;
        _increaseReservedAmount(_collateralToken, reserveDelta);

        if (_isLong) {
            // guaranteedUsd stores the sum of (position.size - position.collateral) for all positions
            // if a fee is charged on the collateral then guaranteedUsd should be increased by that fee amount
            // since (position.size - position.collateral) would have increased by `fee`
            _increaseGuaranteedUsd(_collateralToken, _sizeDelta + fee);
            _decreaseGuaranteedUsd(_collateralToken, collateralDeltaUsd);
            // treat the deposited collateral as part of the pool
            _increasePoolAmount(_collateralToken, collateralDelta);
            // fees need to be deducted from the pool since fees are deducted from position.collateral
            // and collateral is treated as part of the pool
            _decreasePoolAmount(
                _collateralToken,
                usdToTokenMin(_collateralToken, fee)
            );
        } else {
            if (globalShortSizes[_indexToken] == 0) {
                globalShortAveragePrices[_indexToken] = price;
            } else {
                globalShortAveragePrices[
                    _indexToken
                ] = getNextGlobalShortAveragePrice(
                    _indexToken,
                    price,
                    _sizeDelta
                );
            }

            _increaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        emit IncreasePosition(
            key,
            _account,
            _collateralToken,
            _indexToken,
            collateralDeltaUsd,
            _sizeDelta,
            _isLong,
            price,
            fee
        );
        emit UpdatePosition(
            key,
            position.size,
            position.collateral,
            position.averagePrice,
            position.entryFundingRate,
            position.reserveAmount,
            position.realisedPnl,
            price
        );
    }

    function decreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateGasPrice();
        _validateRouter(_account);
        return
            _decreasePosition(
                _account,
                _collateralToken,
                _indexToken,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                _receiver
            );
    }

    /// @dev Emits a `CollectMarginFees` event
    /// @dev Emits a `LiquidatePosition` event
    function liquidatePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        address _feeReceiver
    ) external override nonReentrant {
        if (inPrivateLiquidationMode) {
            if (!isLiquidator[msg.sender]) {
                revert InvalidLiquidator();
            }
        }

        // set includeAmmPrice to false to prevent manipulated liquidations
        includeAmmPrice = false;

        updateCumulativeFundingRate(_collateralToken, _indexToken);

        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        Position memory position = positions[key];
        if (position.size == 0) {
            revert InvalidPositionSize();
        }

        (uint256 liquidationState, uint256 marginFees) = validateLiquidation(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            false
        );
        if (liquidationState == 0) {
            revert InvalidLiquidationState();
        }
        if (liquidationState == 2) {
            // max leverage exceeded but there is collateral remaining after deducting losses so decreasePosition instead
            _decreasePosition(
                _account,
                _collateralToken,
                _indexToken,
                0,
                position.size,
                _isLong,
                _account
            );
            includeAmmPrice = true;
            return;
        }

        uint256 feeTokens = usdToTokenMin(_collateralToken, marginFees);
        feeReserves[_collateralToken] += feeTokens;
        emit CollectMarginFees(_collateralToken, marginFees, feeTokens);

        _decreaseReservedAmount(_collateralToken, position.reserveAmount);
        if (_isLong) {
            _decreaseGuaranteedUsd(
                _collateralToken,
                position.size - position.collateral
            );
            _decreasePoolAmount(
                _collateralToken,
                usdToTokenMin(_collateralToken, marginFees)
            );
        }

        uint256 markPrice = _isLong
            ? getMinPrice(_indexToken)
            : getMaxPrice(_indexToken);
        emit LiquidatePosition(
            key,
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            position.size,
            position.collateral,
            position.reserveAmount,
            position.realisedPnl,
            markPrice
        );

        if (!_isLong && marginFees < position.collateral) {
            uint256 remainingCollateral = position.collateral - marginFees;
            _increasePoolAmount(
                _collateralToken,
                usdToTokenMin(_collateralToken, remainingCollateral)
            );
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, position.size);
        }

        delete positions[key];

        // pay the fee receiver using the pool, we assume that in general the liquidated amount should be sufficient to cover
        // the liquidation fees
        _decreasePoolAmount(
            _collateralToken,
            usdToTokenMin(_collateralToken, liquidationFeeUsd)
        );
        _transferOut(
            _collateralToken,
            usdToTokenMin(_collateralToken, liquidationFeeUsd),
            _feeReceiver
        );

        includeAmmPrice = true;
    }

    /// @notice Get the number of whitelisted tokens
    /// @return The length of the allWhiteListedtokens array
    function allWhitelistedTokensLength()
        external
        view
        override
        returns (uint256)
    {
        return allWhitelistedTokens.length;
    }

    /// @notice Update the cumulative funding rate
    /// @dev Emits an `UpdateFundingRate` event
    /// @param _collateralToken The collateral token
    /// @param _indexToken The address of the token to long or short
    function updateCumulativeFundingRate(
        address _collateralToken,
        address _indexToken
    ) public {
        bool shouldUpdate = vaultUtils.updateCumulativeFundingRate(
            _collateralToken,
            _indexToken
        );
        if (!shouldUpdate) {
            return;
        }

        if (lastFundingTimes[_collateralToken] == 0) {
            lastFundingTimes[_collateralToken] =
                (block.timestamp / fundingInterval) *
                fundingInterval;
            return;
        }

        if (
            lastFundingTimes[_collateralToken] + fundingInterval >
            block.timestamp
        ) {
            return;
        }

        uint256 fundingRate = getNextFundingRate(_collateralToken);
        cumulativeFundingRates[_collateralToken] += fundingRate;
        lastFundingTimes[_collateralToken] =
            (block.timestamp / fundingInterval) *
            fundingInterval;

        emit UpdateFundingRate(
            _collateralToken,
            cumulativeFundingRates[_collateralToken]
        );
    }

    /// @notice Validate a liquidation
    // validateLiquidation returns (state, fees)
    function validateLiquidation(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        bool _raise
    ) public view returns (uint256, uint256) {
        return
            vaultUtils.validateLiquidation(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                _raise
            );
    }

    /// @notice Get the max price for `_token`
    /// @param _token The token address to query for the price
    /// @return The max price for the token
    function getMaxPrice(address _token)
        public
        view
        override
        returns (uint256)
    {
        return
            IVaultPriceFeed(priceFeed).getPrice(
                _token,
                true,
                includeAmmPrice,
                useSwapPricing
            );
    }

    /// @notice Get the min price for `_token`
    /// @param _token The token address to query for the price
    /// @return The min price for the token
    function getMinPrice(address _token)
        public
        view
        override
        returns (uint256)
    {
        return
            IVaultPriceFeed(priceFeed).getPrice(
                _token,
                false,
                includeAmmPrice,
                useSwapPricing
            );
    }

    /// @notice Get the redemption amount for `_token`
    /// @param _token The token address to query for the redemption amount
    /// @param _usdvAmount The USDV amount
    /// @return The redemption amount for the token in USDV
    function getRedemptionAmount(address _token, uint256 _usdvAmount)
        public
        view
        override
        returns (uint256)
    {
        uint256 price = getMaxPrice(_token);
        uint256 redemptionAmount = (_usdvAmount * PRICE_PRECISION) / price;
        return adjustForDecimals(redemptionAmount, usdv, _token);
    }

    /// @notice Get the redemption collateral for `_token`
    /// @param _token The token address to query
    /// @return The redemption collateral amount
    function getRedemptionCollateral(address _token)
        public
        view
        returns (uint256)
    {
        if (stableTokens[_token]) {
            return poolAmounts[_token];
        }
        uint256 collateral = usdToTokenMin(_token, guaranteedUsd[_token]);
        return collateral + poolAmounts[_token] - reservedAmounts[_token];
    }

    /// @notice Get the redemption collateral for `_token` in USD
    /// @param _token The token address to query
    /// @return The redemption collateral amount in USD
    function getRedemptionCollateralUsd(address _token)
        public
        view
        returns (uint256)
    {
        return tokenToUsdMin(_token, getRedemptionCollateral(_token));
    }

    /// @notice Adjust the amount for the tokens' decimals
    /// @param _amount Token amount to be adjusted
    /// @param _tokenDiv The divisor
    /// @param _tokenMul The multiplier
    /// @return The token amount adjusted for decimals
    function adjustForDecimals(
        uint256 _amount,
        address _tokenDiv,
        address _tokenMul
    ) public view returns (uint256) {
        uint256 decimalsDiv = _tokenDiv == usdv
            ? USDV_DECIMALS
            : tokenDecimals[_tokenDiv];
        uint256 decimalsMul = _tokenMul == usdv
            ? USDV_DECIMALS
            : tokenDecimals[_tokenMul];
        return (_amount * (10**decimalsMul)) / (10**decimalsDiv);
    }

    /// @notice Get the minimum price for `_tokenAmount` of `_token` in USD
    /// @param _token The token address to query for the minimum price
    /// @param _tokenAmount The token amount
    /// @return The token amount converted to USD value using the minimum price
    function tokenToUsdMin(address _token, uint256 _tokenAmount)
        public
        view
        override
        returns (uint256)
    {
        if (_tokenAmount == 0) {
            return 0;
        }
        uint256 price = getMinPrice(_token);
        uint256 decimals = tokenDecimals[_token];
        return (_tokenAmount * price) / (10**decimals);
    }

    /// @notice Get the max token amount for `_usdAmount` USD of `_token`
    /// @param _token The token addres to query for the maximum price
    /// @param _usdAmount The USD amount
    /// @return The max amount of tokens for the given USD amount
    function usdToTokenMax(address _token, uint256 _usdAmount)
        public
        view
        returns (uint256)
    {
        if (_usdAmount == 0) {
            return 0;
        }
        return usdToToken(_token, _usdAmount, getMinPrice(_token));
    }

    /// @notice Get the minimum token amount for `_usdAmount` USD of `_token`
    /// @param _token The token addres to query for the minimum price
    /// @param _usdAmount The USD amount
    /// @return The minimum amount of tokens for the given USD amount
    function usdToTokenMin(address _token, uint256 _usdAmount)
        public
        view
        returns (uint256)
    {
        if (_usdAmount == 0) {
            return 0;
        }
        return usdToToken(_token, _usdAmount, getMaxPrice(_token));
    }

    /// @notice Get the token amount for `_usdAmount` USD of `_token` at `_price` USD per token
    /// @param _token The token address
    /// @param _usdAmount The USD amount
    /// @param _price The USD price per token
    /// @return The token amount
    function usdToToken(
        address _token,
        uint256 _usdAmount,
        uint256 _price
    ) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        uint256 decimals = tokenDecimals[_token];
        return (_usdAmount * (10**decimals)) / _price;
    }

    /// @notice Get a position
    /// @param _account The account associated with the position
    /// @param _collateralToken The collateral token
    /// @param _indexToken The address of the token to long or short
    /// @param _isLong True if the position is long, false if the position is short
    function getPosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    )
        public
        view
        override
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            bool,
            uint256
        )
    {
        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        Position memory position = positions[key];
        uint256 realisedPnl = position.realisedPnl > 0
            ? uint256(position.realisedPnl)
            : uint256(-position.realisedPnl);
        return (
            position.size, // 0
            position.collateral, // 1
            position.averagePrice, // 2
            position.entryFundingRate, // 3
            position.reserveAmount, // 4
            realisedPnl, // 5
            position.realisedPnl >= 0, // 6
            position.lastIncreasedTime // 7
        );
    }

    /// @notice Get a position leverage
    /// @param _account The account associated with the position
    /// @param _collateralToken The collateral token
    /// @param _indexToken The address of the token to long or short
    /// @param _isLong True if the position is long, false if the position is short
    function getPositionLeverage(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public view returns (uint256) {
        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        Position memory position = positions[key];
        if (position.collateral == 0) {
            revert InvalidCollateral();
        }
        return (position.size * BASIS_POINTS_DIVISOR) / position.collateral;
    }

    /// @notice Get a position delta
    /// @param _account The account associated with the position
    /// @param _collateralToken The collateral token
    /// @param _indexToken The address of the token to long or short
    /// @param _isLong True if the position is long, false if the position is short
    /// @return The position delta
    function getPositionDelta(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public view returns (bool, uint256) {
        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        Position memory position = positions[key];
        return
            getDelta(
                _indexToken,
                position.size,
                position.averagePrice,
                _isLong,
                position.lastIncreasedTime
            );
    }

    /// @notice Get the next funding rate
    /// @param _token The token address
    /// @return The next funding rate
    function getNextFundingRate(address _token)
        public
        view
        override
        returns (uint256)
    {
        if (lastFundingTimes[_token] + fundingInterval > block.timestamp) {
            return 0;
        }

        uint256 intervals = block.timestamp -
            lastFundingTimes[_token] /
            fundingInterval;
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) {
            return 0;
        }

        uint256 _fundingRateFactor = stableTokens[_token]
            ? stableFundingRateFactor
            : fundingRateFactor;
        return
            (_fundingRateFactor * reservedAmounts[_token] * intervals) /
            poolAmount;
    }

    /// @notice Get the token utilisation
    /// @param _token The token address
    /// @return The token utilisation
    function getUtilisation(address _token) public view returns (uint256) {
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) {
            return 0;
        }

        return (reservedAmounts[_token] * FUNDING_RATE_PRECISION) / poolAmount;
    }

    /// @notice Get the next average price
    /// @dev for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    /// @dev for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    /// @param _indexToken The address of the token to long or short
    /// @param _size The position size
    /// @param _averagePrice The average price
    /// @param _isLong True if the position is long, false if the position is short
    /// @param _nextPrice The next price
    /// @param _sizeDelta The change in the position size
    /// @param _lastIncreasedTime The time of the last increase
    /// @return The next average price
    function getNextAveragePrice(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        uint256 _lastIncreasedTime
    ) public view returns (uint256) {
        (bool hasProfit, uint256 delta) = getDelta(
            _indexToken,
            _size,
            _averagePrice,
            _isLong,
            _lastIncreasedTime
        );
        uint256 nextSize = _size + _sizeDelta;
        uint256 divisor;
        if (_isLong) {
            divisor = hasProfit ? nextSize + delta : nextSize - delta;
        } else {
            divisor = hasProfit ? nextSize - delta : nextSize + delta;
        }
        return (_nextPrice * nextSize) / divisor;
    }

    /// @notice Get the next global short average price
    /// @dev for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    /// @dev for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    /// @param _indexToken The address of the token to long or short
    /// @param _nextPrice The next price
    /// @param _sizeDelta The size delta
    /// @return The next global short average price
    function getNextGlobalShortAveragePrice(
        address _indexToken,
        uint256 _nextPrice,
        uint256 _sizeDelta
    ) public view returns (uint256) {
        uint256 size = globalShortSizes[_indexToken];
        uint256 averagePrice = globalShortAveragePrices[_indexToken];
        uint256 priceDelta = averagePrice > _nextPrice
            ? averagePrice - _nextPrice
            : _nextPrice - averagePrice;
        uint256 delta = (size * priceDelta) / averagePrice;
        bool hasProfit = averagePrice > _nextPrice;

        uint256 nextSize = size + _sizeDelta;
        uint256 divisor = hasProfit ? nextSize - delta : nextSize + delta;

        return (_nextPrice * nextSize) / divisor;
    }

    /// @notice Get the global short delta
    /// @param _token The token address
    /// @return The global short delta
    function getGlobalShortDelta(address _token)
        public
        view
        returns (bool, uint256)
    {
        uint256 size = globalShortSizes[_token];
        if (size == 0) {
            return (false, 0);
        }

        uint256 nextPrice = getMaxPrice(_token);
        uint256 averagePrice = globalShortAveragePrices[_token];
        uint256 priceDelta = averagePrice > nextPrice
            ? averagePrice - nextPrice
            : nextPrice - averagePrice;
        uint256 delta = (size * priceDelta) / averagePrice;
        bool hasProfit = averagePrice > nextPrice;

        return (hasProfit, delta);
    }

    function getDelta(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) public view override returns (bool, uint256) {
        if (_averagePrice == 0) {
            revert InvalidAveragePrice();
        }
        uint256 price = _isLong
            ? getMinPrice(_indexToken)
            : getMaxPrice(_indexToken);
        uint256 priceDelta = _averagePrice > price
            ? _averagePrice - price
            : price - _averagePrice;
        uint256 delta = (_size * priceDelta) / _averagePrice;

        bool hasProfit;

        if (_isLong) {
            hasProfit = price > _averagePrice;
        } else {
            hasProfit = _averagePrice > price;
        }

        // if the minProfitTime has passed then there will be no min profit threshold
        // the min profit threshold helps to prevent front-running issues
        uint256 minBps = block.timestamp > _lastIncreasedTime + minProfitTime
            ? 0
            : minProfitBasisPoints[_indexToken];
        if (hasProfit && delta * BASIS_POINTS_DIVISOR <= _size * minBps) {
            delta = 0;
        }

        return (hasProfit, delta);
    }

    /// @notice Get the entry funding rate
    /// @param _collateralToken The collateral token
    /// @param _indexToken The address of the token to long or short
    /// @param _isLong True if the position is long, false if the position is short
    function getEntryFundingRate(
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public view returns (uint256) {
        return
            vaultUtils.getEntryFundingRate(
                _collateralToken,
                _indexToken,
                _isLong
            );
    }

    /// @notice Get the funding fee
    /// @param _account The address of the account
    /// @param _collateralToken The collateral token
    /// @param _indexToken The address of the token to long or short
    /// @param _isLong True if the position is long, false if the position is short
    /// @param _size The size of the position
    /// @param _entryFundingRate The entry funding rate
    function getFundingFee(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        uint256 _size,
        uint256 _entryFundingRate
    ) public view returns (uint256) {
        return
            vaultUtils.getFundingFee(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                _size,
                _entryFundingRate
            );
    }

    /// @notice Get the position fee
    /// @param _account The address of the account
    /// @param _collateralToken The collateral token
    /// @param _indexToken The address of the token to long or short
    /// @param _isLong True if the position is long, false if the position is short
    /// @param _sizeDelta The change in size of the position
    function getPositionFee(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta
    ) public view returns (uint256) {
        return
            vaultUtils.getPositionFee(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                _sizeDelta
            );
    }

    /*
     * @notice Get the fee basis points
     * @dev cases to consider
     * 1. initialAmount is far from targetAmount, action increases balance slightly => high rebate
     * 2. initialAmount is far from targetAmount, action increases balance largely => high rebate
     * 3. initialAmount is close to targetAmount, action increases balance slightly => low rebate
     * 4. initialAmount is far from targetAmount, action reduces balance slightly => high tax
     * 5. initialAmount is far from targetAmount, action reduces balance largely => high tax
     * 6. initialAmount is close to targetAmount, action reduces balance largely => low tax
     * 7. initialAmount is above targetAmount, nextAmount is below targetAmount and vice versa
     * 8. a large swap should have similar fees as the same trade split into multiple smaller swaps
     */
    function getFeeBasisPoints(
        address _token,
        uint256 _usdvDelta,
        uint256 _feeBasisPoints,
        uint256 _taxBasisPoints,
        bool _increment
    ) public view override returns (uint256) {
        return
            vaultUtils.getFeeBasisPoints(
                _token,
                _usdvDelta,
                _feeBasisPoints,
                _taxBasisPoints,
                _increment
            );
    }

    /// @notice Get the target USDV amount
    /// @param _token The token address
    /// @return The target USDV amount
    function getTargetUsdvAmount(address _token)
        public
        view
        override
        returns (uint256)
    {
        uint256 supply = IERC20(usdv).totalSupply();
        if (supply == 0) {
            return 0;
        }
        uint256 weight = tokenWeights[_token];
        return (weight * supply) / totalTokenWeights;
    }

    /// @notice Get a position key
    /// @dev The position key is deterministically created from the hash of the parameters
    /// @param _account The account associated with the position
    /// @param _collateralToken The collateral token
    /// @param _indexToken The address of the token to long or short
    /// @param _isLong True if the position is long, false if the position is short
    function getPositionKey(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _account,
                    _collateralToken,
                    _indexToken,
                    _isLong
                )
            );
    }

    function _reduceCollateral(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) private returns (uint256, uint256) {
        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        Position storage position = positions[key];

        uint256 fee = _collectMarginFees(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _sizeDelta,
            position.size,
            position.entryFundingRate
        );
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
            (bool _hasProfit, uint256 delta) = getDelta(
                _indexToken,
                position.size,
                position.averagePrice,
                _isLong,
                position.lastIncreasedTime
            );
            hasProfit = _hasProfit;
            // get the proportional change in pnl
            adjustedDelta = (_sizeDelta * delta) / position.size;
        }

        uint256 usdOut;
        // transfer profits out
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);

            // pay out realised profits from the pool amount for short positions
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(
                    _collateralToken,
                    adjustedDelta
                );
                _decreasePoolAmount(_collateralToken, tokenAmount);
            }
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral -= adjustedDelta;

            // transfer realised losses to the pool for short positions
            // realised losses for long positions are not transferred here as
            // _increasePoolAmount was already called in increasePosition for longs
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(
                    _collateralToken,
                    adjustedDelta
                );
                _increasePoolAmount(_collateralToken, tokenAmount);
            }

            position.realisedPnl = position.realisedPnl - int256(adjustedDelta);
        }

        // reduce the position's collateral by _collateralDelta
        // transfer _collateralDelta out
        if (_collateralDelta > 0) {
            usdOut += _collateralDelta;
            position.collateral -= _collateralDelta;
        }

        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == _sizeDelta) {
            usdOut += position.collateral;
            position.collateral = 0;
        }

        // if the usdOut is more than the fee then deduct the fee from the usdOut directly
        // else deduct the fee from the position's collateral
        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut - fee;
        } else {
            position.collateral -= fee;
            if (_isLong) {
                uint256 feeTokens = usdToTokenMin(_collateralToken, fee);
                _decreasePoolAmount(_collateralToken, feeTokens);
            }
        }

        emit UpdatePnl(key, hasProfit, adjustedDelta);

        return (usdOut, usdOutAfterFee);
    }

    function _decreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) private returns (uint256) {
        vaultUtils.validateDecreasePosition(
            _account,
            _collateralToken,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver
        );
        updateCumulativeFundingRate(_collateralToken, _indexToken);

        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        Position storage position = positions[key];
        if (position.size == 0 || position.size < _sizeDelta) {
            revert InvalidPositionSize();
        }
        if (position.collateral < _collateralDelta) {
            revert InvalidCollateral();
        }

        uint256 collateral = position.collateral;
        // scrop variables to avoid stack too deep errors
        {
            uint256 reserveDelta = (position.reserveAmount * _sizeDelta) /
                position.size;
            position.reserveAmount -= reserveDelta;
            _decreaseReservedAmount(_collateralToken, reserveDelta);
        }

        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(
            _account,
            _collateralToken,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong
        );

        if (position.size != _sizeDelta) {
            position.entryFundingRate = getEntryFundingRate(
                _collateralToken,
                _indexToken,
                _isLong
            );
            position.size -= _sizeDelta;

            _validatePosition(position.size, position.collateral);
            validateLiquidation(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                true
            );

            if (_isLong) {
                _increaseGuaranteedUsd(
                    _collateralToken,
                    collateral - position.collateral
                );
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            uint256 price = _isLong
                ? getMinPrice(_indexToken)
                : getMaxPrice(_indexToken);
            emit DecreasePosition(
                key,
                _account,
                _collateralToken,
                _indexToken,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                price,
                usdOut - usdOutAfterFee
            );
            emit UpdatePosition(
                key,
                position.size,
                position.collateral,
                position.averagePrice,
                position.entryFundingRate,
                position.reserveAmount,
                position.realisedPnl,
                price
            );
        } else {
            if (_isLong) {
                _increaseGuaranteedUsd(_collateralToken, collateral);
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            uint256 price = _isLong
                ? getMinPrice(_indexToken)
                : getMaxPrice(_indexToken);
            emit DecreasePosition(
                key,
                _account,
                _collateralToken,
                _indexToken,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                price,
                usdOut - usdOutAfterFee
            );
            emit ClosePosition(
                key,
                position.size,
                position.collateral,
                position.averagePrice,
                position.entryFundingRate,
                position.reserveAmount,
                position.realisedPnl
            );

            delete positions[key];
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        if (usdOut > 0) {
            if (_isLong) {
                _decreasePoolAmount(
                    _collateralToken,
                    usdToTokenMin(_collateralToken, usdOut)
                );
            }
            uint256 amountOutAfterFees = usdToTokenMin(
                _collateralToken,
                usdOutAfterFee
            );
            _transferOut(_collateralToken, amountOutAfterFees, _receiver);
            return amountOutAfterFees;
        }

        return 0;
    }

    function _collectSwapFees(
        address _token,
        uint256 _amount,
        uint256 _feeBasisPoints
    ) private returns (uint256) {
        uint256 afterFeeAmount = (_amount *
            (BASIS_POINTS_DIVISOR - _feeBasisPoints)) / BASIS_POINTS_DIVISOR;
        uint256 feeAmount = _amount - afterFeeAmount;
        feeReserves[_token] += feeAmount;
        emit CollectSwapFees(
            _token,
            tokenToUsdMin(_token, feeAmount),
            feeAmount
        );
        return afterFeeAmount;
    }

    function _collectMarginFees(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _size,
        uint256 _entryFundingRate
    ) private returns (uint256) {
        uint256 feeUsd = getPositionFee(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _sizeDelta
        );

        uint256 fundingFee = getFundingFee(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _size,
            _entryFundingRate
        );
        feeUsd += fundingFee;

        uint256 feeTokens = usdToTokenMin(_collateralToken, feeUsd);
        feeReserves[_collateralToken] += feeTokens;

        emit CollectMarginFees(_collateralToken, feeUsd, feeTokens);
        return feeUsd;
    }

    function _transferIn(address _token) private returns (uint256) {
        uint256 prevBalance = tokenBalances[_token];
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;

        return nextBalance - prevBalance;
    }

    function _transferOut(
        address _token,
        uint256 _amount,
        address _receiver
    ) private {
        IERC20(_token).safeTransfer(_receiver, _amount);
        tokenBalances[_token] = IERC20(_token).balanceOf(address(this));
    }

    function _updateTokenBalance(address _token) private {
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;
    }

    function _increasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] += _amount;
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (poolAmounts[_token] > balance) {
            revert InvalidTokenAmount();
        }
        emit IncreasePoolAmount(_token, _amount);
    }

    function _decreasePoolAmount(address _token, uint256 _amount) private {
        if (poolAmounts[_token] < _amount) {
            revert InsufficientPoolAmount();
        }
        unchecked {
            poolAmounts[_token] = poolAmounts[_token] - _amount;
        }
        if (reservedAmounts[_token] > poolAmounts[_token]) {
            revert InsufficientPoolAmount();
        }
        emit DecreasePoolAmount(_token, _amount);
    }

    function _increaseUsdvAmount(address _token, uint256 _amount) private {
        usdvAmounts[_token] += _amount;
        uint256 maxUsdvAmount = maxUsdvAmounts[_token];
        if (maxUsdvAmount != 0) {
            if (usdvAmounts[_token] > maxUsdvAmount) {
                revert InvalidUsdvAmount();
            }
        }
        emit IncreaseUsdvAmount(_token, _amount);
    }

    function _decreaseUsdvAmount(address _token, uint256 _amount) private {
        uint256 value = usdvAmounts[_token];
        // since USDV can be minted using multiple assets
        // it is possible for the USDV debt for a single asset to be less than zero
        // the USDV debt is capped to zero for this case
        if (value <= _amount) {
            usdvAmounts[_token] = 0;
            emit DecreaseUsdvAmount(_token, value);
            return;
        }
        usdvAmounts[_token] = value - _amount;
        emit DecreaseUsdvAmount(_token, _amount);
    }

    function _increaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] += _amount;
        if (reservedAmounts[_token] > poolAmounts[_token]) {
            revert InsufficientPoolAmount();
        }
        emit IncreaseReservedAmount(_token, _amount);
    }

    function _decreaseReservedAmount(address _token, uint256 _amount) private {
        if (reservedAmounts[_token] < _amount) {
            revert InsufficientReserve();
        }
        unchecked {
            reservedAmounts[_token] = reservedAmounts[_token] - _amount;
        }
        emit DecreaseReservedAmount(_token, _amount);
    }

    function _increaseGuaranteedUsd(address _token, uint256 _usdAmount)
        private
    {
        guaranteedUsd[_token] += _usdAmount;
        emit IncreaseGuaranteedUsd(_token, _usdAmount);
    }

    function _decreaseGuaranteedUsd(address _token, uint256 _usdAmount)
        private
    {
        guaranteedUsd[_token] -= _usdAmount;
        emit DecreaseGuaranteedUsd(_token, _usdAmount);
    }

    function _increaseGlobalShortSize(address _token, uint256 _amount) private {
        globalShortSizes[_token] += _amount;

        uint256 maxSize = maxGlobalShortSizes[_token];
        if (maxSize != 0) {
            if (globalShortSizes[_token] > maxSize) {
                revert MaxShortsExceeded();
            }
        }
    }

    function _decreaseGlobalShortSize(address _token, uint256 _amount) private {
        uint256 size = globalShortSizes[_token];
        if (_amount > size) {
            globalShortSizes[_token] = 0;
            return;
        }

        globalShortSizes[_token] = size - _amount;
    }

    function _validateBufferAmount(address _token) private view {
        if (poolAmounts[_token] < bufferAmounts[_token]) {
            revert InsufficientPoolAmount();
        }
    }

    function _validateRouter(address _account) private view {
        if (msg.sender == _account) {
            return;
        }
        if (msg.sender == router) {
            return;
        }
        if (!approvedRouters[_account][msg.sender]) {
            revert InvalidRouter();
        }
    }

    function _validateTokens(
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) private view {
        if (_isLong) {
            require(
                _collateralToken == _indexToken &&
                    whitelistedTokens[_collateralToken] &&
                    !stableTokens[_collateralToken]
            );
            return;
        }

        require(
            whitelistedTokens[_collateralToken] &&
                stableTokens[_collateralToken] &&
                !stableTokens[_indexToken] &&
                shortableTokens[_indexToken]
        );
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _onlyOwner() private view {
        if (msg.sender != owner) {
            revert InvalidOwner();
        }
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateManager() private view {
        if (inManagerMode) {
            if (!isManager[msg.sender]) {
                revert InvalidManager();
            }
        }
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateGasPrice() private view {
        if (maxGasPrice == 0) {
            return;
        }
        if (tx.gasprice > maxGasPrice) {
            revert InvalidGasPrice();
        }
    }

    function _validatePosition(uint256 _size, uint256 _collateral)
        private
        pure
    {
        if (_size == 0) {
            if (_collateral != 0) {
                revert InvalidCollateral();
            }
            return;
        }
        if (_size < _collateral) {
            revert InvalidPositionSize();
        }
    }
}
