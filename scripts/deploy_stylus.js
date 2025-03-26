// Script to deploy the Volatility Calculator Stylus contract
const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const { AbiCoder } = require('@ethersproject/abi');

// Configuration - update these values
const PROVIDER_URL = process.env.PROVIDER_URL || 'https://sepolia-rollup.arbitrum.io/rpc';
const PRIVATE_KEY = process.env.PRIVATE_KEY;

// Paths - update as needed
const WASM_PATH = path.join(__dirname, '../target/wasm32-unknown-unknown/release/liquidity_shield.wasm');
const ABI_PATH = path.join(__dirname, '../target/abi.json');

// Main function to deploy the Stylus contract
async function main() {
  if (!PRIVATE_KEY) {
    console.error('PRIVATE_KEY environment variable is required');
    process.exit(1);
  }

  console.log('Building Stylus contract...');
  await buildStylusContract();

  console.log('Deploying Volatility Calculator...');
  
  // Connect to the network
  const provider = new ethers.JsonRpcProvider(PROVIDER_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  
  console.log(`Connected to network with address: ${wallet.address}`);
  
  // Check if the WASM binary exists
  if (!fs.existsSync(WASM_PATH)) {
    console.error(`WASM binary not found at ${WASM_PATH}`);
    process.exit(1);
  }
  
  // Read the WASM binary
  const wasmBinary = fs.readFileSync(WASM_PATH);
  console.log(`WASM binary size: ${wasmBinary.length} bytes`);
  
  // Read the ABI
  const abi = JSON.parse(fs.readFileSync(ABI_PATH, 'utf8'));
  console.log('ABI loaded successfully');
  
  // Get the encoded constructor parameters
  const encodedConstructor = encodeConstructorParams([]);
  
  // Create deployment transaction using Stylus SDK
  // Using the ethers.js directly since we're in an example script
  // In a production environment, you'd use the Stylus SDK
  
  // Deploy the contract using Arbitrum Stylus deployment address
  const STYLUS_DEPLOYER_ADDRESS = '0x8295aB40CDd53dFBF6Daff305E25a6C5d320b716'; // Arbitrum Sepolia
  
  // Create the deployer contract instance
  const deployer = new ethers.Contract(
    STYLUS_DEPLOYER_ADDRESS,
    [
      'function createProgram(bytes wasmBinary, bytes32 salt, bytes constructorArgs) external returns (address)',
    ],
    wallet
  );
  
  // Generate a random salt for deployment
  const salt = ethers.hexlify(ethers.randomBytes(32));
  
  // Deploy the contract
  console.log('Deploying contract...');
  const tx = await deployer.createProgram(
    wasmBinary,
    salt,
    encodedConstructor,
    {
      gasLimit: 10000000, // Adjust as needed
    }
  );
  
  console.log(`Transaction sent: ${tx.hash}`);
  console.log('Waiting for confirmation...');
  
  const receipt = await tx.wait();
  
  // Parse the logs to get the deployed contract address
  // The address should be in the event logs
  // This is a simplified version; you'd need to parse the event properly
  const contractAddress = receipt.logs[0].address;
  
  console.log(`Contract deployed at: ${contractAddress}`);
  console.log('');
  console.log('Next steps:');
  console.log(`1. Call the LiquidityShield.setVolatilityCalculator() function with this address: ${contractAddress}`);
  
  // Write the deployment information to a file
  const deploymentInfo = {
    network: PROVIDER_URL,
    deployerAddress: wallet.address,
    contractAddress,
    transactionHash: tx.hash,
    deployedAt: new Date().toISOString(),
  };
  
  fs.writeFileSync(
    path.join(__dirname, '../deployment-info.json'),
    JSON.stringify(deploymentInfo, null, 2)
  );
  
  console.log('Deployment information saved to deployment-info.json');
}

// Helper function to build the Stylus contract
async function buildStylusContract() {
  return new Promise((resolve, reject) => {
    // Execute cargo build command
    exec(
      'cargo build --release --target wasm32-unknown-unknown',
      { cwd: path.join(__dirname, '..') },
      (error, stdout, stderr) => {
        if (error) {
          console.error(`Build error: ${error.message}`);
          console.error(stderr);
          return reject(error);
        }
        if (stderr) {
          console.warn(stderr);
        }
        console.log(stdout);
        
        // Generate the ABI
        exec(
          'cargo stylus export-abi',
          { cwd: path.join(__dirname, '..') },
          (err, out, err2) => {
            if (err) {
              console.error(`ABI generation error: ${err.message}`);
              console.error(err2);
              return reject(err);
            }
            if (err2) {
              console.warn(err2);
            }
            console.log(out);
            resolve();
          }
        );
      }
    );
  });
}

// Helper function to encode constructor parameters
function encodeConstructorParams(params) {
  const abiCoder = new AbiCoder();
  return abiCoder.encode([], []);  // No constructor params in our case
}

// Execute the main function
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 