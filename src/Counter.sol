// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interface for the Stylus contract that will calculate volatility metrics
interface IVolatilityCalculator {
    // Calculate volatility score based on recent price movements
    function calculateVolatilityScore(
        address token0, 
        address token1, 
        uint256[] calldata recentPrices, 
        uint256 timeWindow
    ) external view returns (uint256);
    
    // Get recommended fee based on volatility score
    function getRecommendedFee(uint256 volatilityScore, uint24 baseFee, uint24 maxFee) 
        external view returns (uint24);
}

/**
 * @title LiquidityShield
 * @notice A Uniswap v4 hook that protects liquidity providers by dynamically adjusting 
 * fees based on market volatility and price movements.
 * @dev Integrates with a Stylus Rust contract for efficient volatility calculations
 */
contract LiquidityShield is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using LPFeeLibrary for uint24;
    
    // Constants
    uint24 public constant BASE_FEE = 3000; // 0.3%
    uint24 public constant MAX_FEE = 10000; // 1.0%
    uint256 public constant PRICE_WINDOW_SIZE = 10; // Number of prices to track
    uint256 public constant UPDATE_THRESHOLD = 20; // Number of blocks between fee updates
    
    // State variables
    IVolatilityCalculator public volatilityCalculator;
    
    // Pool-specific state
    mapping(PoolId => PoolState) public poolStates;
    
    // Structure to track pool-specific data
    struct PoolState {
        uint256[] recentPrices;        // Circular buffer of recent prices
        uint256 lastPriceIndex;        // Index to track circular buffer position
        uint256 lastUpdateBlock;       // Last block when fees were updated
        uint24 currentFee;             // Current fee for the pool
        uint256 cumulativeVolatility;  // Cumulative volatility score
        uint256 updateCount;           // Number of updates to calculate average
    }
    
    // Events
    event FeeUpdated(PoolId indexed poolId, uint24 oldFee, uint24 newFee, uint256 volatilityScore);
    event VolatilityCalculatorUpdated(address indexed oldCalculator, address indexed newCalculator);
    event ProtectionEnabled(PoolId indexed poolId);
    
    // Errors
    error MustUseDynamicFee();
    error InvalidVolatilityCalculator();
    error UpdateTooFrequent();
    
    constructor(IPoolManager _poolManager, address _volatilityCalculator) 
        BaseHook(_poolManager) 
        Ownable(msg.sender) 
    {
        if (_volatilityCalculator == address(0)) revert InvalidVolatilityCalculator();
        volatilityCalculator = IVolatilityCalculator(_volatilityCalculator);
    }
    
    /**
     * @notice Updates the volatility calculator contract
     * @param _newCalculator Address of the new volatility calculator
     */
    function setVolatilityCalculator(address _newCalculator) external onlyOwner {
        if (_newCalculator == address(0)) revert InvalidVolatilityCalculator();
        address oldCalculator = address(volatilityCalculator);
        volatilityCalculator = IVolatilityCalculator(_newCalculator);
        emit VolatilityCalculatorUpdated(oldCalculator, _newCalculator);
    }
    
    /**
     * @notice Hook permissions required for this contract
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
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
        // Verify the pool is using dynamic fees
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }
    
    /**
     * @notice Initialize the pool state with default values
     */
    function afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24, bytes calldata) 
        external 
        override 
        returns (bytes4) 
    {
        PoolId poolId = key.toId();
        
        // Initialize pool state if not already done
        if (poolStates[poolId].recentPrices.length == 0) {
            // Initialize price tracking
            uint256[] memory initialPrices = new uint256[](PRICE_WINDOW_SIZE);
            for (uint256 i = 0; i < PRICE_WINDOW_SIZE; i++) {
                initialPrices[i] = uint256(sqrtPriceX96) ** 2;
            }
            
            // Set initial pool state
            poolStates[poolId] = PoolState({
                recentPrices: initialPrices,
                lastPriceIndex: 0,
                lastUpdateBlock: block.number,
                currentFee: BASE_FEE,
                cumulativeVolatility: 0,
                updateCount: 0
            });
            
            // Set initial fee
            poolManager.updateDynamicLPFee(key, BASE_FEE);
            
            emit ProtectionEnabled(poolId);
        }
        
        return this.afterInitialize.selector;
    }
    
    /**
     * @notice Before each swap, check if fee needs to be updated
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
        PoolState storage state = poolStates[poolId];
        
        // Update circular buffer with current price
        state.recentPrices[state.lastPriceIndex] = currentPrice;
        state.lastPriceIndex = (state.lastPriceIndex + 1) % PRICE_WINDOW_SIZE;
        
        // Check if we should update fee (not too frequent)
        if (block.number >= state.lastUpdateBlock + UPDATE_THRESHOLD) {
            // Calculate volatility and update fee
            uint256 volatilityScore = volatilityCalculator.calculateVolatilityScore(
                Currency.unwrap(key.currency0),
                Currency.unwrap(key.currency1),
                state.recentPrices,
                PRICE_WINDOW_SIZE
            );
            
            // Update volatility tracking
            state.cumulativeVolatility += volatilityScore;
            state.updateCount++;
            
            // Get recommended fee based on volatility
            uint24 newFee = volatilityCalculator.getRecommendedFee(
                volatilityScore,
                BASE_FEE,
                MAX_FEE
            );
            
            // Only update if fee is different
            if (newFee != state.currentFee) {
                uint24 oldFee = state.currentFee;
                state.currentFee = newFee;
                
                // Update fee on pool
                poolManager.updateDynamicLPFee(key, newFee);
                
                emit FeeUpdated(poolId, oldFee, newFee, volatilityScore);
            }
            
            // Update last update block
            state.lastUpdateBlock = block.number;
        }
        
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
    
    /**
     * @notice After swap hook to track market activity
     */
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        return (this.afterSwap.selector, 0);
    }
    
    /**
     * @notice Get the average volatility for a pool
     * @param poolId The ID of the pool
     * @return The average volatility score
     */
    function getAverageVolatility(PoolId poolId) external view returns (uint256) {
        PoolState storage state = poolStates[poolId];
        
        if (state.updateCount == 0) {
            return 0;
        }
        
        return state.cumulativeVolatility / state.updateCount;
    }
    
    /**
     * @notice Reset volatility tracking for a pool
     * @param poolId The ID of the pool to reset
     */
    function resetVolatilityTracking(PoolId poolId) external onlyOwner {
        PoolState storage state = poolStates[poolId];
        state.cumulativeVolatility = 0;
        state.updateCount = 0;
    }
}
