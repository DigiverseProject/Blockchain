//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Importing necessary OpenZeppelin contracts for security and utility
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
    function claimEarned(uint256 _stakingId, uint256 _amount) public virtual;
}

// Contract implementing staking functionalities
contract DigiStake is IERC20Staking {
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
    function unstake(uint256 _stakingId, uint256 _amount) public nonReentrant checkPools override {
        uint256 _stakedAmount;
        uint256 _canWithdraw;
        Plan storage plan = plans[_stakingId];
        (_stakedAmount, _canWithdraw) = canWithdrawAmount(_stakingId, msg.sender);
        require(_stakedAmount >= _amount, "Insufficient staked amount");

        uint256 amountToWithdraw = _amount;
        uint256 totalPenalty = 0;
        uint256 totalEarned = 0;

        // First pass: Process stakings without penalty
        uint256 stakesCount = stakes[_stakingId][msg.sender].length;
        for (uint256 i = 0; i < stakesCount && amountToWithdraw > 0; ++i) {
            Staking storage _staking = stakes[_stakingId][msg.sender][i];
            if (block.timestamp >= _staking.endstakeAt) {
                uint256 withdrawableAmount = (_staking.amount <= amountToWithdraw) ? _staking.amount : amountToWithdraw;
                amountToWithdraw -= withdrawableAmount;
                totalEarned += calculateEarned(withdrawableAmount, _staking.lastClaim, plan.apr);
                _staking.amount -= withdrawableAmount;
                _staking.lastClaim = block.timestamp;
            }
        }

        // Second pass: Process stakings with penalty
        for (uint256 i = 0; i < stakesCount && amountToWithdraw > 0; ++i) {
            Staking storage _staking = stakes[_stakingId][msg.sender][i];
            if (block.timestamp < _staking.endstakeAt && _staking.amount > 0) {
                uint256 withdrawableAmount = (_staking.amount <= amountToWithdraw) ? _staking.amount : amountToWithdraw;
                uint256 penaltyAmount = calculatePenalty(withdrawableAmount, plan.earlyPenalty);
                totalPenalty += penaltyAmount;
                amountToWithdraw -= withdrawableAmount;
                totalEarned += calculateEarned(withdrawableAmount, _staking.lastClaim, plan.apr);
                _staking.amount -= withdrawableAmount;
                _staking.lastClaim = block.timestamp;
            }
        }

        require(amountToWithdraw == 0, "Requested amount too high");

        uint256 netAmount = _amount - totalPenalty;
        if (netAmount > 0) {
            IERC20(stakingToken).safeTransfer(msg.sender, netAmount);
        }
        if (totalEarned > 0) {
            IERC20(stakingToken).safeTransfer(msg.sender, totalEarned);
            updateReferralEarnings(totalEarned);
        }

        plans[_stakingId].overallStaked -= _amount;
        totalStaked -= _amount;

        removeEmptyStakes(_stakingId, msg.sender);

        emit unStake(msg.sender, _amount, _stakingId);
    }

    // Function to claim earned rewards from staking
    function claimEarned(uint256 _stakingId, uint256 _eAmount) public nonReentrant checkPools override {
        require(_eAmount > 0, "Requested claim amount must be greater than zero");

        uint256 _totalEarned = 0;
        Plan storage plan = plans[_stakingId];

        // Calculate total earned rewards
        for (uint256 i = 0; i < stakes[_stakingId][msg.sender].length; ++i) {
            Staking storage _staking = stakes[_stakingId][msg.sender][i];
            _totalEarned += calculateEarned(_staking.amount, _staking.lastClaim, plan.apr);
        }

        require(_totalEarned >= _eAmount, "Not enough earned rewards to claim the requested amount");

        // Update staking records
        for (uint256 i = 0; i < stakes[_stakingId][msg.sender].length; ++i) {
            Staking storage _staking = stakes[_stakingId][msg.sender][i];
            uint256 _earned = calculateEarned(_staking.amount, _staking.lastClaim, plan.apr);

            // Calculate the proportion of the requested amount to claim from each staking
            uint256 _claimAmount = (_eAmount * _earned) / _totalEarned;
            _eAmount -= _claimAmount;
            _staking.totalClaim += _claimAmount;
            _staking.lastClaim = block.timestamp; // Update last claim time
        }

        IERC20(stakingToken).safeTransfer(msg.sender, _eAmount);
        updateReferralEarnings(_eAmount);

        emit Claim(msg.sender, _eAmount, _stakingId);
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
            _stakedAmount = _stakedAmount + _staking.amount;
            if(block.timestamp >= _staking.endstakeAt){
                _canWithdraw = _canWithdraw + _staking.amount;
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
            _earned = _earned + calculateEarned(_staking.amount, _staking.lastClaim, plan.apr);
        }
        return (_earned);
    }
    
    // function for set enable or disable for specific stake plan
    function setStakeConclude(uint256 _stakingId, bool _conclude) external onlyOwner {
        plans[_stakingId].conclude = _conclude;
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

    // Internal function to update earnings based on referrals
    function updateReferralEarnings(uint256 amount) internal {
        address currentUpline = user[msg.sender].invitedBy;
        for (uint256 i = 0; i < refPercent.length; i++) {
            uint256 bonusInvite = (amount * refPercent[i]) / 100;
            user[currentUpline].totalEarning += bonusInvite;
            user[currentUpline].claimableEarning += bonusInvite;
            currentUpline = user[currentUpline].invitedBy; // Move to next referrer
        }
    }

    // Internal function to calculate earned rewards based on stake amount, time, and APR
    function calculateEarned(uint256 amount, uint256 lastClaim, uint256 apr) internal view returns (uint256) {
        return (amount * (block.timestamp - lastClaim) * apr) / 100 / periodicTime;
    }

    // Internal function to calculate penalty for early withdrawal
    function calculatePenalty(uint256 amount, uint256 earlyPenalty) internal pure returns (uint256) {
        return (amount * earlyPenalty) / 100;
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
