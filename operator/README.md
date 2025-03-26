# LiquidityShield Price Operator

This is the price operator for the LiquidityShield project, built for EigenLayer AVS integration. The operator fetches and submits price data for token pairs to be used in the LiquidityShield volatility calculations.

## Features

- Monitors and responds to price data tasks from the ServiceManager contract
- Fetches real-time price data from external APIs (CoinGecko by default)
- Signs price data with the operator's private key
- Submits signed price data back to the ServiceManager
- Handles task status updates and error reporting

## Setup

### Prerequisites

- Node.js (v16+)
- npm or yarn
- An Ethereum wallet with funds for gas (on the network where ServiceManager is deployed)
- CoinGecko API key (optional, but recommended for production)

### Installation

1. Install dependencies:

```bash
npm install
```

2. Create a `.env` file with the following variables:

```
# Network settings
RPC_URL=https://sepolia-rollup.arbitrum.io/rpc

# Operator settings
OPERATOR_PRIVATE_KEY=your_private_key_here

# Service Manager contract
SERVICE_MANAGER_ADDRESS=deployed_contract_address

# API settings
PRICE_API_URL=https://api.coingecko.com/api/v3
PRICE_API_KEY=your_api_key_here

# Operator settings
POLLING_INTERVAL=60000
```

## Running the Operator

Start the operator with:

```bash
npm run start:operator
```

## Architecture

The operator consists of several key components:

1. **Configuration**: Settings loaded from environment variables and config file
2. **Price Fetcher**: Retrieves price data from external APIs
3. **Task Processor**: Handles incoming tasks and processes them
4. **Signature Generator**: Signs price data with the operator's private key
5. **Service Manager Interface**: Communicates with the ServiceManager contract

## Security Considerations

- The operator's private key should be kept secure
- In production, use environment variables instead of hardcoded values
- Consider adding additional validation for price data
- Implement monitoring and alerts for operator health

## Integration with EigenLayer

This operator is designed to be part of the EigenLayer AVS (Actively Validated Service) ecosystem. It handles specific tasks (price data fetching and submission) within the larger LiquidityShield service.

## License

MIT 