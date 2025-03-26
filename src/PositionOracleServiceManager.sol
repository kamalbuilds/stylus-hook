// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {ECDSAServiceManagerBase} from "@eigenlayer-middleware/src/unaudited/ECDSAServiceManagerBase.sol";
import {ECDSAStakeRegistry} from "@eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
import {IServiceManager} from "@eigenlayer-middleware/src/interfaces/IServiceManager.sol";
import {ECDSAUpgradeable} from "@openzeppelin-upgrades/contracts/utils/cryptography/ECDSAUpgradeable.sol";
import {IERC1271Upgradeable} from "@openzeppelin-upgrades/contracts/interfaces/IERC1271Upgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@eigenlayer/contracts/interfaces/IRewardsCoordinator.sol";
import {IAllocationManager} from "@eigenlayer/contracts/interfaces/IAllocationManager.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title PositionOracleServiceManager
 * @notice EigenLayer service manager for decentralized price data provision
 */
contract PositionOracleServiceManager is ECDSAServiceManagerBase {
    using ECDSAUpgradeable for bytes32;

    struct PriceData {
        address token0;
        address token1;
        uint256[] prices;
        uint32 dataTimestamp;
    }

    // Latest task number
    uint32 public latestTaskNum;

    // Mapping of task indices to task data
    mapping(uint32 => bytes32) public allTaskHashes;
    
    // Mapping of token pair to latest price data
    mapping(address => mapping(address => PriceData)) public latestPriceData;
    
    // Mapping of task indices to token pairs
    mapping(uint32 => address) public taskToToken0;
    mapping(uint32 => address) public taskToToken1;
    
    // Mapping of task indices to task status
    mapping(uint32 => bool) public taskCompleted;
    
    // Max interval in blocks for responding to a task
    uint32 public immutable MAX_RESPONSE_INTERVAL_BLOCKS;

    event NewPriceTaskCreated(uint32 indexed taskIndex, address token0, address token1);
    event PriceDataSubmitted(uint32 indexed taskIndex, address token0, address token1, uint256 latestPrice);
    
    constructor(
        address _avsDirectory,
        address _stakeRegistry,
        address _rewardsCoordinator,
        address _delegationManager,
        address _allocationManager,
        uint32 _maxResponseIntervalBlocks
    )
        ECDSAServiceManagerBase(
            _avsDirectory,
            _stakeRegistry,
            _rewardsCoordinator,
            _delegationManager,
            _allocationManager
        )
    {
        MAX_RESPONSE_INTERVAL_BLOCKS = _maxResponseIntervalBlocks;
    }

    function initialize(address initialOwner, address _rewardsInitiator) external initializer {
        __ServiceManagerBase_init(initialOwner, _rewardsInitiator);
    }

    // Required interface implementations
    function addPendingAdmin(address admin) external onlyOwner {}
    function removePendingAdmin(address pendingAdmin) external onlyOwner {}
    function removeAdmin(address admin) external onlyOwner {}
    function setAppointee(address appointee, address target, bytes4 selector) external onlyOwner {}
    function removeAppointee(address appointee, address target, bytes4 selector) external onlyOwner {}
    function deregisterOperatorFromOperatorSets(address operator, uint32[] memory operatorSetIds) external {}

    /**
     * @notice Create a new price data task for a token pair
     * @param token0 Address of the first token
     * @param token1 Address of the second token
     * @return taskIndex The index of the created task
     */
    function createPriceDataTask(
        address token0,
        address token1
    ) external returns (uint32) {
        require(token0 < token1, "Token addresses must be ordered");

        // Create a new task struct (simplified for example)
        bytes32 taskHash = keccak256(abi.encode(
            token0,
            token1,
            block.number
        ));

        // Store task hash and token pair mapping
        uint32 taskIndex = latestTaskNum;
        allTaskHashes[taskIndex] = taskHash;
        taskToToken0[taskIndex] = token0;
        taskToToken1[taskIndex] = token1;
        
        emit NewPriceTaskCreated(taskIndex, token0, token1);
        
        // Increment task number for next task
        latestTaskNum = latestTaskNum + 1;
        
        return taskIndex;
    }

    /**
     * @notice Submit price data for a token pair
     * @param taskIndex The index of the task
     * @param data The price data being submitted
     * @param signature Signatures from EigenLayer operators
     * @return success Whether the submission was successful
     */
    function submitPriceData(
        uint32 taskIndex,
        PriceData calldata data,
        bytes calldata signature
    ) external returns (bool) {
        // Verify task exists
        require(allTaskHashes[taskIndex] != bytes32(0), "Task does not exist");
        
        // Verify token pair matches task
        require(taskToToken0[taskIndex] == data.token0, "Token0 mismatch");
        require(taskToToken1[taskIndex] == data.token1, "Token1 mismatch");
        
        // Verify data is not empty
        require(data.prices.length > 0, "Empty price data");
        
        // Verify data is recent
        require(data.dataTimestamp > 0, "Invalid timestamp");
        
        // The message that operators signed (hash of the price data)
        bytes32 messageHash = keccak256(abi.encode(data));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        bytes4 magicValue = IERC1271Upgradeable.isValidSignature.selector;
        
        // Decode the signature data to get operators and their signatures
        (address[] memory operators, bytes[] memory signatures, uint32 referenceBlock) =
            abi.decode(signature, (address[], bytes[], uint32));
        
        // Verify signatures with the stake registry
        bytes4 isValidSignatureResult =
            ECDSAStakeRegistry(stakeRegistry).isValidSignature(ethSignedMessageHash, signature);
        
        require(magicValue == isValidSignatureResult, "Invalid signature");
        
        // Store the latest price data
        latestPriceData[data.token0][data.token1] = data;
        
        // Mark task as completed
        taskCompleted[taskIndex] = true;
        
        // Emit event with the latest price
        emit PriceDataSubmitted(
            taskIndex, 
            data.token0, 
            data.token1, 
            data.prices[data.prices.length - 1]
        );
        
        return true;
    }
    
    /**
     * @notice Get the latest price data for a token pair
     * @param token0 Address of the first token
     * @param token1 Address of the second token
     * @return data The latest price data
     */
    function getLatestPriceData(
        address token0,
        address token1
    ) external view returns (PriceData memory) {
        // Ensure token addresses are ordered consistently
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }
        
        return latestPriceData[token0][token1];
    }
} 