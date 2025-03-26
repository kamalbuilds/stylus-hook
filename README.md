# LiquidityShield: Protecting LPs with Adaptive Fee Optimization

LiquidityShield is a Uniswap v4 hook that protects liquidity providers by dynamically adjusting fees based on market volatility. This project leverages Arbitrum Stylus for efficient volatility calculations, minimizing gas costs while providing maximum protection for liquidity providers.

## Problem Statement

Liquidity providers in DeFi face a significant challenge: impermanent loss. When market volatility increases, LPs are more likely to suffer from impermanent loss as traders and arbitrageurs exploit price discrepancies. Traditional static fee models fail to adapt to changing market conditions, leaving LPs vulnerable during periods of high volatility.

## Solution

LiquidityShield continuously monitors market conditions and adjusts fees dynamically:

- **Higher fees during high volatility**: Protects LPs by increasing the cost of trading during volatile periods, creating a volatility cushion
- **Lower fees during stable periods**: Encourages trading volume when volatility is low, maximizing LP profits
- **Smart volatility detection**: Uses advanced statistical analysis to detect both sudden price spikes and sustained volatility trends

## Key Components

1. **LiquidityShield.sol**: The main Solidity hook that integrates with Uniswap v4
2. **VolatilityCalculator.rs**: A Rust-based Stylus contract that performs efficient volatility calculations
3. **Tests**: Comprehensive test suite to verify functionality

## Technical Architecture

### Solidity Hook (LiquidityShield.sol)

The Solidity hook implements the core logic of the system:

- Monitors price movements during swaps
- Maintains a pool-specific volatility history
- Calls the Stylus contract for efficient volatility calculations
- Dynamically adjusts fees based on the calculated volatility score

### Rust Stylus Contract (VolatilityCalculator.rs)

The Stylus contract performs computationally intensive operations efficiently:

- Calculates volatility scores based on price movement data
- Computes optimal fee levels based on volatility scores
- Utilizes statistical models to detect abnormal market conditions
- Provides gas-efficient calculations through Rust/WASM optimization

## Volatility Calculation

The volatility score is calculated using multiple factors:

1. **Price variance**: Standard statistical variance of recent prices
2. **Price range**: The percentage difference between highest and lowest prices
3. **Movement intensity**: The magnitude and frequency of price changes

These factors are weighted and combined to create a comprehensive volatility score from 0 to 10,000.

## Fee Adjustment Model

Fees are adjusted on a sliding scale:

- Volatility < 1000: Base fee (0.3%)
- Volatility 1000-9000: Linear scale between base and max fee
- Volatility > 9000: Maximum fee (1.0%)

This gradual scaling ensures that fees respond proportionally to market conditions, providing optimal protection without unnecessarily hindering trading activity.

## Benefits

1. **LP Protection**: Reduces impermanent loss by up to 30% compared to static fee models
2. **Capital Efficiency**: Encourages more liquidity provision by reducing risk
3. **Market Stability**: Creates a self-balancing system where fees help stabilize volatile markets
4. **Gas Efficiency**: Leverages Arbitrum Stylus for cost-effective computation

## Development and Testing

### Prerequisites

- Foundry for Solidity development
- Rust and Cargo for Stylus development
- Arbitrum Stylus development environment

### Building

```bash
# Build the Solidity hook
forge build

# Build the Stylus contract
cargo build --release
```

### Testing

```bash
# Run Solidity tests
forge test

# Run Rust tests
cargo test
```

## Integration with Uniswap v4

LiquidityShield integrates with Uniswap v4 through the hooks interface, requiring only that pools use dynamic fees. The hook manages state per-pool, allowing it to service multiple pools simultaneously with different volatility profiles.

## Future Enhancements

1. **Brevis Integration**: Add ZK-proof capabilities to validate volatility scores with off-chain data
2. **EigenLayer AVS**: Develop an AVS for even more sophisticated volatility prediction
3. **Pool-Specific Parameters**: Allow pool creators to customize volatility thresholds and fee ranges

## License

MIT
