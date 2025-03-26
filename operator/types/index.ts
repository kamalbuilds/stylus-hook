// Type definitions for the price operator

// Task status
export enum TaskStatus {
  PENDING = 'PENDING',
  PROCESSING = 'PROCESSING',
  COMPLETED = 'COMPLETED',
  FAILED = 'FAILED'
}

// Price data interface
export interface PriceData {
  tokenA: string;
  tokenB: string;
  price: string;
  timestamp: number;
  signature: string;
}

// Task interface
export interface Task {
  id: string;
  tokenA: string;
  tokenB: string;
  requestTimestamp: number;
  status: TaskStatus;
  result?: PriceData;
  error?: string;
}

// Service manager interface for price data submission
export interface IServiceManager {
  submitPriceData(priceData: PriceData): Promise<string>;
  getPendingTasks(): Promise<Task[]>;
  getTask(taskId: string): Promise<Task>;
  updateTaskStatus(taskId: string, status: TaskStatus, result?: PriceData, error?: string): Promise<void>;
} 