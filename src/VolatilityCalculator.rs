// Required for Stylus contract
#![cfg_attr(not(feature = "export-abi"), no_main)]
extern crate alloc;

use alloc::string::{String, ToString};
use stylus_sdk::{
    alloy_primitives::{Address, U256},
    alloy_sol_types::{sol, SolError},
    evm, msg,
    prelude::*,
};

// Helper function to compute absolute difference between two prices
fn abs_diff(a: U256, b: U256) -> U256 {
    if a >= b {
        a - b
    } else {
        b - a
    }
}

// Compute variance from a set of prices
fn compute_variance(prices: &[U256], mean: U256) -> U256 {
    let mut sum_squared_diff = U256::ZERO;
    let len = U256::from(prices.len());
    
    if len == U256::ZERO {
        return U256::ZERO;
    }
    
    for price in prices {
        let diff = if *price >= mean {
            *price - mean
        } else {
            mean - *price
        };
        
        // Square the difference - handle carefully to avoid overflow
        let squared = diff.saturating_mul(diff);
        sum_squared_diff = sum_squared_diff.saturating_add(squared);
    }
    
    // Return variance (sum of squared differences divided by count)
    sum_squared_diff / len
}

// Calculate mean of an array of prices
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

// Calculate price movement intensity
fn calculate_price_movement_intensity(prices: &[U256]) -> U256 {
    if prices.len() <= 1 {
        return U256::ZERO;
    }
    
    let mut total_movement = U256::ZERO;
    
    // Calculate total absolute differences between consecutive prices
    for i in 1..prices.len() {
        total_movement = total_movement.saturating_add(abs_diff(prices[i], prices[i-1]));
    }
    
    // Average movement per price point
    total_movement / U256::from(prices.len() - 1)
}

// Calculate a relative volatility score based on price data
// Returns a score from 0 to 10000, where 0 is low volatility and 10000 is extreme volatility
fn calculate_relative_volatility(
    prices: &[U256],
    base_price: U256,
) -> U256 {
    // Calculate mean and variance
    let mean = compute_mean(prices);
    let variance = compute_variance(prices, mean);
    
    // Calculate movement intensity
    let movement_intensity = calculate_price_movement_intensity(prices);
    
    // Calculate variation coefficient (variance relative to the mean)
    let variation_coefficient = if mean > U256::ZERO {
        (variance * U256::from(10000)) / mean
    } else {
        U256::ZERO
    };
    
    // Calculate price range as a percentage of base price
    let mut min_price = U256::MAX;
    let mut max_price = U256::ZERO;
    
    for price in prices {
        if *price < min_price {
            min_price = *price;
        }
        if *price > max_price {
            max_price = *price;
        }
    }
    
    let price_range = if max_price > min_price {
        max_price - min_price
    } else {
        U256::ZERO
    };
    
    let price_range_percent = if base_price > U256::ZERO {
        (price_range * U256::from(10000)) / base_price
    } else {
        U256::ZERO
    };
    
    // Compute final volatility score as a weighted sum of factors
    // Weight variance more heavily than simple range
    let volatility_score = (variation_coefficient.saturating_mul(U256::from(6)) + 
                           price_range_percent.saturating_mul(U256::from(3)) +
                           movement_intensity.saturating_mul(U256::from(1))) / U256::from(10);
    
    // Cap at 10000
    if volatility_score > U256::from(10000) {
        U256::from(10000)
    } else {
        volatility_score
    }
}

// Contract errors
sol! {
    error InvalidPriceArray();
    error InvalidTimeWindow();
}

#[solidity_storage]
struct VolatilityCalculator {
    // Scaling factor used in calculations (10000 = 100%)
    scaling_factor: U256,
}

#[external]
impl VolatilityCalculator {
    pub fn constructor(&mut self) {
        self.scaling_factor = U256::from(10000);
    }
    
    /// Calculate a volatility score based on recent prices
    /// @param token0 Address of the first token (not used directly but included for optimization)
    /// @param token1 Address of the second token (not used directly but included for optimization)
    /// @param recent_prices Array of recent prices to analyze
    /// @param time_window The time window for which prices are being analyzed
    /// @return Volatility score (0-10000)
    pub fn calculate_volatility_score(
        &self,
        _token0: Address,
        _token1: Address, 
        recent_prices: Vec<U256>,
        time_window: U256
    ) -> Result<U256, SolError> {
        // Validate inputs
        if recent_prices.len() == 0 {
            return Err(InvalidPriceArray {}.into());
        }
        
        if time_window == U256::ZERO {
            return Err(InvalidTimeWindow {}.into());
        }
        
        // Use the mean price as the base price for comparisons
        let base_price = compute_mean(&recent_prices);
        
        // Calculate the volatility score
        let volatility_score = calculate_relative_volatility(&recent_prices, base_price);
        
        Ok(volatility_score)
    }
    
    /// Get a recommended fee based on volatility score
    /// @param volatility_score The volatility score (0-10000)
    /// @param base_fee The base fee to use when volatility is low
    /// @param max_fee The maximum fee to use when volatility is high
    /// @return The recommended fee
    pub fn get_recommended_fee(
        &self,
        volatility_score: U256,
        base_fee: u32,
        max_fee: u32
    ) -> Result<u32, SolError> {
        let base = U256::from(base_fee);
        let max = U256::from(max_fee);
        
        // Calculate dynamic fee based on volatility score
        // For very low volatility (0-1000), use base fee
        // For very high volatility (9000-10000), use max fee
        // For values in between, scale linearly
        
        if volatility_score <= U256::from(1000) {
            return Ok(base_fee);
        }
        
        if volatility_score >= U256::from(9000) {
            return Ok(max_fee);
        }
        
        // Normalized score from 0 to 8000
        let normalized_score = volatility_score.saturating_sub(U256::from(1000));
        
        // Calculate fee within the range
        let fee_range = max.saturating_sub(base);
        let fee_increase = (normalized_score.saturating_mul(fee_range)) / U256::from(8000);
        let dynamic_fee = base.saturating_add(fee_increase);
        
        // Convert back to u32 (safe because max_fee is a u32)
        Ok(dynamic_fee.as_u32())
    }
} 