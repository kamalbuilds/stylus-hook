import { ethers } from 'ethers';
import axios from 'axios';
import * as dotenv from 'dotenv';
import { PriceData, Task, TaskStatus } from './types';
import { config } from './config';
import { ServiceManager } from './service_manager';

// Load environment variables
dotenv.config();

// Initialize provider
const provider = new ethers.JsonRpcProvider(config.network.rpcUrl);

// Initialize service manager
const serviceManager = new ServiceManager(
  provider,
  config.serviceManager.address,
  config.operator.privateKey
);

// Fetch price data from API
async function fetchPriceData(tokenA: string, tokenB: string): Promise<{ price: string, timestamp: number }> {
  try {
    // Convert token addresses to symbols using config mappings
    const symbolA = config.tokenMappings[tokenA.toLowerCase()] || tokenA;
    const symbolB = config.tokenMappings[tokenB.toLowerCase()] || tokenB;
    
    // Use CoinGecko or similar API
    const apiUrl = `${config.priceApi.url}/simple/price?ids=${symbolA.toLowerCase()}&vs_currencies=${symbolB.toLowerCase()}&include_last_updated_at=true`;
    const headers = config.priceApi.apiKey 
      ? { 'x-cg-api-key': config.priceApi.apiKey } 
      : {};
    
    const response = await axios.get(apiUrl, { headers });
    
    if (!response.data || !response.data[symbolA.toLowerCase()]) {
      throw new Error(`Failed to fetch price data for ${symbolA}/${symbolB}`);
    }
    
    const price = response.data[symbolA.toLowerCase()][symbolB.toLowerCase()];
    const timestamp = Math.floor(Date.now() / 1000);
    
    return {
      price: ethers.parseUnits(price.toString(), 18).toString(),
      timestamp
    };
  } catch (error) {
    console.error('Error fetching price data:', error);
    throw error;
  }
}

// Sign price data
async function signPriceData(
  tokenA: string, 
  tokenB: string, 
  price: string, 
  timestamp: number
): Promise<string> {
  const wallet = new ethers.Wallet(config.operator.privateKey);
  
  // Create message hash
  const messageHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'address', 'uint256', 'uint256'],
      [tokenA, tokenB, price, timestamp]
    )
  );
  
  // Sign the hash
  const signature = await wallet.signMessage(ethers.getBytes(messageHash));
  return signature;
}

// Process a price task
async function processTask(task: Task): Promise<void> {
  try {
    console.log(`Processing task ${task.id} for ${task.tokenA}/${task.tokenB}`);
    
    // Update task status to PROCESSING
    await serviceManager.updateTaskStatus(task.id, TaskStatus.PROCESSING);
    
    // Fetch price data
    const { price, timestamp } = await fetchPriceData(task.tokenA, task.tokenB);
    
    // Sign the price data
    const signature = await signPriceData(task.tokenA, task.tokenB, price, timestamp);
    
    // Create price data object
    const priceData: PriceData = {
      tokenA: task.tokenA,
      tokenB: task.tokenB,
      price,
      timestamp,
      signature
    };
    
    // Submit price data to service manager
    await serviceManager.submitPriceData(priceData);
    
    // Update task status to COMPLETED
    await serviceManager.updateTaskStatus(task.id, TaskStatus.COMPLETED, priceData);
    
    console.log(`Task ${task.id} completed successfully`);
  } catch (error) {
    console.error(`Error processing task ${task.id}:`, error);
    
    // Update task status to FAILED
    await serviceManager.updateTaskStatus(
      task.id, 
      TaskStatus.FAILED, 
      undefined, 
      error instanceof Error ? error.message : String(error)
    );
  }
}

// Poll for pending tasks
async function pollPendingTasks(): Promise<void> {
  try {
    console.log('Polling for pending tasks...');
    const pendingTasks = await serviceManager.getPendingTasks();
    
    console.log(`Found ${pendingTasks.length} pending tasks`);
    
    for (const task of pendingTasks) {
      if (task.status === TaskStatus.PENDING) {
        await processTask(task);
      }
    }
  } catch (error) {
    console.error('Error polling for pending tasks:', error);
  }
}

// Main function
async function main() {
  console.log('Starting price operator...');
  console.log(`Connected to network: ${config.network.chainId}`);
  console.log(`Service manager address: ${config.serviceManager.address}`);
  
  // Check if we're registered as an operator
  const wallet = new ethers.Wallet(config.operator.privateKey);
  const isOperator = await serviceManager.isOperator(wallet.address);
  
  if (!isOperator) {
    console.warn(`WARNING: This wallet (${wallet.address}) is not registered as an operator. Some functions may fail.`);
  } else {
    console.log(`Operator address: ${wallet.address}`);
  }
  
  // Initial poll
  await pollPendingTasks();
  
  // Set up polling interval
  setInterval(pollPendingTasks, config.operator.pollingInterval);
  
  console.log(`Polling for tasks every ${config.operator.pollingInterval / 1000} seconds`);
}

// Execute main function
if (require.main === module) {
  main().catch((error) => {
    console.error('Fatal error:', error);
    process.exit(1);
  });
} 