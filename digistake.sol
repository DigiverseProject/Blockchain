//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Importing necessary OpenZeppelin contracts for security and utility
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Interface defining the structure for staking and associated data
abstract contract IERC20Staking is ReentrancyGuard, Ownable {
    struct Plan {
        uint256 overallStaked; // Total staked amount in this plan
        uint256 stakesCount; // Number of stakes within this plan
        uint256 apr; // Annual Percentage Rate for the plan
        uint256 stakeDuration; // Duration for which the stake is held
        uint256 earlyPenalty; // Penalty for early withdrawal
        bool conclude; // Flag to mark if the staking in this plan is concluded
    }
    
    // Struct for individual staking information
    struct Staking {
        uint256 amount; // Amount staked
        uint256 stakeAt; // Time when staking started
        uint256 endstakeAt; // Time when the stake ends
        uint256 lastClaim; // Time of the last claimed reward
        uint256 totalClaim; // Total claimed rewards
    }

    // Mapping to track stakes for each user within each plan
    mapping(uint256 => mapping(address => Staking[])) public stakes;
    address public stakingToken; // Address of the staked token
    mapping(uint256 => Plan) public plans; // Mapping for different staking plans

    // Constructor initializing the staking token address
    constructor(address _stakingToken) {
        stakingToken = _stakingToken;
    }

    // Abstract functions that must be implemented by the derived contract
    function stake(uint256 _stakingId, uint256 _amount) public virtual;
    function canWithdrawAmount(uint256 _stakingId, address account) public virtual view returns (uint256, uint256);
    function unstake(uint256 _stakingId, uint256 _amount) public virtual;
    function earnedToken(uint256 _stakingId, address account) public virtual view returns (uint256);
    function stakeData(uint256 _stakingId, address account) public virtual view returns (Staking[] memory);
    function claimEarned(uint256 _stakingId) public virtual;
}

