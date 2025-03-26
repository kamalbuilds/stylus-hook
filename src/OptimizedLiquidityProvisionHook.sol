// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interfaces for external systems
interface IPositionOptimizer {
    function calculateOptimalPositionBounds(
        address token0,
        address token1,
        uint256[] calldata recentPrices,
        uint256 liquidityAmount
    ) external view returns (int24 lowerTick, int24 upperTick);
    
    function shouldRebalance(
        address token0,
        address token1,
        int24 currentLowerTick,
        int24 currentUpperTick,
        uint256[] calldata recentPrices
    ) external view returns (bool, int24 newLowerTick, int24 newUpperTick);
}

// Interface for EigenLayer Service Manager
interface IPositionOracleServiceManager {
    struct PriceData {
        address token0;
        address token1;
        uint256[] prices;
        uint32 dataTimestamp;
    }
    
    function createPriceDataTask(address token0, address token1) external returns (uint32 taskIndex);
    
    function submitPriceData(
        uint32 taskIndex,
        PriceData calldata data,
        bytes calldata signatures
    ) external returns (bool);
    
    function getLatestPriceData(address token0, address token1) external view returns (PriceData memory);
}

// Interface for Flaunch integration
interface IPositionManager {
    struct FlaunchParams {
        string name;
        string symbol;
        string tokenUri;
        uint256 initialTokenFairLaunch;
        uint256 premineAmount;
        address creator;
        uint256 creatorFeeAllocation;
        uint256 flaunchAt;
        bytes initialPriceParams;
        bytes feeCalculatorParams;
    }
    
    function flaunch(FlaunchParams calldata params) external returns (address);
    function flaunchContract() external view returns (address);
}

interface IRevenueManager {
    struct FlaunchToken {
        address flaunchContract;
        uint256 tokenId;
    }
    
    struct InitializeParams {
        address payable treasury;
        address payable minter;
        uint256 mintFee;
    }
    
    function initialize(
        FlaunchToken calldata token,
        address owner,
        bytes calldata params
    ) external;
    
    function claim() external returns (uint256, uint256);
}

interface ITreasuryManagerFactory {
    function deployManager(address implementation) external returns (address payable);
}

/**
 * @title OptimizedLiquidityProvisionHook
 * @notice A Uniswap v4 hook that optimizes LP positions, validates data with EigenLayer,
 * and incentivizes liquidity provision through Flaunch tokens
 */
contract OptimizedLiquidityProvisionHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using LPFeeLibrary for uint24;
    
    // State variables
    IPositionOptimizer public positionOptimizer;
    IPositionOracleServiceManager public serviceManager;
    IPositionManager public positionManager;
    ITreasuryManagerFactory public treasuryManagerFactory;
    address public managerImplementation;
    
    // Tracking of price data tasks
    mapping(PoolId => uint32) public priceDataTasks;
    
    // Recent price storage (limited circular buffer)
    uint256 public constant PRICE_WINDOW_SIZE = 10;
    mapping(PoolId => uint256[]) public recentPrices;
    mapping(PoolId => uint256) public lastPriceIndex;
    
    // Flaunch tokens for each pool
    struct PoolToken {
        address tokenAddress;
        uint256 tokenId;
        address payable manager;
        bool initialized;
    }
    
    mapping(PoolId => PoolToken) public poolTokens;
    
    // Events
    event PoolOptimized(PoolId indexed poolId, int24 lowerTick, int24 upperTick);
    event PriceDataUpdated(PoolId indexed poolId, uint256 price);
    event TokenCreated(PoolId indexed poolId, address tokenAddress, uint256 tokenId);
    event FeesReinvested(PoolId indexed poolId, uint256 amount);
    
    // Errors
    error InvalidOptimizerAddress();
    error InvalidServiceManagerAddress();
    error InvalidPositionManagerAddress();
    error MustUseDynamicFee();
    error TokenAlreadyCreated();
    
    constructor(
        IPoolManager _poolManager,
        address _positionOptimizer,
        address _serviceManager,
        address _positionManager,
        address _treasuryManagerFactory,
        address _managerImplementation
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        if (_positionOptimizer == address(0)) revert InvalidOptimizerAddress();
        if (_serviceManager == address(0)) revert InvalidServiceManagerAddress();
        if (_positionManager == address(0)) revert InvalidPositionManagerAddress();
        
        positionOptimizer = IPositionOptimizer(_positionOptimizer);
        serviceManager = IPositionOracleServiceManager(_serviceManager);
        positionManager = IPositionManager(_positionManager);
        treasuryManagerFactory = ITreasuryManagerFactory(_treasuryManagerFactory);
        managerImplementation = _managerImplementation;
    }
    
    /**
     * @notice Set the position optimizer address
     * @param _newOptimizer Address of the new position optimizer
     */
    function setPositionOptimizer(address _newOptimizer) external onlyOwner {
        if (_newOptimizer == address(0)) revert InvalidOptimizerAddress();
        positionOptimizer = IPositionOptimizer(_newOptimizer);
    }
    
    /**
     * @notice Set the EigenLayer service manager address
     * @param _newServiceManager Address of the new service manager
     */
    function setServiceManager(address _newServiceManager) external onlyOwner {
        if (_newServiceManager == address(0)) revert InvalidServiceManagerAddress();
        serviceManager = IPositionOracleServiceManager(_newServiceManager);
    }
    
    /**
     * @notice Define which hooks are implemented
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    
    /**
     * @notice Ensure pools using this hook have dynamic fees enabled
     */
    function beforeInitialize(address, PoolKey calldata key, uint160) 
        external 
        view 
        override 
        returns (bytes4) 
    {
        // Ensure the pool uses dynamic fees
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }
    
    /**
     * @notice Initialize the pool with a price data task and create a Flaunch token
     */
    function afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24, bytes calldata) 
        external 
        override 
        returns (bytes4) 
    {
        PoolId poolId = key.toId();
        
        // Initialize price tracking
        if (recentPrices[poolId].length == 0) {
            uint256[] memory initialPrices = new uint256[](PRICE_WINDOW_SIZE);
            uint256 currentPrice = uint256(sqrtPriceX96) ** 2;
            
            for (uint256 i = 0; i < PRICE_WINDOW_SIZE; i++) {
                initialPrices[i] = currentPrice;
            }
            
            recentPrices[poolId] = initialPrices;
            lastPriceIndex[poolId] = 0;
        }
        
        // Create a price data task in EigenLayer
        uint32 taskIndex = serviceManager.createPriceDataTask(
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1)
        );
        priceDataTasks[poolId] = taskIndex;
        
        // Create a Flaunch token if it doesn't exist already and one token is ETH
        if (!poolTokens[poolId].initialized) {
            if (Currency.unwrap(key.currency0) == address(0) || 
                Currency.unwrap(key.currency1) == address(0)) {
                _createFlaunchToken(key);
            }
        }
        
        return this.afterInitialize.selector;
    }
    
    /**
     * @notice Create a Flaunch token for the pool
     */
    function _createFlaunchToken(PoolKey calldata key) internal {
        PoolId poolId = key.toId();
        
        // Only create token once
        if (poolTokens[poolId].initialized) revert TokenAlreadyCreated();
        
        // Create Flaunch token
        string memory tokenSymbol = string(abi.encodePacked(
            "LP",
            Currency.unwrap(key.currency0) == address(0) ? "ETH" : "TKN",
            Currency.unwrap(key.currency1) == address(0) ? "ETH" : "TKN"
        ));
        
        // Flaunch the new token
        address tokenAddress = positionManager.flaunch(
            IPositionManager.FlaunchParams({
                name: string(abi.encodePacked("Optimized LP Token ", tokenSymbol)),
                symbol: tokenSymbol,
                tokenUri: "https://optimized-lp.token/",
                initialTokenFairLaunch: 50e27,
                premineAmount: 0,
                creator: address(this),
                creatorFeeAllocation: 10_00, // 10% fees
                flaunchAt: 0,
                initialPriceParams: abi.encode(''),
                feeCalculatorParams: abi.encode(1_000)
            })
        );
        
        // Get the flaunched tokenId
        uint256 tokenId = positionManager.flaunchContract().tokenId(tokenAddress);
        
        // Deploy a revenue manager for the token
        address payable manager = treasuryManagerFactory.deployManager(managerImplementation);
        
        // Initialize the manager with the token
        positionManager.flaunchContract().approve(manager, tokenId);
        IRevenueManager(manager).initialize(
            IRevenueManager.FlaunchToken(positionManager.flaunchContract(), tokenId),
            address(this),
            abi.encode(
                IRevenueManager.InitializeParams(
                    payable(address(this)),
                    payable(address(this)),
                    100_00
                )
            )
        );
        
        // Store the token information
        poolTokens[poolId] = PoolToken({
            tokenAddress: tokenAddress,
            tokenId: tokenId,
            manager: manager,
            initialized: true
        });
        
        emit TokenCreated(poolId, tokenAddress, tokenId);
    }
    
    /**
     * @notice Update price data from EigenLayer operators before swaps
     */
    function beforeSwap(
        address, 
        PoolKey calldata key, 
        IPoolManager.SwapParams calldata, 
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // Get current state
        (uint160 sqrtPriceX96, , , ) = poolManager.getPoolState(key);
        PoolId poolId = key.toId();
        
        // Update price tracking
        uint256 currentPrice = uint256(sqrtPriceX96) ** 2;
        uint256 idx = lastPriceIndex[poolId];
        recentPrices[poolId][idx] = currentPrice;
        lastPriceIndex[poolId] = (idx + 1) % PRICE_WINDOW_SIZE;
        
        emit PriceDataUpdated(poolId, currentPrice);
        
        // If this pool has a Flaunch token, claim and reinvest fees
        if (poolTokens[poolId].initialized) {
            _claimAndReinvestFees(key);
        }
        
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
    
    /**
     * @notice Claim and reinvest fees from the Flaunch token
     */
    function _claimAndReinvestFees(PoolKey calldata key) internal {
        PoolId poolId = key.toId();
        PoolToken storage poolToken = poolTokens[poolId];
        
        if (!poolToken.initialized) {
            return;
        }
        
        // Claim fees from the manager
        (, uint256 ethReceived) = IRevenueManager(poolToken.manager).claim();
        
        // If we received ETH, donate it to the pool
        if (ethReceived > 0) {
            // Only donate if one of the currencies is ETH
            if (Currency.unwrap(key.currency0) == address(0)) {
                poolManager.donate({
                    key: key,
                    amount0: ethReceived,
                    amount1: 0,
                    hookData: ''
                });
                emit FeesReinvested(poolId, ethReceived);
            } else if (Currency.unwrap(key.currency1) == address(0)) {
                poolManager.donate({
                    key: key,
                    amount0: 0,
                    amount1: ethReceived,
                    hookData: ''
                });
                emit FeesReinvested(poolId, ethReceived);
            }
        }
    }
    
    /**
     * @notice After swap, check if we have received new price data from EigenLayer
     */
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        uint32 taskIndex = priceDataTasks[poolId];
        
        // Check if we have new price data from EigenLayer
        if (taskIndex > 0) {
            // Attempt to get the latest price data
            IPositionOracleServiceManager.PriceData memory priceData = 
                serviceManager.getLatestPriceData(
                    Currency.unwrap(key.currency0),
                    Currency.unwrap(key.currency1)
                );
            
            // If we have recent data and enough prices, update our local cache
            if (priceData.dataTimestamp > 0 && priceData.prices.length > 0) {
                // Take the most recent price and add it to our buffer
                uint256 latestPrice = priceData.prices[priceData.prices.length - 1];
                uint256 idx = lastPriceIndex[poolId];
                recentPrices[poolId][idx] = latestPrice;
                lastPriceIndex[poolId] = (idx + 1) % PRICE_WINDOW_SIZE;
                
                emit PriceDataUpdated(poolId, latestPrice);
            }
        }
        
        return (this.afterSwap.selector, 0);
    }
    
    /**
     * @notice Before adding liquidity, suggest optimal position bounds
     */
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata data
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        
        // Check if we should optimize the position
        if (data.length > 0 && keccak256(data) == keccak256(abi.encode("optimize"))) {
            // Calculate optimal position bounds using the Stylus optimizer
            (int24 lowerTick, int24 upperTick) = positionOptimizer.calculateOptimalPositionBounds(
                Currency.unwrap(key.currency0),
                Currency.unwrap(key.currency1),
                recentPrices[poolId],
                uint256(uint128(params.liquidityDelta))
            );
            
            emit PoolOptimized(poolId, lowerTick, upperTick);
            
            // Note: We can't modify the params here, but we can emit an event with the suggested bounds
            // The user would need to monitor these events and submit a new transaction with the optimized bounds
        }
        
        // If this pool has a Flaunch token, claim and reinvest fees
        if (poolTokens[poolId].initialized) {
            _claimAndReinvestFees(key);
        }
        
        return this.beforeAddLiquidity.selector;
    }
    
    /**
     * @notice Before removing liquidity, check if fees need to be reinvested
     */
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        
        // If this pool has a Flaunch token, claim and reinvest fees
        if (poolTokens[poolId].initialized) {
            _claimAndReinvestFees(key);
        }
        
        return this.beforeRemoveLiquidity.selector;
    }
    
    /**
     * @notice Manually submit price data from EigenLayer operators
     */
    function submitPriceDataFromEigenLayer(
        PoolKey calldata key,
        uint32 taskIndex,
        IPositionOracleServiceManager.PriceData calldata data,
        bytes calldata signatures
    ) external {
        PoolId poolId = key.toId();
        
        // Verify the task index matches
        require(priceDataTasks[poolId] == taskIndex, "Invalid task index");
        
        // Submit the price data to the service manager
        bool success = serviceManager.submitPriceData(taskIndex, data, signatures);
        require(success, "Failed to submit price data");
        
        // Update our local cache with the new price data
        if (data.prices.length > 0) {
            uint256 latestPrice = data.prices[data.prices.length - 1];
            uint256 idx = lastPriceIndex[poolId];
            recentPrices[poolId][idx] = latestPrice;
            lastPriceIndex[poolId] = (idx + 1) % PRICE_WINDOW_SIZE;
            
            emit PriceDataUpdated(poolId, latestPrice);
        }
    }
    
    // Allow the contract to receive ETH
    receive() external payable {}
} 