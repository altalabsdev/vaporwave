// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../tokens/interfaces/IWETH.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IOrderBook.sol";

/// Account does not have function permissions
error OrderBookForbidden();
/// Contract already initialized
error AlreadyInitialized();
/// Invalid execution price
error InvalidPrice();
/// Invalid token swap path
error InvalidPath();
/// Sender must be weth
error InvalidSender();
/// Amount in cannot be 0
error InvalidAmount();
/// Incorrect msg.value sent with the transaction
error InvalidValue();
/// The execution fee is less than the minimum fee
error InsufficientFee();
/// The amount out is less than minOut
error InsufficientAmountOut();
/// Insufficient collateral provided
error InsufficientCollateral();
/// The order specified does not exist
error NonexistentOrder();

/// @title Vaporwave Order Book
contract OrderBook is ReentrancyGuard, IOrderBook {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    struct IncreaseOrder {
        address account;
        address purchaseToken;
        uint256 purchaseTokenAmount;
        address collateralToken;
        address indexToken;
        uint256 sizeDelta;
        bool isLong;
        uint256 triggerPrice;
        bool triggerAboveThreshold;
        uint256 executionFee;
    }
    struct DecreaseOrder {
        address account;
        address collateralToken;
        uint256 collateralDelta;
        address indexToken;
        uint256 sizeDelta;
        bool isLong;
        uint256 triggerPrice;
        bool triggerAboveThreshold;
        uint256 executionFee;
    }
    struct SwapOrder {
        address account;
        address[] path;
        uint256 amountIn;
        uint256 minOut;
        uint256 triggerRatio;
        bool triggerAboveThreshold;
        bool shouldUnwrap;
        uint256 executionFee;
    }

    uint256 public constant PRICE_PRECISION = 1e30;
    uint256 public constant USDV_PRECISION = 1e18;

    mapping(address => mapping(uint256 => IncreaseOrder)) public increaseOrders;
    mapping(address => uint256) public increaseOrdersIndex;
    mapping(address => mapping(uint256 => DecreaseOrder)) public decreaseOrders;
    mapping(address => uint256) public decreaseOrdersIndex;
    mapping(address => mapping(uint256 => SwapOrder)) public swapOrders;
    mapping(address => uint256) public swapOrdersIndex;

    address public gov;
    address public weth;
    address public usdv;
    address public router;
    address public vault;
    uint256 public minExecutionFee;
    uint256 public minPurchaseTokenAmountUsd;
    bool public isInitialized = false;

    event CreateIncreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address purchaseToken,
        uint256 purchaseTokenAmount,
        address collateralToken,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee
    );
    event CancelIncreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address purchaseToken,
        uint256 purchaseTokenAmount,
        address collateralToken,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee
    );
    event ExecuteIncreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address purchaseToken,
        uint256 purchaseTokenAmount,
        address collateralToken,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee,
        uint256 executionPrice
    );
    event UpdateIncreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 sizeDelta,
        uint256 triggerPrice,
        bool triggerAboveThreshold
    );
    event CreateDecreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee
    );
    event CancelDecreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee
    );
    event ExecuteDecreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee,
        uint256 executionPrice
    );
    event UpdateDecreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold
    );
    event CreateSwapOrder(
        address indexed account,
        uint256 orderIndex,
        address[] path,
        uint256 amountIn,
        uint256 minOut,
        uint256 triggerRatio,
        bool triggerAboveThreshold,
        bool shouldUnwrap,
        uint256 executionFee
    );
    event CancelSwapOrder(
        address indexed account,
        uint256 orderIndex,
        address[] path,
        uint256 amountIn,
        uint256 minOut,
        uint256 triggerRatio,
        bool triggerAboveThreshold,
        bool shouldUnwrap,
        uint256 executionFee
    );
    event UpdateSwapOrder(
        address indexed account,
        uint256 ordexIndex,
        address[] path,
        uint256 amountIn,
        uint256 minOut,
        uint256 triggerRatio,
        bool triggerAboveThreshold,
        bool shouldUnwrap,
        uint256 executionFee
    );
    event ExecuteSwapOrder(
        address indexed account,
        uint256 orderIndex,
        address[] path,
        uint256 amountIn,
        uint256 minOut,
        uint256 amountOut,
        uint256 triggerRatio,
        bool triggerAboveThreshold,
        bool shouldUnwrap,
        uint256 executionFee
    );

    event Initialize(
        address router,
        address vault,
        address weth,
        address usdv,
        uint256 minExecutionFee,
        uint256 minPurchaseTokenAmountUsd
    );
    event UpdateMinExecutionFee(uint256 minExecutionFee);
    event UpdateMinPurchaseTokenAmountUsd(uint256 minPurchaseTokenAmountUsd);
    event UpdateGov(address gov);

    modifier onlyGov() {
        if (msg.sender != gov) {
            revert OrderBookForbidden();
        }
        _;
    }

    constructor() {
        gov = msg.sender;
    }

    receive() external payable {
        if (msg.sender != weth) {
            revert InvalidSender();
        }
    }

    /// @notice Initialize the order book
    /// @param _router The router contract address
    /// @param _vault The vault contract address
    /// @param _weth The WETH contract address
    /// @param _usdv The USDV contract address
    /// @param _minExecutionFee The minimum execution fee
    /// @param _minPurchaseTokenAmountUsd The minimum purchase token amount in USD
    function initialize(
        address _router,
        address _vault,
        address _weth,
        address _usdv,
        uint256 _minExecutionFee,
        uint256 _minPurchaseTokenAmountUsd
    ) external onlyGov {
        if (isInitialized) {
            revert AlreadyInitialized();
        }
        isInitialized = true;

        router = _router;
        vault = _vault;
        weth = _weth;
        usdv = _usdv;
        minExecutionFee = _minExecutionFee;
        minPurchaseTokenAmountUsd = _minPurchaseTokenAmountUsd;

        emit Initialize(
            _router,
            _vault,
            _weth,
            _usdv,
            _minExecutionFee,
            _minPurchaseTokenAmountUsd
        );
    }

    /// @notice Set the Minimum Execution Fee to `_minExecutionFee`
    /// @param _minExecutionFee The minimum execution fee
    /// @dev Emits an event `UpdateMinExecutionFee`
    function setMinExecutionFee(uint256 _minExecutionFee) external onlyGov {
        minExecutionFee = _minExecutionFee;

        emit UpdateMinExecutionFee(_minExecutionFee);
    }

    /// @notice Set the Minimum Purchase Token Amount in USD to `_minPurchaseTokenAmountUsd`
    /// @param _minPurchaseTokenAmountUsd The minimum purchase token amount in USD
    /// @dev Emits an event `UpdateMinPurchaseTokenAmountUsd`
    function setMinPurchaseTokenAmountUsd(uint256 _minPurchaseTokenAmountUsd)
        external
        onlyGov
    {
        minPurchaseTokenAmountUsd = _minPurchaseTokenAmountUsd;

        emit UpdateMinPurchaseTokenAmountUsd(_minPurchaseTokenAmountUsd);
    }

    /// @notice Set the Governor address to `_gov`
    /// @param _gov The governor address
    /// @dev Emits an event `UpdateGov`
    function setGov(address _gov) external onlyGov {
        gov = _gov;

        emit UpdateGov(_gov);
    }

    /// @notice Create a swap order
    /// @param _path The path of the swap
    /// @param _amountIn The amount of the token to swap in
    /// @param _minOut The minimum amount of the token to swap out
    /// @param _triggerRatio The trigger ratio of the swap
    /// @param _triggerAboveThreshold The threshold to trigger the swap
    /// @param _executionFee The execution fee of the swap
    /// @param _shouldWrap The flag to wrap WETH
    /// @param _shouldUnwrap The flag to unwrap WETH
    function createSwapOrder(
        address[] memory _path,
        uint256 _amountIn,
        uint256 _minOut,
        uint256 _triggerRatio, // tokenB / tokenA
        bool _triggerAboveThreshold,
        uint256 _executionFee,
        bool _shouldWrap,
        bool _shouldUnwrap
    ) external payable nonReentrant {
        if (_path.length != 2 && _path.length != 3) {
            revert InvalidPath();
        }
        if (_path[0] == _path[_path.length - 1]) {
            revert InvalidPath();
        }
        if (_amountIn == 0) {
            revert InvalidAmount();
        }
        if (_executionFee < minExecutionFee) {
            revert InsufficientFee();
        }

        // always need this call because of mandatory executionFee user has to transfer in ETH
        _transferInETH();

        if (_shouldWrap) {
            if (_path[0] != weth) {
                revert InvalidPath();
            }
            if (msg.value != _executionFee.add(_amountIn)) {
                revert InvalidValue();
            }
        } else {
            if (msg.value != _executionFee) {
                revert InvalidValue();
            }
            IRouter(router).pluginTransfer(
                _path[0],
                msg.sender,
                address(this),
                _amountIn
            );
        }

        _createSwapOrder(
            msg.sender,
            _path,
            _amountIn,
            _minOut,
            _triggerRatio,
            _triggerAboveThreshold,
            _shouldUnwrap,
            _executionFee
        );
    }

    /// @notice Cancel multiple swap orders
    /// @param _swapOrderIndexes The indexes of the swap orders to cancel
    /// @param _increaseOrderIndexes The indexes of the increase orders to cancel
    /// @param _decreaseOrderIndexes The indexes of the decrease orders to cancel
    function cancelMultiple(
        uint256[] memory _swapOrderIndexes,
        uint256[] memory _increaseOrderIndexes,
        uint256[] memory _decreaseOrderIndexes
    ) external {
        for (uint256 i = 0; i < _swapOrderIndexes.length; i++) {
            cancelSwapOrder(_swapOrderIndexes[i]);
        }
        for (uint256 i = 0; i < _increaseOrderIndexes.length; i++) {
            cancelIncreaseOrder(_increaseOrderIndexes[i]);
        }
        for (uint256 i = 0; i < _decreaseOrderIndexes.length; i++) {
            cancelDecreaseOrder(_decreaseOrderIndexes[i]);
        }
    }

    /// @notice Update a swap order
    /// @dev Emits an event `UpdateSwapOrder`
    /// @param _orderIndex The index of the order to update
    /// @param _minOut The minimum token amount to swap out
    /// @param _triggerRatio The trigger ratio for the swap
    /// @param _triggerAboveThreshold True if the threshold is above the trigger ratio, false otherwise
    function updateSwapOrder(
        uint256 _orderIndex,
        uint256 _minOut,
        uint256 _triggerRatio,
        bool _triggerAboveThreshold
    ) external nonReentrant {
        SwapOrder storage order = swapOrders[msg.sender][_orderIndex];
        if (order.account == address(0)) {
            revert NonexistentOrder();
        }

        order.minOut = _minOut;
        order.triggerRatio = _triggerRatio;
        order.triggerAboveThreshold = _triggerAboveThreshold;

        emit UpdateSwapOrder(
            msg.sender,
            _orderIndex,
            order.path,
            order.amountIn,
            _minOut,
            _triggerRatio,
            _triggerAboveThreshold,
            order.shouldUnwrap,
            order.executionFee
        );
    }

    /// @notice Execute a swap order
    /// @dev Emits an event `ExecuteSwapOrder`
    /// @param _account The account that created the swap order
    /// @param _orderIndex The index of the order to execute
    /// @param _feeReceiver The address to receive the fees
    function executeSwapOrder(
        address _account,
        uint256 _orderIndex,
        address payable _feeReceiver
    ) external nonReentrant {
        SwapOrder memory order = swapOrders[_account][_orderIndex];
        if (order.account == address(0)) {
            revert NonexistentOrder();
        }

        if (order.triggerAboveThreshold) {
            // gas optimisation
            // order.minAmount should prevent wrong price execution in case of simple limit order
            if (
                !validateSwapOrderPriceWithTriggerAboveThreshold(
                    order.path,
                    order.triggerRatio
                )
            ) {
                revert InvalidPrice();
            }
        }

        delete swapOrders[_account][_orderIndex];

        IERC20(order.path[0]).safeTransfer(vault, order.amountIn);

        uint256 _amountOut;
        if (order.path[order.path.length - 1] == weth && order.shouldUnwrap) {
            _amountOut = _swap(order.path, order.minOut, address(this));
            _transferOutETH(_amountOut, payable(order.account));
        } else {
            _amountOut = _swap(order.path, order.minOut, order.account);
        }

        // pay executor
        _transferOutETH(order.executionFee, _feeReceiver);

        emit ExecuteSwapOrder(
            _account,
            _orderIndex,
            order.path,
            order.amountIn,
            order.minOut,
            _amountOut,
            order.triggerRatio,
            order.triggerAboveThreshold,
            order.shouldUnwrap,
            order.executionFee
        );
    }

    /// @notice Create an increase order
    /// @dev User must always transfer in ETH for execution fee
    /// @param _path The path of the token swap
    /// @param _amountIn The amount of tokens to swap in
    /// @param _indexToken The index token
    /// @param _minOut The minimum amount of tokens to swap out
    /// @param _sizeDelta The size delta
    /// @param _collateralToken The collateral token
    /// @param _isLong True if the position is long, false otherwise
    /// @param _triggerPrice The trigger price
    /// @param _triggerAboveThreshold True if the threshold is above the trigger ratio, false otherwise
    /// @param _executionFee The execution fee
    /// @param _shouldWrap True if weth should be wrapped, false otherwise
    function createIncreaseOrder(
        address[] memory _path,
        uint256 _amountIn,
        address _indexToken,
        uint256 _minOut,
        uint256 _sizeDelta,
        address _collateralToken,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _executionFee,
        bool _shouldWrap
    ) external payable nonReentrant {
        // always need this call because of mandatory executionFee user has to transfer in ETH
        _transferInETH();

        if (_executionFee < minExecutionFee) {
            revert InsufficientFee();
        }
        if (_shouldWrap) {
            if (_path[0] != weth) {
                revert InvalidPath();
            }
            if (msg.value != _executionFee.add(_amountIn)) {
                revert InvalidValue();
            }
        } else {
            if (msg.value != _executionFee) {
                revert InvalidValue();
            }
            IRouter(router).pluginTransfer(
                _path[0],
                msg.sender,
                address(this),
                _amountIn
            );
        }

        address _purchaseToken = _path[_path.length - 1];
        uint256 _purchaseTokenAmount;
        if (_path.length > 1) {
            if (_path[0] == _purchaseToken) {
                revert InvalidPath();
            }
            IERC20(_path[0]).safeTransfer(vault, _amountIn);
            _purchaseTokenAmount = _swap(_path, _minOut, address(this));
        } else {
            _purchaseTokenAmount = _amountIn;
        }

        {
            uint256 _purchaseTokenAmountUsd = IVault(vault).tokenToUsdMin(
                _purchaseToken,
                _purchaseTokenAmount
            );
            if (_purchaseTokenAmountUsd < minPurchaseTokenAmountUsd) {
                revert InsufficientCollateral();
            }
        }

        _createIncreaseOrder(
            msg.sender,
            _purchaseToken,
            _purchaseTokenAmount,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            _executionFee
        );
    }

    /// @notice Update an increase order
    /// @dev Emits an event `UpdateIncreaseOrder`
    /// @param _orderIndex The index of the order to update
    /// @param _sizeDelta The size delta
    /// @param _triggerPrice The trigger price
    /// @param _triggerAboveThreshold True if the threshold is above the trigger price, false otherwise
    function updateIncreaseOrder(
        uint256 _orderIndex,
        uint256 _sizeDelta,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) external nonReentrant {
        IncreaseOrder storage order = increaseOrders[msg.sender][_orderIndex];
        if (order.account == address(0)) {
            revert NonexistentOrder();
        }

        order.triggerPrice = _triggerPrice;
        order.triggerAboveThreshold = _triggerAboveThreshold;
        order.sizeDelta = _sizeDelta;

        emit UpdateIncreaseOrder(
            msg.sender,
            _orderIndex,
            order.collateralToken,
            order.indexToken,
            order.isLong,
            _sizeDelta,
            _triggerPrice,
            _triggerAboveThreshold
        );
    }

    /// @notice Execute an increase order
    /// @dev Emits an event `ExecuteIncreaseOrder`
    /// @param _address The account that owns the order
    /// @param _orderIndex The index of the increase order
    /// @param _feeReceiver The address to receive the fees
    function executeIncreaseOrder(
        address _address,
        uint256 _orderIndex,
        address payable _feeReceiver
    ) external nonReentrant {
        IncreaseOrder memory order = increaseOrders[_address][_orderIndex];
        if (order.account == address(0)) {
            revert NonexistentOrder();
        }

        // increase long should use max price
        // increase short should use min price
        (uint256 currentPrice, ) = validatePositionOrderPrice(
            order.triggerAboveThreshold,
            order.triggerPrice,
            order.indexToken,
            order.isLong,
            true
        );

        delete increaseOrders[_address][_orderIndex];

        IERC20(order.purchaseToken).safeTransfer(
            vault,
            order.purchaseTokenAmount
        );

        if (order.purchaseToken != order.collateralToken) {
            address[] memory path = new address[](2);
            path[0] = order.purchaseToken;
            path[1] = order.collateralToken;

            uint256 amountOut = _swap(path, 0, address(this));
            IERC20(order.collateralToken).safeTransfer(vault, amountOut);
        }

        IRouter(router).pluginIncreasePosition(
            order.account,
            order.collateralToken,
            order.indexToken,
            order.sizeDelta,
            order.isLong
        );

        // pay executor
        _transferOutETH(order.executionFee, _feeReceiver);

        emit ExecuteIncreaseOrder(
            order.account,
            _orderIndex,
            order.purchaseToken,
            order.purchaseTokenAmount,
            order.collateralToken,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee,
            currentPrice
        );
    }

    /// @notice Create a decrease order
    /// @param _indexToken The index token
    /// @param _sizeDelta The size delta
    /// @param _collateralToken The collateral token
    /// @param _collateralDelta The collateral delta
    /// @param _isLong True if the order is long, false if short
    /// @param _triggerPrice The trigger price
    /// @param _triggerAboveThreshold True if the threshold is above the trigger price, false otherwise
    function createDecreaseOrder(
        address _indexToken,
        uint256 _sizeDelta,
        address _collateralToken,
        uint256 _collateralDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) external payable nonReentrant {
        _transferInETH();

        if (msg.value < minExecutionFee) {
            // TODO: should be <= or <?
            revert InvalidValue();
        }

        _createDecreaseOrder(
            msg.sender,
            _collateralToken,
            _collateralDelta,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold
        );
    }

    /// @notice Execute a decrease order
    /// @dev Emits an event `ExecuteDecreaseOrder`
    /// @param _address The account that owns the decrease order
    /// @param _orderIndex The index of the decrease order
    /// @param _feeReceiver The address to receive the fees
    function executeDecreaseOrder(
        address _address,
        uint256 _orderIndex,
        address payable _feeReceiver
    ) external nonReentrant {
        DecreaseOrder memory order = decreaseOrders[_address][_orderIndex];
        if (order.account == address(0)) {
            revert NonexistentOrder();
        }

        // decrease long should use min price
        // decrease short should use max price
        (uint256 currentPrice, ) = validatePositionOrderPrice(
            order.triggerAboveThreshold,
            order.triggerPrice,
            order.indexToken,
            !order.isLong,
            true
        );

        delete decreaseOrders[_address][_orderIndex];

        uint256 amountOut = IRouter(router).pluginDecreasePosition(
            order.account,
            order.collateralToken,
            order.indexToken,
            order.collateralDelta,
            order.sizeDelta,
            order.isLong,
            address(this)
        );

        // transfer released collateral to user
        if (order.collateralToken == weth) {
            _transferOutETH(amountOut, payable(order.account));
        } else {
            IERC20(order.collateralToken).safeTransfer(
                order.account,
                amountOut
            );
        }

        // pay executor
        _transferOutETH(order.executionFee, _feeReceiver);

        emit ExecuteDecreaseOrder(
            order.account,
            _orderIndex,
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee,
            currentPrice
        );
    }

    /// @notice Update a decrease order
    /// @dev Emits an event `UpdateDecreaseOrder`
    /// @param _orderIndex The index of the decrease order
    /// @param _collateralDelta The collateral delta
    /// @param _sizeDelta The size delta
    /// @param _triggerPrice The price to trigger the decrease order
    /// @param _triggerAboveThreshold True if the threshold is above the trigger price, false otherwise
    function updateDecreaseOrder(
        uint256 _orderIndex,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) external nonReentrant {
        DecreaseOrder storage order = decreaseOrders[msg.sender][_orderIndex];
        if (order.account == address(0)) {
            revert NonexistentOrder();
        }

        order.triggerPrice = _triggerPrice;
        order.triggerAboveThreshold = _triggerAboveThreshold;
        order.sizeDelta = _sizeDelta;
        order.collateralDelta = _collateralDelta;

        emit UpdateDecreaseOrder(
            msg.sender,
            _orderIndex,
            order.collateralToken,
            _collateralDelta,
            order.indexToken,
            _sizeDelta,
            order.isLong,
            _triggerPrice,
            _triggerAboveThreshold
        );
    }

    /// @notice Cancel an increase order
    /// @dev Emits an event `CancelIncreaseOrder`
    /// @param _orderIndex The index of the order to cancel
    function cancelIncreaseOrder(uint256 _orderIndex) public nonReentrant {
        IncreaseOrder memory order = increaseOrders[msg.sender][_orderIndex];
        if (order.account == address(0)) {
            revert NonexistentOrder();
        }

        delete increaseOrders[msg.sender][_orderIndex];

        if (order.purchaseToken == weth) {
            _transferOutETH(
                order.executionFee.add(order.purchaseTokenAmount),
                payable(msg.sender)
            );
        } else {
            IERC20(order.purchaseToken).safeTransfer(
                msg.sender,
                order.purchaseTokenAmount
            );
            _transferOutETH(order.executionFee, payable(msg.sender));
        }

        emit CancelIncreaseOrder(
            order.account,
            _orderIndex,
            order.purchaseToken,
            order.purchaseTokenAmount,
            order.collateralToken,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee
        );
    }

    /// @notice Cancel a decrease order
    /// @dev Emits an event `CancelDecreaseOrder`
    /// @param _orderIndex The index of the decrease order
    function cancelDecreaseOrder(uint256 _orderIndex) public nonReentrant {
        DecreaseOrder memory order = decreaseOrders[msg.sender][_orderIndex];
        if (order.account == address(0)) {
            revert NonexistentOrder();
        }

        delete decreaseOrders[msg.sender][_orderIndex];
        _transferOutETH(order.executionFee, payable(msg.sender));

        emit CancelDecreaseOrder(
            order.account,
            _orderIndex,
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee
        );
    }

    /// @notice Cancel a swap order
    /// @dev Can only cancel the account's own swap orders
    /// @dev Emits an event `CancelSwapOrder`
    /// @param _orderIndex The index of the order to cancel
    function cancelSwapOrder(uint256 _orderIndex) public nonReentrant {
        SwapOrder memory order = swapOrders[msg.sender][_orderIndex];
        if (order.account == address(0)) {
            revert NonexistentOrder();
        }

        delete swapOrders[msg.sender][_orderIndex];

        if (order.path[0] == weth) {
            _transferOutETH(
                order.executionFee.add(order.amountIn),
                payable(msg.sender)
            );
        } else {
            IERC20(order.path[0]).safeTransfer(msg.sender, order.amountIn);
            _transferOutETH(order.executionFee, payable(msg.sender));
        }

        emit CancelSwapOrder(
            msg.sender,
            _orderIndex,
            order.path,
            order.amountIn,
            order.minOut,
            order.triggerRatio,
            order.triggerAboveThreshold,
            order.shouldUnwrap,
            order.executionFee
        );
    }

    /// @notice Get swap order
    /// @param _account The account address
    /// @param _orderIndex The index of the order
    function getSwapOrder(address _account, uint256 _orderIndex)
        public
        view
        returns (
            address path0,
            address path1,
            address path2,
            uint256 amountIn,
            uint256 minOut,
            uint256 triggerRatio,
            bool triggerAboveThreshold,
            bool shouldUnwrap,
            uint256 executionFee
        )
    {
        SwapOrder memory order = swapOrders[_account][_orderIndex];
        return (
            order.path.length > 0 ? order.path[0] : address(0),
            order.path.length > 1 ? order.path[1] : address(0),
            order.path.length > 2 ? order.path[2] : address(0),
            order.amountIn,
            order.minOut,
            order.triggerRatio,
            order.triggerAboveThreshold,
            order.shouldUnwrap,
            order.executionFee
        );
    }

    /// @notice Get minimum price of token in USDV
    /// @param _otherToken The token to get the minimum price of
    /// @return The minimum price of the token in USDV
    function getUsdvMinPrice(address _otherToken)
        public
        view
        returns (uint256)
    {
        // USDV_PRECISION is the same as 1 USDV
        uint256 redemptionAmount = IVault(vault).getRedemptionAmount(
            _otherToken,
            USDV_PRECISION
        );
        uint256 otherTokenPrice = IVault(vault).getMinPrice(_otherToken);

        uint256 otherTokenDecimals = IVault(vault).tokenDecimals(_otherToken);
        return
            redemptionAmount.mul(otherTokenPrice).div(10**otherTokenDecimals);
    }

    /// @notice Validate the swap order price is above the trigger threshold
    /// @param _path The path of the token swap
    /// @param _triggerRatio The trigger ratio for the swap
    /// @return True if the price is above the threshold, false otherwise
    function validateSwapOrderPriceWithTriggerAboveThreshold(
        address[] memory _path,
        uint256 _triggerRatio
    ) public view returns (bool) {
        if (_path.length != 2 && _path.length != 3) {
            revert InvalidPath();
        }

        // limit orders don't need this validation because minOut is enough
        // so this validation handles scenarios for stop orders only
        // when a user wants to swap when a price of tokenB increases relative to tokenA
        address tokenA = _path[0];
        address tokenB = _path[_path.length - 1];
        uint256 tokenAPrice;
        uint256 tokenBPrice;

        // 1. USDV doesn't have a price feed so we need to calculate it based on redemption amount of a specific token
        // That's why USDV price in USD can vary depending on the redepmtion token
        // 2. In complex scenarios with path=[USDV, ETH, BTC] we need to know how much ETH we'll get for provided USDV
        // to know how much BTC will be received
        // That's why in such scenario ETH should be used to determine price of USDV
        if (tokenA == usdv) {
            // with both _path.length == 2 or 3 we need usdv price against _path[1]
            // tokenAPrice = getUsdvMinPrice(_path[1]);
            tokenAPrice = 0;
        } else {
            tokenAPrice = IVault(vault).getMinPrice(tokenA);
        }

        if (tokenB == usdv) {
            tokenBPrice = PRICE_PRECISION;
        } else {
            tokenBPrice = IVault(vault).getMaxPrice(tokenB);
        }

        uint256 currentRatio = tokenBPrice.mul(PRICE_PRECISION).div(
            tokenAPrice
        );

        bool isValid = currentRatio > _triggerRatio;
        return isValid;
    }

    /// @notice Validate the price of a position order
    /// @param _triggerAboveThreshold True if the threshold is above the trigger ratio, false otherwise
    /// @param _triggerPrice The price of the trigger ratio
    /// @param _indexToken The index token of the position order
    /// @param _maximizePrice True if the price should be maximised, false otherwise
    function validatePositionOrderPrice(
        bool _triggerAboveThreshold,
        uint256 _triggerPrice,
        address _indexToken,
        bool _maximizePrice,
        bool _raise
    ) public view returns (uint256, bool) {
        uint256 currentPrice = _maximizePrice
            ? IVault(vault).getMaxPrice(_indexToken)
            : IVault(vault).getMinPrice(_indexToken);
        bool isPriceValid = _triggerAboveThreshold
            ? currentPrice > _triggerPrice
            : currentPrice < _triggerPrice;
        if (_raise) {
            if (!isPriceValid) {
                revert InvalidPrice();
            }
        }
        return (currentPrice, isPriceValid);
    }

    /// @notice Get a decrease order
    /// @param _account The account that created the order
    /// @param _orderIndex The index of the order to get
    function getDecreaseOrder(address _account, uint256 _orderIndex)
        public
        view
        returns (
            address collateralToken,
            uint256 collateralDelta,
            address indexToken,
            uint256 sizeDelta,
            bool isLong,
            uint256 triggerPrice,
            bool triggerAboveThreshold,
            uint256 executionFee
        )
    {
        DecreaseOrder memory order = decreaseOrders[_account][_orderIndex];
        return (
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee
        );
    }

    /// @notice Get an increase order
    /// @param _account The account that created the order
    /// @param _orderIndex The index of the order to get
    function getIncreaseOrder(address _account, uint256 _orderIndex)
        public
        view
        returns (
            address purchaseToken,
            uint256 purchaseTokenAmount,
            address collateralToken,
            address indexToken,
            uint256 sizeDelta,
            bool isLong,
            uint256 triggerPrice,
            bool triggerAboveThreshold,
            uint256 executionFee
        )
    {
        IncreaseOrder memory order = increaseOrders[_account][_orderIndex];
        return (
            order.purchaseToken,
            order.purchaseTokenAmount,
            order.collateralToken,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee
        );
    }

    function _createSwapOrder(
        address _account,
        address[] memory _path,
        uint256 _amountIn,
        uint256 _minOut,
        uint256 _triggerRatio,
        bool _triggerAboveThreshold,
        bool _shouldUnwrap,
        uint256 _executionFee
    ) private {
        uint256 _orderIndex = swapOrdersIndex[_account];
        SwapOrder memory order = SwapOrder(
            _account,
            _path,
            _amountIn,
            _minOut,
            _triggerRatio,
            _triggerAboveThreshold,
            _shouldUnwrap,
            _executionFee
        );
        swapOrdersIndex[_account] = _orderIndex.add(1);
        swapOrders[_account][_orderIndex] = order;

        emit CreateSwapOrder(
            _account,
            _orderIndex,
            _path,
            _amountIn,
            _minOut,
            _triggerRatio,
            _triggerAboveThreshold,
            _shouldUnwrap,
            _executionFee
        );
    }

    function _createIncreaseOrder(
        address _account,
        address _purchaseToken,
        uint256 _purchaseTokenAmount,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _executionFee
    ) private {
        uint256 _orderIndex = increaseOrdersIndex[msg.sender];
        IncreaseOrder memory order = IncreaseOrder(
            _account,
            _purchaseToken,
            _purchaseTokenAmount,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            _executionFee
        );
        increaseOrdersIndex[_account] = _orderIndex.add(1);
        increaseOrders[_account][_orderIndex] = order;

        emit CreateIncreaseOrder(
            _account,
            _orderIndex,
            _purchaseToken,
            _purchaseTokenAmount,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            _executionFee
        );
    }

    function _createDecreaseOrder(
        address _account,
        address _collateralToken,
        uint256 _collateralDelta,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) private {
        uint256 _orderIndex = decreaseOrdersIndex[_account];
        DecreaseOrder memory order = DecreaseOrder(
            _account,
            _collateralToken,
            _collateralDelta,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            msg.value
        );
        decreaseOrdersIndex[_account] = _orderIndex.add(1);
        decreaseOrders[_account][_orderIndex] = order;

        emit CreateDecreaseOrder(
            _account,
            _orderIndex,
            _collateralToken,
            _collateralDelta,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            msg.value
        );
    }

    function _transferInETH() private {
        if (msg.value != 0) {
            IWETH(weth).deposit{value: msg.value}();
        }
    }

    function _transferOutETH(uint256 _amountOut, address payable _receiver)
        private
    {
        IWETH(weth).withdraw(_amountOut);
        _receiver.sendValue(_amountOut);
    }

    function _swap(
        address[] memory _path,
        uint256 _minOut,
        address _receiver
    ) private returns (uint256) {
        if (_path.length == 2) {
            return _vaultSwap(_path[0], _path[1], _minOut, _receiver);
        }
        if (_path.length == 3) {
            uint256 midOut = _vaultSwap(_path[0], _path[1], 0, address(this));
            IERC20(_path[1]).safeTransfer(vault, midOut);
            return _vaultSwap(_path[1], _path[2], _minOut, _receiver);
        }

        revert InvalidPath();
    }

    function _vaultSwap(
        address _tokenIn,
        address _tokenOut,
        uint256 _minOut,
        address _receiver
    ) private returns (uint256) {
        uint256 amountOut;

        if (_tokenOut == usdv) {
            // buyUSDV
            amountOut = IVault(vault).buyUSDV(_tokenIn, _receiver);
        } else if (_tokenIn == usdv) {
            // sellUSDV
            amountOut = IVault(vault).sellUSDV(_tokenOut, _receiver);
        } else {
            // swap
            amountOut = IVault(vault).swap(_tokenIn, _tokenOut, _receiver);
        }

        if (amountOut < _minOut) {
            revert InsufficientAmountOut();
        }
        return amountOut;
    }
}
