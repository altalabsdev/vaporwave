// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./interfaces/ITimelockTarget.sol";
import "./interfaces/IVwaveTimelock.sol";
import "./interfaces/IHandlerTarget.sol";
import "../access/interfaces/IAdmin.sol";
import "../core/interfaces/IVault.sol";
import "../core/interfaces/IVaultUtils.sol";
import "../core/interfaces/IVaultPriceFeed.sol";
import "../core/interfaces/IRouter.sol";
import "../tokens/interfaces/IYieldToken.sol";
import "../tokens/interfaces/IBaseToken.sol";
import "../tokens/interfaces/IMintable.sol";
import "../tokens/interfaces/IUSDV.sol";
import "../staking/interfaces/IVester.sol";

/// User does not have function priveleges
error Forbidden();
error InvalidBuffer();
error InvalidFundingRateFactor();
error InvalidStableFundingRateFactor();
error InvalidSetFeesParameter();
error InvalidMinProfitBps();

/// @title Vaporwave Timelock
contract VwaveTimelock is IVwaveTimelock {
    using SafeMath for uint256;

    uint256 public constant PRICE_PRECISION = 10**30;
    uint256 public constant MAX_BUFFER = 7 days;
    uint256 public constant MAX_FEE_BASIS_POINTS = 300; // 3%
    uint256 public constant MAX_FUNDING_RATE_FACTOR = 200; // 0.02%
    uint256 public constant MAX_LEVERAGE_VALIDATION = 500000; // 50x

    uint256 public buffer;
    uint256 public longBuffer;
    address public admin;

    address public tokenManager;
    address public rewardManager;
    address public mintReceiver;
    uint256 public maxTokenSupply;

    mapping(bytes32 => uint256) public pendingActions;
    mapping(address => bool) public excludedTokens;

    mapping(address => bool) public isHandler;

    event SignalPendingAction(bytes32 action);
    event SignalApprove(
        address token,
        address spender,
        uint256 amount,
        bytes32 action
    );
    event SignalWithdrawToken(
        address target,
        address token,
        address receiver,
        uint256 amount,
        bytes32 action
    );
    event SignalMint(
        address token,
        address receiver,
        uint256 amount,
        bytes32 action
    );
    event SignalSetGov(address target, address gov, bytes32 action);
    event SignalSetPriceFeed(address vault, address priceFeed, bytes32 action);
    event SignalAddPlugin(address router, address plugin, bytes32 action);
    event SignalRedeemUsdv(address vault, address token, uint256 amount);
    event SignalVaultSetTokenConfig(
        address vault,
        address token,
        uint256 tokenDecimals,
        uint256 tokenWeight,
        uint256 minProfitBps,
        uint256 maxUsdvAmount,
        bool isStable,
        bool isShortable
    );
    event SignalPriceFeedSetTokenConfig(
        address vaultPriceFeed,
        address token,
        address priceFeed,
        uint256 priceDecimals,
        bool isStrictStable
    );
    event ClearAction(bytes32 action);

    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert Forbidden();
        }
        _;
    }

    modifier onlyAdminOrHandler() {
        if (msg.sender != admin && !isHandler[msg.sender]) {
            revert Forbidden();
        }
        _;
    }

    modifier onlyTokenManager() {
        if (msg.sender != tokenManager) {
            revert Forbidden();
        }
        _;
    }

    modifier onlyRewardManager() {
        if (msg.sender != rewardManager) {
            revert Forbidden();
        }
        _;
    }

    constructor(
        address _admin,
        uint256 _buffer,
        uint256 _longBuffer,
        address _rewardManager,
        address _tokenManager,
        address _mintReceiver,
        uint256 _maxTokenSupply
    ) {
        if (_buffer > MAX_BUFFER) {
            revert InvalidBuffer();
        }
        require(
            _longBuffer <= MAX_BUFFER,
            "VwaveTimelock: invalid _longBuffer"
        );
        admin = _admin;
        buffer = _buffer;
        longBuffer = _longBuffer;
        rewardManager = _rewardManager;
        tokenManager = _tokenManager;
        mintReceiver = _mintReceiver;
        maxTokenSupply = _maxTokenSupply;
    }

    /// @notice Set admin address
    /// @param _admin New admin address
    function setAdmin(address _admin) external override onlyTokenManager {
        admin = _admin;
    }

    /// @notice Set the external admin
    /// @param _target The address of the target contract
    /// @param _admin The address of the new admin
    function setExternalAdmin(address _target, address _admin)
        external
        onlyAdmin
    {
        require(_target != address(this), "VwaveTimelock: invalid _target");
        IAdmin(_target).setAdmin(_admin);
    }

    /// @notice Set the contract handler
    /// @param _handler The contract handler address
    /// @param _isActive Whether to add or remove `_handler` from the list of handlers
    function setContractHandler(address _handler, bool _isActive)
        external
        onlyAdmin
    {
        isHandler[_handler] = _isActive;
    }

    /// @notice Set the buffer for the timelock.
    /// @dev Buffer can only be increased and never more than `MAX_BUFFER`.
    /// @param _buffer The buffer in seconds.
    function setBuffer(uint256 _buffer) external onlyAdmin {
        if (_buffer > MAX_BUFFER) {
            revert InvalidBuffer();
        }
        if (_buffer < buffer) {
            revert InvalidBuffer();
        }
        buffer = _buffer;
    }

    /// @notice Set the maximum leverage allowed
    /// @param _vault The vault address
    /// @param _maxLeverage The maximum leverage allowed
    function setMaxLeverage(address _vault, uint256 _maxLeverage)
        external
        onlyAdmin
    {
        require(
            _maxLeverage > MAX_LEVERAGE_VALIDATION,
            "VwaveTimelock: invalid _maxLeverage"
        );
        IVault(_vault).setMaxLeverage(_maxLeverage);
    }

    /// @notice Set Funding Rate
    /// @param _vault The vault address
    /// @param _fundingInterval The funding interval in seconds
    /// @param _fundingRateFactor The funding rate factor in basis points
    /// @param _stableFundingRateFactor The stable funding rate factor in basis points
    function setFundingRate(
        address _vault,
        uint256 _fundingInterval,
        uint256 _fundingRateFactor,
        uint256 _stableFundingRateFactor
    ) external onlyAdmin {
        if (_fundingRateFactor >= MAX_FUNDING_RATE_FACTOR) {
            revert InvalidFundingRateFactor();
        }
        if (_stableFundingRateFactor >= MAX_FUNDING_RATE_FACTOR) {
            revert InvalidStableFundingRateFactor();
        }
        IVault(_vault).setFundingRate(
            _fundingInterval,
            _fundingRateFactor,
            _stableFundingRateFactor
        );
    }

    /// @notice Set Fees
    function setFees(
        address _vault,
        uint256 _taxBasisPoints,
        uint256 _stableTaxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _swapFeeBasisPoints,
        uint256 _stableSwapFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime,
        bool _hasDynamicFees
    ) external onlyAdmin {
        if (
            _taxBasisPoints >= MAX_FEE_BASIS_POINTS ||
            _stableTaxBasisPoints >= MAX_FEE_BASIS_POINTS ||
            _mintBurnFeeBasisPoints >= MAX_FEE_BASIS_POINTS ||
            _swapFeeBasisPoints >= MAX_FEE_BASIS_POINTS ||
            _stableSwapFeeBasisPoints >= MAX_FEE_BASIS_POINTS ||
            _marginFeeBasisPoints >= MAX_FEE_BASIS_POINTS ||
            _liquidationFeeUsd >= MAX_FEE_BASIS_POINTS
        ) {
            revert InvalidSetFeesParameter();
        }

        IVault(_vault).setFees(
            _taxBasisPoints,
            _stableTaxBasisPoints,
            _mintBurnFeeBasisPoints,
            _swapFeeBasisPoints,
            _stableSwapFeeBasisPoints,
            _marginFeeBasisPoints,
            _liquidationFeeUsd,
            _minProfitTime,
            _hasDynamicFees
        );
    }

    /// @notice Set Token Configurations
    function setTokenConfig(
        address _vault,
        address _token,
        uint256 _tokenWeight,
        uint256 _minProfitBps,
        uint256 _maxUsdvAmount,
        uint256 _bufferAmount,
        uint256 _usdvAmount
    ) external onlyAdmin {
        if (_minProfitBps > 500) {
            revert InvalidMinProfitBps();
        }

        IVault vault = IVault(_vault);

        if (!vault.whitelistedTokens(_token)) {
            revert(); // TODO "VwaveTimelock: token not yet whitelisted"
        }

        uint256 tokenDecimals = vault.tokenDecimals(_token);
        bool isStable = vault.stableTokens(_token);
        bool isShortable = vault.shortableTokens(_token);

        IVault(_vault).setTokenConfig(
            _token,
            tokenDecimals,
            _tokenWeight,
            _minProfitBps,
            _maxUsdvAmount,
            isStable,
            isShortable
        );

        IVault(_vault).setBufferAmount(_token, _bufferAmount);

        IVault(_vault).setUsdvAmount(_token, _usdvAmount);
    }

    /// @notice Set Max Global Short Size
    /// @param _vault The vault address
    /// @param _token The token to set the max short size for
    /// @param _amount The max short size for the token
    function setMaxGlobalShortSize(
        address _vault,
        address _token,
        uint256 _amount
    ) external onlyAdmin {
        IVault(_vault).setMaxGlobalShortSize(_token, _amount);
    }

    /// @notice Remove an admin from a yield token
    /// @param _token The token to remove the admin from
    /// @param _account The account to remove as an admin
    function removeAdmin(address _token, address _account) external onlyAdmin {
        IYieldToken(_token).removeAdmin(_account);
    }

    /// @notice Enable or disable `_isEnabled` the price feed from using AMM aggregate pricing
    /// @param _priceFeed The price feed address
    /// @param _isEnabled Whether to enable or disable the AMM pricing for the feed
    function setIsAmmEnabled(address _priceFeed, bool _isEnabled)
        external
        onlyAdmin
    {
        IVaultPriceFeed(_priceFeed).setIsAmmEnabled(_isEnabled);
    }

    /// @notice Enable or disable `_isEnabled` the price feed from using secondary pricing
    /// @param _priceFeed The price feed address
    /// @param _isEnabled Whether to enable or disable the secondary pricing for the feed
    function setIsSecondaryPriceEnabled(address _priceFeed, bool _isEnabled)
        external
        onlyAdmin
    {
        IVaultPriceFeed(_priceFeed).setIsSecondaryPriceEnabled(_isEnabled);
    }

    /// @notice Set the strict max price deviation for the price feed
    /// @param _priceFeed The price feed address
    /// @param _maxStrictPriceDeviation The max price deviation for the feed
    function setMaxStrictPriceDeviation(
        address _priceFeed,
        uint256 _maxStrictPriceDeviation
    ) external onlyAdmin {
        IVaultPriceFeed(_priceFeed).setMaxStrictPriceDeviation(
            _maxStrictPriceDeviation
        );
    }

    /// @notice Enable or disable `_useV2Pricing` the price feed from using V2 pricing
    /// @param _priceFeed The price feed address
    /// @param _useV2Pricing Whether to enable or disable the V2 pricing for the feed
    function setUseV2Pricing(address _priceFeed, bool _useV2Pricing)
        external
        onlyAdmin
    {
        IVaultPriceFeed(_priceFeed).setUseV2Pricing(_useV2Pricing);
    }

    // TODO: add natspec
    function setAdjustment(
        address _priceFeed,
        address _token,
        bool _isAdditive,
        uint256 _adjustmentBps
    ) external onlyAdmin {
        IVaultPriceFeed(_priceFeed).setAdjustment(
            _token,
            _isAdditive,
            _adjustmentBps
        );
    }

    function setSpreadBasisPoints(
        address _priceFeed,
        address _token,
        uint256 _spreadBasisPoints
    ) external onlyAdmin {
        IVaultPriceFeed(_priceFeed).setSpreadBasisPoints(
            _token,
            _spreadBasisPoints
        );
    }

    function setSpreadThresholdBasisPoints(
        address _priceFeed,
        uint256 _spreadThresholdBasisPoints
    ) external onlyAdmin {
        IVaultPriceFeed(_priceFeed).setSpreadThresholdBasisPoints(
            _spreadThresholdBasisPoints
        );
    }

    function setFavorPrimaryPrice(address _priceFeed, bool _favorPrimaryPrice)
        external
        onlyAdmin
    {
        IVaultPriceFeed(_priceFeed).setFavorPrimaryPrice(_favorPrimaryPrice);
    }

    function setPriceSampleSpace(address _priceFeed, uint256 _priceSampleSpace)
        external
        onlyAdmin
    {
        require(_priceSampleSpace <= 5, "Invalid _priceSampleSpace");
        IVaultPriceFeed(_priceFeed).setPriceSampleSpace(_priceSampleSpace);
    }

    function setIsSwapEnabled(address _vault, bool _isSwapEnabled)
        external
        onlyAdmin
    {
        IVault(_vault).setIsSwapEnabled(_isSwapEnabled);
    }

    function setIsLeverageEnabled(address _vault, bool _isLeverageEnabled)
        external
        override
        onlyAdminOrHandler
    {
        IVault(_vault).setIsLeverageEnabled(_isLeverageEnabled);
    }

    function setVaultUtils(address _vault, IVaultUtils _vaultUtils)
        external
        onlyAdmin
    {
        IVault(_vault).setVaultUtils(_vaultUtils);
    }

    function setMaxGasPrice(address _vault, uint256 _maxGasPrice)
        external
        onlyAdmin
    {
        require(_maxGasPrice > 5000000000, "Invalid _maxGasPrice");
        IVault(_vault).setMaxGasPrice(_maxGasPrice);
    }

    function withdrawFees(
        address _vault,
        address _token,
        address _receiver
    ) external onlyAdmin {
        IVault(_vault).withdrawFees(_token, _receiver);
    }

    function setInPrivateLiquidationMode(
        address _vault,
        bool _inPrivateLiquidationMode
    ) external onlyAdmin {
        IVault(_vault).setInPrivateLiquidationMode(_inPrivateLiquidationMode);
    }

    function setLiquidator(
        address _vault,
        address _liquidator,
        bool _isActive
    ) external onlyAdmin {
        IVault(_vault).setLiquidator(_liquidator, _isActive);
    }

    function addExcludedToken(address _token) external onlyAdmin {
        excludedTokens[_token] = true;
    }

    function setInPrivateTransferMode(
        address _token,
        bool _inPrivateTransferMode
    ) external onlyAdmin {
        if (excludedTokens[_token]) {
            // excludedTokens can only have their transfers enabled
            require(
                _inPrivateTransferMode == false,
                "VwaveTimelock: invalid _inPrivateTransferMode"
            );
        }

        IBaseToken(_token).setInPrivateTransferMode(_inPrivateTransferMode);
    }

    function transferIn(
        address _sender,
        address _token,
        uint256 _amount
    ) external onlyAdmin {
        IERC20(_token).transferFrom(_sender, address(this), _amount);
    }

    function signalApprove(
        address _token,
        address _spender,
        uint256 _amount
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked("approve", _token, _spender, _amount)
        );
        _setPendingAction(action);
        emit SignalApprove(_token, _spender, _amount, action);
    }

    function approve(
        address _token,
        address _spender,
        uint256 _amount
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked("approve", _token, _spender, _amount)
        );
        _validateAction(action);
        _clearAction(action);
        IERC20(_token).approve(_spender, _amount);
    }

    function signalWithdrawToken(
        address _target,
        address _token,
        address _receiver,
        uint256 _amount
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked(
                "withdrawToken",
                _target,
                _token,
                _receiver,
                _amount
            )
        );
        _setPendingAction(action);
        emit SignalWithdrawToken(_target, _token, _receiver, _amount, action);
    }

    function withdrawToken(
        address _target,
        address _token,
        address _receiver,
        uint256 _amount
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked(
                "withdrawToken",
                _target,
                _token,
                _receiver,
                _amount
            )
        );
        _validateAction(action);
        _clearAction(action);
        IBaseToken(_target).withdrawToken(_token, _receiver, _amount);
    }

    function signalMint(
        address _token,
        address _receiver,
        uint256 _amount
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked("mint", _token, _receiver, _amount)
        );
        _setPendingAction(action);
        emit SignalMint(_token, _receiver, _amount, action);
    }

    function processMint(
        address _token,
        address _receiver,
        uint256 _amount
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked("mint", _token, _receiver, _amount)
        );
        _validateAction(action);
        _clearAction(action);

        _mint(_token, _receiver, _amount);
    }

    function signalSetGov(address _target, address _gov)
        external
        override
        onlyTokenManager
    {
        bytes32 action = keccak256(abi.encodePacked("setGov", _target, _gov));
        _setLongPendingAction(action);
        emit SignalSetGov(_target, _gov, action);
    }

    function setGov(address _target, address _gov) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setGov", _target, _gov));
        _validateAction(action);
        _clearAction(action);
        ITimelockTarget(_target).setGov(_gov);
    }

    function signalSetPriceFeed(address _vault, address _priceFeed)
        external
        onlyAdmin
    {
        bytes32 action = keccak256(
            abi.encodePacked("setPriceFeed", _vault, _priceFeed)
        );
        _setPendingAction(action);
        emit SignalSetPriceFeed(_vault, _priceFeed, action);
    }

    function setPriceFeed(address _vault, address _priceFeed)
        external
        onlyAdmin
    {
        bytes32 action = keccak256(
            abi.encodePacked("setPriceFeed", _vault, _priceFeed)
        );
        _validateAction(action);
        _clearAction(action);
        IVault(_vault).setPriceFeed(_priceFeed);
    }

    function signalAddPlugin(address _router, address _plugin)
        external
        onlyAdmin
    {
        bytes32 action = keccak256(
            abi.encodePacked("addPlugin", _router, _plugin)
        );
        _setPendingAction(action);
        emit SignalAddPlugin(_router, _plugin, action);
    }

    function addPlugin(address _router, address _plugin) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked("addPlugin", _router, _plugin)
        );
        _validateAction(action);
        _clearAction(action);
        IRouter(_router).addPlugin(_plugin);
    }

    function signalRedeemUsdv(
        address _vault,
        address _token,
        uint256 _amount
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked("redeemUsdv", _vault, _token, _amount)
        );
        _setPendingAction(action);
        emit SignalRedeemUsdv(_vault, _token, _amount);
    }

    function redeemUsdv(
        address _vault,
        address _token,
        uint256 _amount
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked("redeemUsdv", _vault, _token, _amount)
        );
        _validateAction(action);
        _clearAction(action);

        address usdv = IVault(_vault).usdv();
        IVault(_vault).setManager(address(this), true);
        IUSDV(usdv).addVault(address(this));

        IUSDV(usdv).mint(address(this), _amount);
        IERC20(usdv).transfer(address(_vault), _amount);

        IVault(_vault).sellUSDV(_token, mintReceiver);

        IVault(_vault).setManager(address(this), false);
        IUSDV(usdv).removeVault(address(this));
    }

    function signalVaultSetTokenConfig(
        address _vault,
        address _token,
        uint256 _tokenDecimals,
        uint256 _tokenWeight,
        uint256 _minProfitBps,
        uint256 _maxUsdvAmount,
        bool _isStable,
        bool _isShortable
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked(
                "vaultSetTokenConfig",
                _vault,
                _token,
                _tokenDecimals,
                _tokenWeight,
                _minProfitBps,
                _maxUsdvAmount,
                _isStable,
                _isShortable
            )
        );

        _setPendingAction(action);

        emit SignalVaultSetTokenConfig(
            _vault,
            _token,
            _tokenDecimals,
            _tokenWeight,
            _minProfitBps,
            _maxUsdvAmount,
            _isStable,
            _isShortable
        );
    }

    function vaultSetTokenConfig(
        address _vault,
        address _token,
        uint256 _tokenDecimals,
        uint256 _tokenWeight,
        uint256 _minProfitBps,
        uint256 _maxUsdvAmount,
        bool _isStable,
        bool _isShortable
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked(
                "vaultSetTokenConfig",
                _vault,
                _token,
                _tokenDecimals,
                _tokenWeight,
                _minProfitBps,
                _maxUsdvAmount,
                _isStable,
                _isShortable
            )
        );

        _validateAction(action);
        _clearAction(action);

        IVault(_vault).setTokenConfig(
            _token,
            _tokenDecimals,
            _tokenWeight,
            _minProfitBps,
            _maxUsdvAmount,
            _isStable,
            _isShortable
        );
    }

    function signalPriceFeedSetTokenConfig(
        address _vaultPriceFeed,
        address _token,
        address _priceFeed,
        uint256 _priceDecimals,
        bool _isStrictStable
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked(
                "priceFeedSetTokenConfig",
                _vaultPriceFeed,
                _token,
                _priceFeed,
                _priceDecimals,
                _isStrictStable
            )
        );

        _setPendingAction(action);

        emit SignalPriceFeedSetTokenConfig(
            _vaultPriceFeed,
            _token,
            _priceFeed,
            _priceDecimals,
            _isStrictStable
        );
    }

    function priceFeedSetTokenConfig(
        address _vaultPriceFeed,
        address _token,
        address _priceFeed,
        uint256 _priceDecimals,
        bool _isStrictStable
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked(
                "priceFeedSetTokenConfig",
                _vaultPriceFeed,
                _token,
                _priceFeed,
                _priceDecimals,
                _isStrictStable
            )
        );

        _validateAction(action);
        _clearAction(action);

        IVaultPriceFeed(_vaultPriceFeed).setTokenConfig(
            _token,
            _priceFeed,
            _priceDecimals,
            _isStrictStable
        );
    }

    function cancelAction(bytes32 _action) external onlyAdmin {
        _clearAction(_action);
    }

    function _mint(
        address _token,
        address _receiver,
        uint256 _amount
    ) private {
        IMintable mintable = IMintable(_token);

        if (!mintable.isMinter(address(this))) {
            mintable.setMinter(address(this), true);
        }

        mintable.mint(_receiver, _amount);
        require(
            IERC20(_token).totalSupply() <= maxTokenSupply,
            "VwaveTimelock: maxTokenSupply exceeded"
        );
    }

    function _setPendingAction(bytes32 _action) private {
        pendingActions[_action] = block.timestamp.add(buffer);
        emit SignalPendingAction(_action);
    }

    function _setLongPendingAction(bytes32 _action) private {
        pendingActions[_action] = block.timestamp.add(longBuffer);
        emit SignalPendingAction(_action);
    }

    function _validateAction(bytes32 _action) private view {
        require(
            pendingActions[_action] != 0,
            "VwaveTimelock: action not signalled"
        );
        require(
            pendingActions[_action] < block.timestamp,
            "VwaveTimelock: action time not yet passed"
        );
    }

    function _clearAction(bytes32 _action) private {
        require(pendingActions[_action] != 0, "VwaveTimelock: invalid _action");
        delete pendingActions[_action];
        emit ClearAction(_action);
    }
}
