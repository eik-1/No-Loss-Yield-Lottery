// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";


/**
 * @title LotteryPool
 * @author Eik
 * @notice This contract allows users to stake USDC into a lottery pool, where yield is generated via Aave and distributed to a randomly selected winner each round.
 * @dev Integrates Chainlink VRFv2.5 for randomness and Chainlink Automation for round management. Yield is generated using Aave protocol.
 */
contract LotteryPool is VRFConsumerBaseV2Plus, AutomationCompatibleInterface, ReentrancyGuard, Pausable {
    /////////////////
    // ERRORS      //
    /////////////////
    error LotteryPool__SendMoreToEnterLottery();
    error LotteryPool__TransferFailed();
    error LotteryPool__LotteryNotOpen();
    error LotteryPool__UpkeepNotNeeded();
    error LotteryPool__AaveDepositFailed();
    error LotteryPool__RequestNotFound();
    error LotteryPool__NoEligibleUsers();

    enum LotteryState {
        OPEN,
        CALCULATING,
        CLOSED
    }

    /////////////////
    // EVENTS      //
    /////////////////
    event TicketPurchased(address indexed user, uint256 amount);
    event RequestSent(uint256 indexed requestId);
    event RequestFulfilled(uint256 indexed requestId, uint256[] randomWords);

    ///////////////////////
    // STATE VARIABLES   //
    ///////////////////////

    /* VRFv2.5 variables */
    uint256 private immutable i_subscriptionId;
    uint32 private constant NUM_WORDS = 1;
    bytes32 private immutable i_keyHash;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private immutable i_callbackGasLimit;
    struct RequestStatus {
        bool fulfilled;
        bool exists; 
        uint256[] randomWords;
    }
    mapping(uint256 => RequestStatus)
        public s_requests; 
    uint256 public s_lastRequestId;
    uint256[] public s_requestIds;

    /* Chainlink Automation */
    uint256 public s_lastTimeStamp;
    uint256 public s_interval;

    /* Aave variables */
    IERC20 public immutable i_link;
    IERC20 public immutable i_aEthLink;
    address public immutable i_aaveLendingPool;

    /* Lottery variables */
    mapping(address user => mapping(uint256 round => uint256 amount)) public s_ticketsPerRoundPerUser;
    address[] public s_users;
    mapping(address => uint256) public s_userStakes;
    LotteryState private s_lotteryState;
    uint256[] public s_totalYieldGeneratedPerRound;
    uint256 public s_totalYieldGenerated;
    uint256 public s_currentRound;
    address public s_previousWinner;
    uint256 public immutable s_ticketCost; // In LINK
    uint256 public immutable s_platformFee; // In percentage
    uint256 public immutable s_lotteryDuration;
    uint256 public immutable s_purchaseTime;

    address public immutable s_platformFeeRecipient;
    uint256 public constant FEE_BPS = 100; // 1% = 100 basis points (BPS)
    uint256 public constant BPS_DENOMINATOR = 10000;

    /////////////////
    // FUNCTIONS   //
    /////////////////

    constructor(
        // VRF parameters
        address _vrfCoordinator,
        bytes32 _gasLane, //keyHash
        uint256 _subscriptionId,
        uint32 _callbackGasLimit,
        // Contract parameters
        address _linkAddress,
        address _aEthLinkAddress,
        address _aaveLendingPool,
        // Lottery parameters
        uint256 _ticketCost,
        uint256 _platformFee,
        uint256 _lotteryDuration,
        uint256 _purchaseTime,
        address _platformFeeRecipient
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        i_subscriptionId = _subscriptionId;
        i_keyHash = _gasLane;
        i_callbackGasLimit = _callbackGasLimit;

        i_link = IERC20(_linkAddress);
        i_aEthLink = IERC20(_aEthLinkAddress);
        i_aaveLendingPool = _aaveLendingPool;

        s_interval = _lotteryDuration + _purchaseTime;
        s_lastTimeStamp = block.timestamp;

        s_lotteryState = LotteryState.OPEN;
        s_currentRound = 1;
        s_ticketCost = _ticketCost;
        s_platformFee = _platformFee;
        s_lotteryDuration = _lotteryDuration;
        s_purchaseTime = _purchaseTime;
        s_platformFeeRecipient = _platformFeeRecipient;
    }

    /** 
     * @notice Stake LINK tokens into the lottery pool
     * @dev Issue lottery tickets, transfers LINK to the aave lending pool. If purchased after the entry cutoff time, the ticket for that round isn't counted but added to the next round.
     * @param amount The amount of LINK
     */
    function stake(uint256 amount) external payable nonReentrant whenNotPaused {
        if (amount == 0) revert LotteryPool__SendMoreToEnterLottery();
        if (amount < s_ticketCost) revert LotteryPool__SendMoreToEnterLottery();

        uint256 round = s_currentRound;
        if (block.timestamp >= s_lastTimeStamp + s_purchaseTime) {
            // Purchase window closed for current round, add to next round
            round = s_currentRound + 1;
        }

        bool transferSuccess = i_link.transferFrom(msg.sender, address(this), amount);
        if (!transferSuccess) revert LotteryPool__TransferFailed();

        bool isNewUser = s_userStakes[msg.sender] == 0;
        if (isNewUser) {
            s_users.push(msg.sender);
        }
        s_userStakes[msg.sender] += amount;
        s_ticketsPerRoundPerUser[msg.sender][round] = s_userStakes[msg.sender];

        i_link.approve(i_aaveLendingPool, amount);
        (bool success, ) = i_aaveLendingPool.call(
            abi.encodeWithSignature("supply(address,uint256,address,uint16)", 
            address(i_link), amount, address(this), 0)
        );
        if (!success) revert LotteryPool__AaveDepositFailed();

        emit TicketPurchased(msg.sender, amount);
    }

    function checkUpkeep(
        bytes memory /* checkData */
    ) 
        public 
        view 
        override 
        returns (bool upkeepNeeded, bytes memory /* performData */)
    {
        bool isOpen = s_lotteryState == LotteryState.OPEN;
        bool timeHasPassed = ((block.timestamp - s_lastTimeStamp) > s_interval);
        bool isNotPaused = !paused();
        bool hasUsers = s_users.length > 0;
        upkeepNeeded = (isOpen && timeHasPassed && isNotPaused && hasUsers);
        return (upkeepNeeded, "0x0");
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        (bool upkeepNeeded,) = checkUpkeep("");
        if(!upkeepNeeded) revert LotteryPool__UpkeepNotNeeded();

        s_lotteryState = LotteryState.CALCULATING;

        VRFV2PlusClient.RandomWordsRequest memory request = VRFV2PlusClient.RandomWordsRequest({
            keyHash: i_keyHash,
            subId: i_subscriptionId,
            requestConfirmations: REQUEST_CONFIRMATIONS,
            callbackGasLimit: i_callbackGasLimit,
            numWords: NUM_WORDS,
            extraArgs: VRFV2PlusClient._argsToBytes(
                VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
            )
        });

        uint256 requestId = s_vrfCoordinator.requestRandomWords(request);
        s_requests[requestId] = RequestStatus({
            randomWords: new uint256[](0),
            exists: true,
            fulfilled: false
        });
        s_requestIds.push(requestId);
        s_lastRequestId = requestId;
        emit RequestSent(requestId);
    }

    function fulfillRandomWords(uint256 requestId , uint256[] calldata _randomWords) internal override {
        if (!s_requests[requestId].exists) revert LotteryPool__RequestNotFound();
        s_requests[requestId].fulfilled = true;
        s_requests[requestId].randomWords = _randomWords;
        emit RequestFulfilled(requestId, _randomWords);

        address[] memory eligibleUsers = new address[](s_users.length);
        uint256 eligibleUserCount = 0;

        for(uint256 i = 0; i < s_users.length; i++) {
            if(s_ticketsPerRoundPerUser[s_users[i]][s_currentRound] > 0) {
                eligibleUsers[eligibleUserCount] = s_users[i];
                eligibleUserCount++;
            }
        }

        if (eligibleUserCount == 0) revert LotteryPool__NoEligibleUsers();

        uint256 winnerIndex = _randomWords[0] % eligibleUserCount;
        address winner = eligibleUsers[winnerIndex];
        s_previousWinner = winner;

        // Reset the lottery
        s_lotteryState = LotteryState.OPEN;
        s_lastTimeStamp = block.timestamp;
        s_currentRound++;



        
    }

    function sendYieldToWinner(address winner) internal {

    }

    function closeLottery() internal {}

    ///////////////
    // GETTERS   //
    ///////////////

    function getLotteryState() public view returns (LotteryState) {
        return s_lotteryState;
    }

    function getTicketCost() public view returns (uint256) {
        return s_ticketCost;
    }

    function getNumberOfUsers() public view returns (uint256) {
        return s_users.length;
    }

    function getUserStakes(address user) public view returns (uint256) {
        return s_userStakes[user];
    }

}