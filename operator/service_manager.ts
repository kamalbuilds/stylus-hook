import { ethers } from 'ethers';
import { PriceData, Task, TaskStatus } from './types';
import { config } from './config';

// Service Manager ABI
const serviceManagerAbi = [
  "function submitPriceData(address tokenA, address tokenB, uint256 price, uint256 timestamp, bytes signature) external returns (string)",
  "function getPendingTasks() external view returns (tuple(string id, address tokenA, address tokenB, uint256 requestTimestamp, string status, tuple(address tokenA, address tokenB, uint256 price, uint256 timestamp, bytes signature) result, string error)[])",
  "function getTask(string taskId) external view returns (tuple(string id, address tokenA, address tokenB, uint256 requestTimestamp, string status, tuple(address tokenA, address tokenB, uint256 price, uint256 timestamp, bytes signature) result, string error))",
  "function updateTaskStatus(string taskId, string status, tuple(address tokenA, address tokenB, uint256 price, uint256 timestamp, bytes signature) result, string error) external",
  "function addOperator(address operator) external",
  "function removeOperator(address operator) external",
  "function operators(address) external view returns (bool)",
  "function createPriceTask(string taskId, address tokenA, address tokenB) external",
  "function getTaskIds() external view returns (string[])"
];

export class ServiceManager {
  private contract: ethers.Contract;
  private signer: ethers.Wallet;

  constructor(
    private provider: ethers.JsonRpcProvider,
    private address: string,
    privateKey: string
  ) {
    this.signer = new ethers.Wallet(privateKey, provider);
    this.contract = new ethers.Contract(address, serviceManagerAbi, this.signer);
  }

  /**
   * Check if an address is registered as an operator
   */
  async isOperator(address: string): Promise<boolean> {
    return await this.contract.operators(address);
  }

  /**
   * Submit price data to the service manager
   */
  async submitPriceData(priceData: PriceData): Promise<string> {
    const tx = await this.contract.submitPriceData(
      priceData.tokenA,
      priceData.tokenB,
      priceData.price,
      priceData.timestamp,
      priceData.signature,
      {
        maxFeePerGas: config.gas.maxFeePerGas,
        maxPriorityFeePerGas: config.gas.maxPriorityFeePerGas,
        gasLimit: config.gas.limit
      }
    );

    const receipt = await tx.wait();
    console.log(`Submitted price data, transaction hash: ${tx.hash}`);
    
    // In a real implementation, we would parse the receipt logs to get the task ID
    // For now, we'll just return a placeholder
    return "TASK_SUBMITTED";
  }

  /**
   * Get all pending tasks
   */
  async getPendingTasks(): Promise<Task[]> {
    const rawTasks = await this.contract.getPendingTasks();
    
    return rawTasks.map((task: any) => this.parseTaskFromContract(task));
  }

  /**
   * Get a task by ID
   */
  async getTask(taskId: string): Promise<Task> {
    const rawTask = await this.contract.getTask(taskId);
    
    return this.parseTaskFromContract(rawTask);
  }

  /**
   * Update a task's status
   */
  async updateTaskStatus(
    taskId: string, 
    status: TaskStatus, 
    result?: PriceData, 
    error?: string
  ): Promise<void> {
    const statusString = TaskStatus[status];
    
    // Prepare empty price data if not provided
    const emptyPriceData: PriceData = {
      tokenA: ethers.ZeroAddress,
      tokenB: ethers.ZeroAddress,
      price: "0",
      timestamp: 0,
      signature: "0x"
    };
    
    const tx = await this.contract.updateTaskStatus(
      taskId,
      statusString,
      result || emptyPriceData,
      error || "",
      {
        maxFeePerGas: config.gas.maxFeePerGas,
        maxPriorityFeePerGas: config.gas.maxPriorityFeePerGas,
        gasLimit: config.gas.limit
      }
    );
    
    await tx.wait();
    console.log(`Updated task ${taskId} status to ${statusString}`);
  }

  /**
   * Create a new price task
   */
  async createPriceTask(taskId: string, tokenA: string, tokenB: string): Promise<void> {
    const tx = await this.contract.createPriceTask(
      taskId,
      tokenA,
      tokenB,
      {
        maxFeePerGas: config.gas.maxFeePerGas,
        maxPriorityFeePerGas: config.gas.maxPriorityFeePerGas,
        gasLimit: config.gas.limit
      }
    );
    
    await tx.wait();
    console.log(`Created new price task ${taskId} for ${tokenA}/${tokenB}`);
  }

  /**
   * Parse a task object from the contract format to our internal format
   */
  private parseTaskFromContract(rawTask: any): Task {
    return {
      id: rawTask.id,
      tokenA: rawTask.tokenA,
      tokenB: rawTask.tokenB,
      requestTimestamp: Number(rawTask.requestTimestamp),
      status: TaskStatus[rawTask.status as keyof typeof TaskStatus] || TaskStatus.PENDING,
      result: rawTask.result && {
        tokenA: rawTask.result.tokenA,
        tokenB: rawTask.result.tokenB,
        price: rawTask.result.price.toString(),
        timestamp: Number(rawTask.result.timestamp),
        signature: rawTask.result.signature
      },
      error: rawTask.error
    };
  }
} 