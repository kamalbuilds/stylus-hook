// Configuration for the price operator
export const config = {
  // Network settings
  network: {
    chainId: 421614, // Arbitrum Sepolia
    rpcUrl: process.env.RPC_URL || 'https://sepolia-rollup.arbitrum.io/rpc',
  },
  
  // Service manager settings
  serviceManager: {
    address: process.env.SERVICE_MANAGER_ADDRESS || '0x0000000000000000000000000000000000000000', // Replace with actual address
  },
  
  // Operator settings
  operator: {
    privateKey: process.env.OPERATOR_PRIVATE_KEY || '',
    pollingInterval: parseInt(process.env.POLLING_INTERVAL || '60000'), // 1 minute default
  },
  
  // Price API settings
  priceApi: {
    url: process.env.PRICE_API_URL || 'https://api.coingecko.com/api/v3',
    apiKey: process.env.PRICE_API_KEY || '',
  },
  
  // Token mappings (address to symbol)
  tokenMappings: {
    '0x0000000000000000000000000000000000000000': 'ETH',
    '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48': 'USDC',
    '0xdAC17F958D2ee523a2206206994597C13D831ec7': 'USDT',
    '0x6B175474E89094C44Da98b954EedeAC495271d0F': 'DAI',
    // Add more mappings as needed
  },
  
  // Gas settings
  gas: {
    limit: 1000000,
    maxFeePerGas: 50000000000, // 50 gwei
    maxPriorityFeePerGas: 2000000000, // 2 gwei
  },
}; 