// Contract implementing staking functionalities
contract DigiStake is IERC20Staking {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant periodicTime = 365 days; // Constant representing a year in seconds
    uint256 public planLimit = 3; // Maximum number of staking plans allowed
    uint256 public totalStaked; // Total amount staked across all plans
    uint256[] public refPercent; // percent for referral

    struct Users {
        bool status;
        address invitedBy;
        uint256 totalDownline;
        uint256 totalEarning;
        uint256 claimableEarning;
    }
    mapping(address => Users) public user;

    // Constructor initializing the staking token and minimum stake amount
    constructor(
        address _stakingToken
    ) IERC20Staking(_stakingToken) {
        // Initializing three predefined staking plans with different parameters
        plans[0].apr = 8;
        plans[0].stakeDuration = 15 days;
        plans[0].earlyPenalty = 15;

        plans[1].apr = 18;
        plans[1].stakeDuration = 30 days;
        plans[1].earlyPenalty = 15;

        plans[2].apr = 30;
        plans[2].stakeDuration = 45 days;
        plans[2].earlyPenalty = 15; 
   
        refPercent = [3, 2, 1];    
    }

    // Staking function allowing users to stake their tokens with referrer
    function rStake(uint256 _stakingId, uint256 _amount, address _referrer) external {  
        if(_referrer != msg.sender && _referrer != address(0)) {
            if(!user[msg.sender].status){
                user[msg.sender].invitedBy = _referrer;
                user[msg.sender].status = true;

                address currentUpline0 = _referrer; 
                for (uint i = 0; i < refPercent.length; ++i) {
                    user[currentUpline0].totalDownline += 1;
                    currentUpline0 = user[currentUpline0].invitedBy; // Move to next referrer
                }               
            }                      
        }
        stake(_stakingId, _amount); 
    }

    // Staking function allowing users to stake their tokens
    function stake(uint256 _stakingId, uint256 _amount) public nonReentrant override {
        require(_amount > 0, "Staking Amount cannot be zero");
        require(IERC20(stakingToken).balanceOf(msg.sender) >= _amount,"Balance is not enough");
        require(_stakingId < planLimit, "Staking is unavailable");

        Plan storage plan = plans[_stakingId];
        require(!plan.conclude, "Staking in this pool is concluded");

        uint256 beforeBalance = IERC20(stakingToken).balanceOf(address(this));
        IERC20(stakingToken).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 afterBalance = IERC20(stakingToken).balanceOf(address(this));
        uint256 amount = afterBalance - beforeBalance;
        
        uint256 stakelength = stakes[_stakingId][msg.sender].length;
        if(stakelength == 0) {
            ++plan.stakesCount; 
        }

        stakes[_stakingId][msg.sender].push();
        Staking storage _staking = stakes[_stakingId][msg.sender][stakelength];
        _staking.amount = amount;
        _staking.stakeAt = block.timestamp;
        _staking.endstakeAt = block.timestamp + plan.stakeDuration;
        _staking.lastClaim = block.timestamp;

        plan.overallStaked += amount;
        totalStaked += amount;

        emit Stake(msg.sender, amount, _stakingId);
    }

    // Function allowing users to withdraw their stakes
    function unstake(uint256 _stakingId, uint256 _amount) public nonReentrant override {
        uint256 _stakedAmount;
        uint256 _canWithdraw;
        Plan storage plan = plans[_stakingId];
        (_stakedAmount, _canWithdraw) = canWithdrawAmount(_stakingId, msg.sender);
        require(_stakedAmount >= _amount, "Insufficient staked amount");

        uint256 amount = _amount;
        uint256 _earned = 0;
        uint256 _penalty = 0;
        
        uint256 stakesCount = stakes[_stakingId][msg.sender].length;
        for (uint256 i = 0; i < stakesCount; ++i) {
            Staking storage _staking = stakes[_stakingId][msg.sender][i];
            if (block.timestamp >= _staking.endstakeAt) { 
                uint256 withdrawAmount = amount >= _staking.amount ? _staking.amount : amount;
                _earned = _earned.add(calculateEarned(withdrawAmount, _staking.lastClaim, plan.apr));
                _staking.amount = _staking.amount.sub(withdrawAmount);
                amount = amount.sub(withdrawAmount);
            } else { 
                uint256 penaltyAmount = amount >= _staking.amount ? _staking.amount : amount;
                _penalty = _penalty.add(calculatePenalty(penaltyAmount, plan.earlyPenalty));
                _earned = _earned.add(calculateEarned(penaltyAmount, _staking.lastClaim, plan.apr));
                _staking.amount = _staking.amount.sub(penaltyAmount);
                amount = amount.sub(penaltyAmount);
                break; 
            }
            _staking.lastClaim = block.timestamp;
        }

        if (_amount > 0) {
            IERC20(stakingToken).safeTransfer(msg.sender, _amount.sub(_penalty));
        }
        if (_earned > 0) {
            IERC20(stakingToken).safeTransfer(msg.sender, _earned);
        }

        plans[_stakingId].overallStaked -= _amount;
        totalStaked -= _amount;

        removeEmptyStakes(_stakingId, msg.sender);

        emit unStake(msg.sender, _amount, _stakingId);
    }

    // Function to claim earned rewards from staking
    function claimEarned(uint256 _stakingId) public nonReentrant checkPools override {
        uint256 _earned = 0;
        Plan storage plan = plans[_stakingId];

        for (uint256 i = 0; i < stakes[_stakingId][msg.sender].length; ++i) {
            Staking storage _staking = stakes[_stakingId][msg.sender][i];
            _earned = _earned.add(calculateEarned(_staking.amount, _staking.lastClaim, plan.apr));
            _staking.lastClaim = block.timestamp; //!important, dont remove this line
            _staking.totalClaim += _earned;
        }

        require(_earned > 0, "There is no amount to claim");
        IERC20(stakingToken).safeTransfer(msg.sender, _earned);

        address currentUpline1 = user[msg.sender].invitedBy; 
        for (uint i = 0; i < refPercent.length; i++) {
            uint256 bonusInvite = _earned.mul(refPercent[i]).div(100);
            user[currentUpline1].totalEarning += bonusInvite;
            user[currentUpline1].claimableEarning += bonusInvite;  
            currentUpline1 = user[currentUpline1].invitedBy; // Move to next referrer
        }

        emit Claim(msg.sender, _earned, _stakingId);
    }

    // Function to claim earning rewards from invite
    function claimReward(uint256 _ramount) external nonReentrant checkPools {
        uint256 _claimable = user[msg.sender].claimableEarning;

        require(_ramount > 0, "Cannot claim zero");
        require(_claimable > 0, "no amount to claim");
        require(_claimable >= _ramount, "input amount higher than claimable balance");

        if(_claimable > 0 && _claimable >= _ramount){
            user[msg.sender].claimableEarning -= _ramount;
            IERC20(stakingToken).safeTransfer(msg.sender, _ramount);
        }
    }

    // public view function for get staked and withdraw data
    function canWithdrawAmount(uint256 _stakingId, address _account) public override view returns (uint256, uint256) {
        uint256 _stakedAmount = 0;
        uint256 _canWithdraw = 0;

        for (uint256 i = 0; i < stakes[_stakingId][_account].length; ++i) {
            Staking storage _staking = stakes[_stakingId][_account][i];
            _stakedAmount = _stakedAmount.add(_staking.amount);
            if(block.timestamp >= _staking.endstakeAt){
                _canWithdraw = _canWithdraw.add(_staking.amount);
            } 
        }

        return (_stakedAmount, _canWithdraw);
    }

    // public view function for get stake data
    function stakeData(uint256 _stakingId, address _account) public override view returns (Staking[] memory) {
        Staking[] memory _stakeDatas = new Staking[](stakes[_stakingId][_account].length);

        for (uint256 i = 0; i < stakes[_stakingId][_account].length; ++i) {
            Staking storage _staking = stakes[_stakingId][_account][i];
            _stakeDatas[i] = _staking;
        }

        return (_stakeDatas);
    }

    // public view function for get earned token
    function earnedToken(uint256 _stakingId, address _account) public override view returns (uint256) {
        uint256 _earned = 0;
        Plan storage plan = plans[_stakingId];

        for (uint256 i = 0; i < stakes[_stakingId][_account].length; ++i) {
            Staking storage _staking = stakes[_stakingId][_account][i];
            _earned = _earned.add(calculateEarned(_staking.amount, _staking.lastClaim, plan.apr));
        }

        return (_earned);
    }

    // function for set stake plan limit
    function setPlanLimit(uint256 _newLimit) external onlyOwner {
        planLimit = _newLimit;
    }

    // function for set stake apr
    function setAPR(uint256 _stakingId, uint256 _percent) external onlyOwner {
        plans[_stakingId].apr = _percent;
    }

    // function for set stake duration
    function setStakeDuration(uint256 _stakingId, uint256 _duration) external onlyOwner {
        plans[_stakingId].stakeDuration = _duration;
    }
    
    // function for set enable or disable specific stake plan
    function setStakeConclude(uint256 _stakingId, bool _conclude) external onlyOwner {
        plans[_stakingId].conclude = _conclude;
    }

    // function for set early penalty
    function setEarlyPenalty(uint256 _stakingId, uint256 _penalty) external onlyOwner {
        require(_penalty < 15, "Cannot more than 15%");
        plans[_stakingId].earlyPenalty = _penalty;
    }

    // function for set reward referral
    function setRefPercent(uint256 _refId, uint256 _rpercent) external onlyOwner {
        require(_rpercent < 10, "Cannot more than 10%");
        refPercent[_refId] = _rpercent;
    }

    // function for recover other token than staked token
    function recoverOtherERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(stakingToken != tokenAddress, "Cannot recover stakingToken");
        IERC20(tokenAddress).safeTransfer(msg.sender, tokenAmount);
    }

    // private function for remove empty stakes
    function removeEmptyStakes(uint256 _stakingId, address _user) private {
        Staking[] storage userStakes = stakes[_stakingId][_user];
        uint256 i = 0;

        while (i < userStakes.length) {
            if (userStakes[i].amount == 0) {
                if (i != userStakes.length - 1) {
                    userStakes[i] = userStakes[userStakes.length - 1];
                }
                userStakes.pop();
            } else {
                ++i; // Increment the index only if an element is not removed
            }
        }
    }

    // Internal function to calculate earned rewards based on stake amount, time, and APR
    function calculateEarned(uint256 amount, uint256 lastClaim, uint256 apr) internal view returns (uint256) {
        return amount.mul(block.timestamp - lastClaim).mul(apr).div(100).div(periodicTime);
    }

    // Internal function to calculate penalty for early withdrawal
    function calculatePenalty(uint256 amount, uint256 earlyPenalty) internal pure returns (uint256) {
        return amount.mul(earlyPenalty).div(100);
    }

    //Security for claim earning, Cannot claim staked balance
    modifier checkPools() {
        uint256 totalsPools = IERC20(stakingToken).balanceOf(address(this));
        require(totalsPools > totalStaked, "Insufficient balance pools need to refill token into contract");
        _;
    }

    // Events to log important contract actions
    event Stake(address indexed user, uint256 amount, uint256 stakeId);
    event unStake(address indexed user, uint256 amount, uint256 stakeId);    
    event Claim(address indexed user, uint256 amount, uint256 stakeId);  
}