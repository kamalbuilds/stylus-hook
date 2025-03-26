// Required for Stylus contract
#![cfg_attr(not(feature = "export-abi"), no_main)]
extern crate alloc;

use alloc::string::{String, ToString};
use alloc::vec::Vec;
use stylus_sdk::{
    alloy_primitives::{Address, U256, I256},
    alloy_sol_types::{sol, SolError},
    evm, msg,
    prelude::*,
};

// Helper function to compute mean of prices
fn compute_mean(prices: &[U256]) -> U256 {
    let mut sum = U256::ZERO;
    let len = prices.len();
    
    if len == 0 {
        return U256::ZERO;
    }
    
    for price in prices {
        sum = sum.saturating_add(*price);
    }
    
    sum / U256::from(len)
}

// Helper function to compute standard deviation
fn compute_std_dev(prices: &[U256], mean: U256) -> U256 {
    let len = prices.len();
    
    if len <= 1 {
        return U256::ZERO;
    }
    
    let mut sum_squared_diff = U256::ZERO;
    
    for price in prices {
        let diff = if *price >= mean {
            *price - mean
        } else {
            mean - *price
        };
        
        // Square the difference (handle overflow)
        let squared = diff.saturating_mul(diff);
        sum_squared_diff = sum_squared_diff.saturating_add(squared);
    }
    
    // Calculate standard deviation (sqrt of variance)
    let variance = sum_squared_diff / U256::from(len);
    sqrt(variance)
}

// Helper function to compute square root
fn sqrt(n: U256) -> U256 {
    if n == U256::ZERO {
        return U256::ZERO;
    }
    
    let mut x = n;
    let mut y = (x + U256::from(1)) / U256::from(2);
    
    while y < x {
        x = y;
        y = (x + n / x) / U256::from(2);
    }
    
    x
}

// Helper function to convert from price to tick (simplified)
fn price_to_tick(price: U256) -> i32 {
    // This is a very simplified version. In a real implementation,
    // we would use TickMath's logic to convert from price to tick.
    let price_f = price.as_u128() as f64;
    let tick_f = (price_f.ln() / 1.0001f64.ln()) as i32;
    tick_f
}

// Helper function to ensure tick is divisible by spacing
fn round_to_spacing(tick: i32, spacing: i32) -> i32 {
    (tick / spacing) * spacing
}

// Contract errors
sol! {
    error InvalidPriceArray();
    error InvalidTickSpacing();
}

#[solidity_storage]
struct PositionOptimizer {
    // Scaling factor for precision
    scaling_factor: U256,
}

#[external]
impl PositionOptimizer {
    pub fn constructor(&mut self) {
        self.scaling_factor = U256::from(10000);
    }
    
    /// Calculate the optimal position bounds for a liquidity position
    /// @param token0 Address of the first token
    /// @param token1 Address of the second token
    /// @param recent_prices Array of recent prices
    /// @param liquidity_amount Amount of liquidity to provide
    /// @return Lower and upper tick bounds
    pub fn calculate_optimal_position_bounds(
        &self,
        _token0: Address,
        _token1: Address,
        recent_prices: Vec<U256>,
        _liquidity_amount: U256
    ) -> Result<(i32, i32), SolError> {
        // Validate inputs
        if recent_prices.len() < 2 {
            return Err(InvalidPriceArray {}.into());
        }
        
        // Calculate price statistics
        let mean_price = compute_mean(&recent_prices);
        let std_dev = compute_std_dev(&recent_prices, mean_price);
        
        // Convert mean price to a tick
        let mean_tick = price_to_tick(mean_price);
        
        // Calculate standard deviation as a percentage of the mean price
        let std_dev_percentage = if mean_price > U256::ZERO {
            (std_dev * U256::from(100)) / mean_price
        } else {
            U256::ZERO
        };
        
        // Calculate tick range based on volatility
        // Higher volatility = wider range
        let tick_spacing = 60; // Default tick spacing
        let volatility_multiplier = if std_dev_percentage < U256::from(5) {
            // Low volatility: tighter range
            20
        } else if std_dev_percentage < U256::from(10) {
            // Medium volatility
            30
        } else if std_dev_percentage < U256::from(20) {
            // High volatility
            50
        } else {
            // Very high volatility: wide range
            100
        };
        
        // Calculate the tick range
        let tick_range = volatility_multiplier * tick_spacing;
        
        // Calculate lower and upper ticks
        let lower_tick = round_to_spacing(mean_tick - tick_range, tick_spacing);
        let upper_tick = round_to_spacing(mean_tick + tick_range, tick_spacing);
        
        Ok((lower_tick, upper_tick))
    }
    
