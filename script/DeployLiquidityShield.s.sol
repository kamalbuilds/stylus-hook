// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {LiquidityShield} from "../src/Counter.sol";  // Renamed from Counter.sol
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract DeployLiquidityShield is Script {
    // Arbitrum Sepolia Uniswap v4 PoolManager address
    // Update this address based on the network you're deploying to
    address constant POOL_MANAGER = 0x7B2B3777Dell55E5c57f1D0D43764B0E1a5606a9;
    
    function run() public {
        // Read private key from environment
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        
        console.log("Deployer address: ", deployer);
        
        // Start the broadcast
        vm.startBroadcast(privateKey);
        
        // Calculate hook address with correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.AFTER_INITIALIZE_FLAG | 
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG
        );
        
        // Mine a salt for the hook deployment
        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer,
            flags,
            0,
            type(LiquidityShield).creationCode, 
            abi.encode(POOL_MANAGER, deployer)  // Initialize with placeholder volatility calculator
        );
        
        console.log("Computed hook address: ", hookAddress);
        
        // Deploy the hook with the mined salt
        LiquidityShield hook = new LiquidityShield{salt: salt}(
            IPoolManager(POOL_MANAGER),
            deployer  // Temporarily use the deployer address for the volatility calculator
        );
        
        require(address(hook) == hookAddress, "Hook address mismatch");
        
        console.log("Hook deployed at: ", address(hook));
        console.log("Hook salt: ", vm.toString(salt));
        
        // Deploy the Stylus Volatility Calculator contract
        // Note: This deployment process will be different for Stylus contracts
        // You'll need to build and deploy the Rust contract separately
        // Using Arbitrum Stylus tools and then update the hook with the address
        
        console.log("Next steps:");
        console.log("1. Deploy the Stylus VolatilityCalculator contract");
        console.log("2. Call hook.setVolatilityCalculator(address) with the Stylus contract address");
        
        vm.stopBroadcast();
    }
} 