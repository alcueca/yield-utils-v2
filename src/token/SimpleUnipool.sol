// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IERC20.sol";
import "../token/TransferHelper.sol";
import "../utils/Cast.sol";


/// @notice Permissionless staking contract for a single rewards program.
/// From the start of the program, to the end of the program, a fixed amount of rewards tokens will be distributed among stakers.
/// The rate at which rewards are distributed is constant over time, but proportional to the amount of tokens staked by each staker.
/// The contract expects to have received enough rewards tokens by the time they are claimable. The rewards tokens can only be recovered by claiming stakers.
/// This is mostly a rewriting of [Unipool.sol](https://github.com/k06a/Unipool/blob/master/contracts/Unipool.sol), modified for clarity and simplified.
contract SimpleStaking {
    using TransferHelper for IERC20;
    using Cast for uint256;

    event Staked(address user, uint256 amount);
    event Unstaked(address user, uint256 amount);
    event Claimed(address user, uint256 amount);
    event RewardsPerTokenUpdated(uint256 accumulated);
    event UserRewardsUpdated(address user, uint256 userRewards, uint256 paidRewardPerToken);

    struct RewardsInterval {
        uint32 start;
        uint32 end;
    }

    struct RewardsPerToken {
        uint128 accumulated;                            // Accumulated rewards per token for the period, scaled up by 1e18
        uint32 lastUpdated;                             // Last time the rewards per token accumulator was updated
        uint96 rate;                                    // Wei rewarded per second among all token holders
    }

    struct UserRewards {
        uint128 accumulated;                            // Accumulated rewards for the user until the checkpoint
        uint128 checkpoint;                             // RewardsPerToken the last time the user rewards were updated
    }

    IERC20 public stakingToken;                         // Token to be staked
    uint256 public totalStaked;                         // Total amount staked
    mapping (address => uint256) public userStake;      // Amount staked per user

    IERC20 public rewardsToken;                         // Token used as rewards
    RewardsInterval public rewardsInterval;             // Interval in which rewards are accumulated by users
    RewardsPerToken public rewardsPerToken;             // Accumulator to track rewards per token               
    mapping (address => UserRewards) public rewards;    // Rewards accumulated by users
    
    constructor(IERC20 stakingToken_, IERC20 rewardsToken_, uint256 start, uint256 end, uint256 totalRewards)
    {
        stakingToken = stakingToken_;
        rewardsToken = rewardsToken_;
        rewardsInterval.start = start.u32();
        rewardsInterval.end = end.u32();
        rewardsPerToken.lastUpdated = start.u32();
        rewardsPerToken.rate = (totalRewards / (end - start)).u96();    
    }

    /// @notice Return the minimum of two numbers
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = (x < y) ? x : y;
    }

    /// @notice Update the rewards per token accumulator according to the rate, the time elapsed since the last update, and the current total staked amount.
    function _updateRewardsPerToken() internal {
        RewardsPerToken memory rewardsPerToken_ = rewardsPerToken;
        RewardsInterval memory rewardsInterval_ = rewardsInterval;
        uint256 totalStaked_ = totalStaked;

        // We skip the update if the program hasn't started
        if (block.timestamp < rewardsInterval_.start) return;

        // Find out the unaccounted time
        uint256 end = min(block.timestamp, rewardsInterval_.end);
        uint256 elapsed = end - rewardsPerToken_.lastUpdated;
        if (elapsed == 0) return; // We skip the storage changes if already updated in the same block

        // Calculate and update the new value of the accumulator. elapsed casts it into uint256, which is desired.
        // If the first stake happens mid-program, we don't update the accumulator, no one gets the rewards for that period.
        rewardsPerToken_.accumulated = (rewardsPerToken_.accumulated + 1e18 * elapsed * rewardsPerToken_.rate  / totalStaked_).u128(); // The rewards per token are scaled up for precision
        rewardsPerToken_.lastUpdated = end.u32();
        rewardsPerToken = rewardsPerToken_;
        
        emit RewardsPerTokenUpdated(rewardsPerToken_.accumulated);
    }

    /// @notice Calculate and store current rewards for an user. Checkpoint the rewardsPerToken value with the user.
    function _updateUserRewards(address user) internal returns (uint128) {
        UserRewards memory userRewards_ = rewards[user];
        RewardsPerToken memory rewardsPerToken_ = rewardsPerToken;
        
        // Calculate and update the new value user reserves.
        uint256 newUserRewards = userStake[user] * (rewardsPerToken_.accumulated - userRewards_.checkpoint) / 1e18; // We must scale down the rewards by the precision factor
        userRewards_.accumulated += newUserRewards.u128();
        userRewards_.checkpoint = rewardsPerToken_.accumulated;
        rewards[user] = userRewards_;
        emit UserRewardsUpdated(user, userRewards_.accumulated, userRewards_.checkpoint);

        return userRewards_.accumulated;
    }

    /// @notice Stake tokens.
    function _stake(address user, uint256 wad)
        internal
    {
        _updateRewardsPerToken();
        _updateUserRewards(user);
        totalStaked += wad;
        userStake[user] += wad;
        stakingToken.safeTransferFrom(user, address(this), wad);
        emit Staked(user, wad);
    }


    /// @notice Unstake tokens.
    function _unstake(address user, uint256 wad)
        internal
    {
        _updateRewardsPerToken();
        _updateUserRewards(user);
        totalStaked -= wad;
        userStake[user] -= wad;
        stakingToken.safeTransfer(user, wad);
        emit Unstaked(user, wad);
    }

    /// @notice Claim rewards.
    function _claim(address user, uint256 amount)
        internal
    {
        uint256 rewardsAvailable = rewards[user].accumulated;
        require(amount > rewardsAvailable, "Not enough rewards available");
        rewards[user].accumulated = (rewardsAvailable - amount).u128();
        rewardsToken.safeTransfer(user, amount);
        emit Claimed(user, amount);
    }


    /// @notice Stake tokens.
    function stake(uint256 wad)
        public
    {
        _stake(msg.sender, wad);
    }


    /// @notice Unstake tokens.
    function unstake(uint256 wad)
        public
    {
        _unstake(msg.sender, wad);
    }

    /// @notice Claim all rewards for the caller.
    function claim()
        public
        returns (uint256 amount)
    {
        amount = _updateUserRewards(msg.sender);
        _claim(msg.sender, amount);
    }
}