    /// Determine if a position should be rebalanced based on current market conditions
    /// @param token0 Address of the first token
    /// @param token1 Address of the second token
    /// @param current_lower_tick Current lower tick bound
    /// @param current_upper_tick Current upper tick bound
    /// @param recent_prices Array of recent prices
    /// @return (should_rebalance, new_lower_tick, new_upper_tick)
    pub fn should_rebalance(
        &self,
        token0: Address,
        token1: Address,
        current_lower_tick: i32,
        current_upper_tick: i32,
        recent_prices: Vec<U256>
    ) -> Result<(bool, i32, i32), SolError> {
        // Calculate optimal bounds based on current conditions
        let (optimal_lower, optimal_upper) = self.calculate_optimal_position_bounds(
            token0,
            token1,
            recent_prices,
            U256::ZERO // Not relevant for this calculation
        )?;
        
        // Check if price is outside the current range or close to the edge
        let current_price = recent_prices[recent_prices.len() - 1];
        let current_tick = price_to_tick(current_price);
        
        // Calculate how far the current price is from the bounds (as a percentage of the range)
        let current_range = current_upper_tick - current_lower_tick;
        
        if current_range <= 0 {
            return Err(InvalidTickSpacing {}.into());
        }
        
        // Calculate distance from bounds as percentage of range
        let dist_from_lower = current_tick - current_lower_tick;
        let dist_from_upper = current_upper_tick - current_tick;
        
        let lower_pct = (dist_from_lower * 100) / current_range;
        let upper_pct = (dist_from_upper * 100) / current_range;
        
        // Determine if rebalancing is needed
        let should_rebalance = 
            // Price outside range
            current_tick <= current_lower_tick || 
            current_tick >= current_upper_tick ||
            // Price close to edge (less than 10% from edge)
            lower_pct < 10 || 
            upper_pct < 10 ||
            // Optimal range is significantly different
            (optimal_lower - current_lower_tick).abs() > (current_range / 4) ||
            (optimal_upper - current_upper_tick).abs() > (current_range / 4);
        
        Ok((should_rebalance, optimal_lower, optimal_upper))
    }
    
    /// Calculate the capital efficiency of a position
    /// @param current_lower_tick Current lower tick bound
    /// @param current_upper_tick Current upper tick bound
    /// @param current_tick Current tick
    /// @return Efficiency percentage (0-100)
    pub fn calculate_position_efficiency(
        &self,
        current_lower_tick: i32,
        current_upper_tick: i32,
        current_tick: i32
    ) -> Result<u32, SolError> {
        if current_upper_tick <= current_lower_tick {
            return Err(InvalidTickSpacing {}.into());
        }
        
        // Check if price is in range
        if current_tick < current_lower_tick || current_tick > current_upper_tick {
            return Ok(0); // 0% efficiency if price is out of range
        }
        
        // Calculate efficiency based on position in range
        // Optimal efficiency is when price is in the middle of the range
        let range_size = current_upper_tick - current_lower_tick;
        let distance_from_middle = (current_tick - current_lower_tick - (range_size / 2)).abs();
        
        // Calculate efficiency as percentage (higher when closer to middle)
        let max_distance = range_size / 2;
        
        if max_distance == 0 {
            return Ok(100);
        }
        
        let efficiency = 100 - ((distance_from_middle * 100) / max_distance) as u32;
        
        Ok(efficiency)
    }
} 