// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {HookTest} from "./utils/HookTest.sol";
import {TokenFixture} from "./utils/TokenFixture.sol";
import {MockERC20} from "v4-core/src/test/MockERC20.sol";

import {LiquidityShield} from "../Counter.sol"; // Renamed from Counter.sol

// Mock volatility calculator for testing
contract MockVolatilityCalculator {
    uint256 private mockVolatilityScore;
    uint24 private mockRecommendedFee;
    
    function setMockVolatilityScore(uint256 _mockScore) external {
        mockVolatilityScore = _mockScore;
    }
    
    function setMockRecommendedFee(uint24 _mockFee) external {
        mockRecommendedFee = _mockFee;
    }
    
    function calculateVolatilityScore(
        address, 
        address, 
        uint256[] calldata, 
        uint256
    ) external view returns (uint256) {
        return mockVolatilityScore;
    }
    
    function getRecommendedFee(uint256, uint24, uint24) external view returns (uint24) {
        return mockRecommendedFee;
    }
}

contract LiquidityShieldTest is HookTest, TokenFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    
    // Test tokens
    MockERC20 token0;
    MockERC20 token1;
    
    // The hook under test
    LiquidityShield liquidityShield;
    MockVolatilityCalculator calculator;
    
    // Pool setup variables
    PoolKey poolKey;
    uint24 dynamicFee;
    uint24 initFee = 3000;
    int24 tickSpacing = 60;
    uint160 initSqrtPriceX96 = TickMath.getSqrtRatioAtTick(0);
    
    function setUp() public {
        // Create test tokens and pool manager
        (token0, token1) = deployMockTokens();
        
        // Deploy mock volatility calculator
        calculator = new MockVolatilityCalculator();
        calculator.setMockVolatilityScore(2000); // Default medium volatility
        calculator.setMockRecommendedFee(3000);  // Default 0.3% fee
        
        // Deploy hook
        liquidityShield = new LiquidityShield(
            IPoolManager(address(manager)),
            address(calculator)
        );
        
        // Create hook parameters
        dynamicFee = LPFeeLibrary.handleDynamicFee(initFee); // Make the fee dynamic
        
        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: dynamicFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(liquidityShield))
        });
        
        // Initialize the pool
        manager.initialize(poolKey, initSqrtPriceX96, "");
        
        // Provide tokens for testing
        token0.mint(address(this), 1000e18);
        token1.mint(address(this), 1000e18);
    }
    
    function test_PoolInitialization() public {
        // Verify the pool was created with the correct hook
        (uint160 sqrtPriceX96, , , , ) = manager.getSlot0(poolKey.toId());
        assertEq(sqrtPriceX96, initSqrtPriceX96);
        
        // Verify pool state was initialized correctly
        uint256 avgVolatility = liquidityShield.getAverageVolatility(poolKey.toId());
        assertEq(avgVolatility, 0);
    }
    
    function test_FeeAdjustment() public {
        // Set up mock volatility conditions
        calculator.setMockVolatilityScore(8000); // High volatility
        calculator.setMockRecommendedFee(6000);  // 0.6% fee
        
        // Get current fee
        uint24 beforeFee = manager.getLPFee(poolKey);
        assertEq(beforeFee, initFee);
        
        // Create swap params
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            zeroForOne: true,
            exactInput: true
        });
        
        // Execute a swap to trigger fee adjustment
        swap(poolKey, testSettings, 1e18, 0);
        
        // Should use the same fee for this swap (changes take effect on next swap)
        uint24 afterFee = manager.getLPFee(poolKey);
        
        // Assume UPDATE_THRESHOLD is set to a small value for testing purposes
        // If UPDATE_THRESHOLD is > 1, we need to make multiple swaps to trigger the update
        // This assumes UPDATE_THRESHOLD is set to 1 in test environment
        assertEq(afterFee, 6000);
    }
    
    function test_VolatilityTracking() public {
        // Set initial mock volatility to a medium level
        calculator.setMockVolatilityScore(5000);
        calculator.setMockRecommendedFee(5000); // 0.5% fee
        
        // Create swap params
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            zeroForOne: true,
            exactInput: true
        });
        
        // Execute a swap to update volatility tracking
        swap(poolKey, testSettings, 1e18, 0);
        
        // Check average volatility
        uint256 avgVolatility = liquidityShield.getAverageVolatility(poolKey.toId());
        assertEq(avgVolatility, 5000);
        
        // Test reset functionality
        liquidityShield.resetVolatilityTracking(poolKey.toId());
        avgVolatility = liquidityShield.getAverageVolatility(poolKey.toId());
        assertEq(avgVolatility, 0);
    }
    
    function test_FeeAdjustmentOnHighVolatility() public {
        // Set up extreme volatility conditions
        calculator.setMockVolatilityScore(9500); // Very high volatility
        calculator.setMockRecommendedFee(10000); // Max 1% fee
        
        // Create swap params
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            zeroForOne: true,
            exactInput: true
        });
        
        // Execute a swap to trigger fee adjustment
        swap(poolKey, testSettings, 1e18, 0);
        
        // Check that fee was increased to max level
        uint24 newFee = manager.getLPFee(poolKey);
        assertEq(newFee, 10000);
    }
    
    function test_FeeAdjustmentOnLowVolatility() public {
        // First set high volatility and adjust
        calculator.setMockVolatilityScore(9500);
        calculator.setMockRecommendedFee(10000);
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            zeroForOne: true,
            exactInput: true
        });
        
        // Execute a swap to set high fee
        swap(poolKey, testSettings, 1e18, 0);
        
        // Now set low volatility
        calculator.setMockVolatilityScore(500); // Very low volatility
        calculator.setMockRecommendedFee(3000); // Base fee
        
        // Execute another swap to trigger fee adjustment downward
        swap(poolKey, testSettings, 1e18, 0);
        
        // Check that fee was decreased to base level
        uint24 newFee = manager.getLPFee(poolKey);
        assertEq(newFee, 3000);
    }
} 