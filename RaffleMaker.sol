// SPDX-License-Identifier: MIT

pragma solidity ^0.8.11;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

error ZeroError();

abstract contract Administration {

    
    address public operator;

	mapping(address => bool) private _moderators;
	
    event OperatorSet(address indexed operator);
	event ModeratorSet(address indexed moderator, bool status);

	error AuthorizationError();

    constructor(address _operator) {
		if(_operator == address(0)) revert ZeroError();
        operator = _operator;
    }

    // =============================================================
    //                    MODIFIERS
    // =============================================================
    modifier onlyOperator {
        if( isOperator( msg.sender ) ){
			_;
		}else{
			revert AuthorizationError();
		} 
    }
    modifier onlyModerator{
        if( isOperator( msg.sender ) || isModerator( msg.sender ) ){
			_;
		}else{
			revert AuthorizationError();
		} 
    }
	
    // =============================================================
    //                    GETTERS
    // =============================================================
	function isOperator(address account) public view returns (bool) {
		return account == operator;
	}	
	function isModerator(address account) public view returns (bool) {
		return ( _moderators[account] == true );
	}
	
    // =============================================================
    //                    SETTERS
    // =============================================================
    function setOperator(address account) external onlyOperator {
        if(account == address(0)) revert ZeroError();
		operator = account;
        emit OperatorSet(account);
    }
    function setModerator(address account, bool _status) external onlyOperator{
        if(account == address(0)) revert ZeroError();
		_moderators[account] = _status;
        emit ModeratorSet(account, _status);        
    }
}

contract RaffleMaker is Administration, VRFConsumerBaseV2 {

    VRFCoordinatorV2Interface COORDINATOR;
    
    address vrfCoordinator = 0xAE975071Be8F8eE67addBC1A82488F1C24858067;
    bytes32 keyHash = 0xd729dc84e21ae57ffb6be0053bf2b0668aa2aaf300a2a7b2ddf7dc0bb6e875a8;
    
    uint16 requestConfirmations = 3;
    uint16 decimals = 6;
    uint32 numWords =  1;
    uint32 callbackGasLimit = 2500000;
    uint64 s_subscriptionId;
    uint256 s_requestId;
    uint256 lastNum;

  
    using SafeERC20 for IERC20;

    error ValueError();
    error TimeError();
    error InputError();

    IERC20 public usdt;
    address public feeAddress;

    struct Mission{
        string[] names;
        string[] links;
        uint256[] tickets;
        uint256 startTime;
        uint256 finishTime;
    }

    struct RefCode{
        bool active;
        uint256 used;
        uint256 maxUse;
        uint256 finishTime;
        uint16 discount;
        uint16 commission;
        address owner;
    }

    uint16 public rewardShare;
    uint256 public lastMissionId;
    uint256 public ticketPrice;

    constructor(address _operator, uint64 subscriptionId) Administration(_operator) VRFConsumerBaseV2(vrfCoordinator) {

        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);

        s_subscriptionId = subscriptionId;

    }

    mapping(uint256 => Mission) private missionById;
    mapping(string => RefCode) private refCode;

    uint16[] numOfTickets = [1,2,3,4];
    uint32[] bonusTimes = [1,2,3,4];


    // =============================================================
    //                    REF CODE
    // =============================================================

    function checkRefCode(string memory code) private view{
        RefCode memory refcode = refCode[code];

        if(refcode.finishTime < block.timestamp) revert TimeError();
        if(refcode.used + 1 > refcode.maxUse) revert ValueError();
    }

    function createRefCode(
        string memory code,
        uint256 maxUse,
        uint256 finishTime,
        uint16 discount,
        uint16 commission,
        address owner
    ) external onlyModerator {

        uint256 time = block.timestamp;

        if(refCode[code].finishTime > time) revert TimeError();
        if(finishTime <= time) revert TimeError();
        if(discount + commission > 10000 - rewardShare) revert ValueError();
        if(owner == address(0) || maxUse == 0) revert ZeroError();

        refCode[code] = RefCode({
            active: true,
            used: 0,
            maxUse: maxUse,
            finishTime: finishTime,
            discount: discount,
            commission: commission,
            owner: owner
        });

    }

    // =============================================================
    //                    TICKETS
    // =============================================================

    function setTicketPrice(uint256 _price) external onlyModerator{
        ticketPrice = _price;
    }

    function setBonusTimeList(uint16[] memory _numOfTickets, uint32[] memory _bonusTimes) external onlyModerator{
        numOfTickets = _numOfTickets;
        bonusTimes = _bonusTimes;
    }

    function calculateTimeAndPrice(uint256[] memory tickets) public view returns(uint256 activeTime, uint256 price){

        uint256 totalTickets = 0;

        for(uint16 i = 0; i < tickets.length; i++){
            totalTickets += tickets[i];
        }

        uint16 index = 0;

        while(totalTickets < numOfTickets[index]){
            index++;
        }

        activeTime = totalTickets * 900 + bonusTimes[index];
        price = totalTickets * ticketPrice;
    }

    // =============================================================
    //                    MISSIONS
    // =============================================================

    function getMission(uint256 id) public view returns(Mission memory){
        return missionById[id];
    }
    
    function addMission(string[] memory names, string[] memory links, uint256[] memory tickets, string memory code) external payable{
        RefCode storage refcode = refCode[code];

        if(names.length != links.length || names.length != tickets.length) revert InputError();

        (uint256 activeTime, uint256 price) = calculateTimeAndPrice(tickets);

        

        uint16 feePercentage = 10000 - rewardShare;
        uint256 fee = price * feePercentage / 10000;

        if(refcode.active){
            checkRefCode(code);

            price = price * (10000 - refcode.discount) / 10000;
            fee = price * (feePercentage - refcode.commission - refcode.discount) * 10000;
            uint256 commission = price * refcode.commission / 10000;
            
            if(commission > 0){
                usdt.safeTransfer(refcode.owner, commission);
            }
            
            refcode.used++;

        }

        usdt.safeTransferFrom(msg.sender, address(this), price);

        if(fee > 0){
            usdt.safeTransfer(feeAddress, fee);
        }

        lastMissionId++;

        missionById[lastMissionId] = Mission({
            names: names,
            links: links,
            tickets: tickets,
            startTime: block.timestamp,
            finishTime: block.timestamp + activeTime
        });

    }

    function setMission(uint256 id, uint256 finishTime) external onlyModerator {
        missionById[id].finishTime = finishTime;
    }

    // =============================================================
    //                    LOTTERY
    // =============================================================

    function getDecimals() public view returns(uint16) {
        return decimals;
    }

    function setDecimals(uint16 _decimals) public onlyModerator {
        decimals = _decimals;
    }

    function setRewardShare(uint16 _rewardShare) external onlyModerator {
        rewardShare = _rewardShare;
    }
    
    function airdropRewards(address[] memory users, uint256[] memory amounts) external onlyModerator {

        if(users.length != amounts.length) revert InputError();

        uint256 totalReward = 0;

        for(uint256 i = 0; i < users.length; i++){
            usdt.safeTransfer(users[i], amounts[i]);
            totalReward += amounts[i];
        }
    }

    function requestRandomWords() external onlyModerator {
        s_requestId = COORDINATOR.requestRandomWords(
        keyHash,
        s_subscriptionId,
        requestConfirmations,
        callbackGasLimit,
        numWords
        );
    }

    function fulfillRandomWords(
        uint256, /* requestId */
        uint256[] memory randomWords
    ) internal override {

        lastNum = randomWords[0] % (10 ** decimals);

    }

}
