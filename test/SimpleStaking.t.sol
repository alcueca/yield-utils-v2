// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import "../src/token/IERC20.sol";
import { ERC20Mock } from "../src/mocks/ERC20Mock.sol";
import { SimpleStaking } from "../src/token/SimpleStaking.sol";
import { TestExtensions } from "./utils/TestExtensions.sol";
import { TestConstants } from "./utils/TestConstants.sol";


using stdStorage for StdStorage;

abstract contract Deployed is Test, TestExtensions, TestConstants {

    event Staked(address user, uint256 amount);
    event Unstaked(address user, uint256 amount);
    event Claimed(address user, uint256 amount);
    event RewardsPerTokenUpdated(uint256 accumulated);
    event UserRewardsUpdated(address user, uint256 userRewards, uint256 paidRewardPerToken);

    SimpleStaking public vault;
    IERC20 public stakingToken;
    uint256 public stakingUnit;
    IERC20 public rewardsToken;
    uint256 public rewardsUnit;
    uint256 totalRewards = 10 * WAD;
    uint256 stakeAmount = totalRewards * 10;
    uint256 start = 1000;
    uint256 interval = 1000000;


    address user;
    address other;
    address admin;
    address me;

    function setUp() public virtual {

        user = address(1);
        other = address(2);
        admin = address(3);
        me = 0xb4c79daB8f259C7Aee6E5b2Aa729821864227e84;

        rewardsToken = IERC20(address(new ERC20Mock("Rewards Token", "REW")));
        rewardsUnit = 10 ** ERC20Mock(address(rewardsToken)).decimals();
        stakingToken = IERC20(address(new ERC20Mock("Staking Token", "STK")));
        stakingUnit = 10 ** ERC20Mock(address(stakingToken)).decimals();

        start += block.timestamp; // Start in the future
        vault = new SimpleStaking(stakingToken, rewardsToken, start, start + interval, totalRewards);
        assertGt(vault.rate(), 0);

        cash(rewardsToken, address(vault), totalRewards); // Rewards to be distributed
        cash(stakingToken, user, stakeAmount); // User stake
        cash(stakingToken, other, stakeAmount); // User stake

        vm.label(user, "user");
        vm.label(other, "other");
        vm.label(admin, "admin");
        vm.label(me, "me");
        vm.label(address(vault), "vault");
        vm.label(address(rewardsToken), "rewardsToken");
        vm.label(address(stakingToken), "stakingToken");
    }
}

contract DeployedTest is Deployed {


    function testDoesntUpdateRewardsPerToken() public {
        vm.startPrank(user);
        stakingToken.approve(address(vault), stakeAmount);
        vault.stake(stakeAmount);
        vm.stopPrank();

        (uint128 accumulated,) = vault.rewardsPerToken();
        assertEq(accumulated, 0);
    }

    function testDoesntUpdateUserRewards() public {
        vm.startPrank(user);
        stakingToken.approve(address(vault), stakeAmount);
        vault.stake(stakeAmount);
        vm.stopPrank();

        uint256 rewards = vault.rewards(user);
        assertEq(rewards, 0);
    }
}

abstract contract DuringInterval is Deployed {
    function setUp() public override virtual {
        super.setUp();

        vm.startPrank(other);
        stakingToken.approve(address(vault), stakeAmount);
        vault.stake(stakeAmount);
        vm.stopPrank();

        (uint256 start,) = vault.rewardsInterval();

        vm.warp(start);
    }
}

contract DuringIntervalTest is DuringInterval {

    function testUpdatesRewardsPerTokenOnStake() public {
        uint256 totalStaked = vault.totalStaked();
        uint256 elapsed = 1;
        (uint32 start,) = vault.rewardsInterval();
        vm.warp(start + 1);

        vm.startPrank(user);
        stakingToken.approve(address(vault), stakeAmount);
        vault.stake(1);
        vm.stopPrank();

        (uint128 accumulated, uint32 lastUpdated) = vault.rewardsPerToken();
        assertEq(lastUpdated, block.timestamp);
        assertEq(accumulated, vault.rate() * elapsed * 1e18 / totalStaked); // accumulated is stored scaled up by 1e18
    }

    function testFuzzUpdatesRewardsPerTokenOnStake(uint32 elapsed) public {
        uint256 totalStaked = vault.totalStaked();
        (uint32 start, uint32 end) = vault.rewardsInterval();
        elapsed = uint32(bound(elapsed, 0, end - start));
        vm.warp(start + elapsed);

        vm.startPrank(user);
        stakingToken.approve(address(vault), stakeAmount);
        vault.stake(1);
        vm.stopPrank();

        (uint128 accumulated, uint32 lastUpdated) = vault.rewardsPerToken();
        assertEq(lastUpdated, block.timestamp);
        assertEq(accumulated, vault.rate() * elapsed * 1e18 / totalStaked); // accumulated is stored scaled up by 1e18
    }

    function testUpdatesUserRewardsOnStake() public {
        vm.startPrank(user);
        cash(stakingToken, user, stakeAmount); // User stake
        stakingToken.approve(address(vault), stakeAmount);
        vault.stake(stakeAmount);
        vm.stopPrank();
        
        vm.warp(block.timestamp + 1); // Warp to next second to accumulate some rewards

        uint256 accumulatedPerTokenNow = vault.accumulatedRewardsPerToken();
        assertGt(accumulatedPerTokenNow, 0);
        uint256 rewards = vault.rewards(user);
        assertGt(rewards, 0);
        assertEq(rewards, vault.userStake(user) * accumulatedPerTokenNow / 1e18);
    }

    function testFuzzUpdatesUserRewardsOnStake(uint32 elapsed) public {
        (uint32 start, uint32 end) = vault.rewardsInterval();
        elapsed = uint32(bound(elapsed, 0, end - start));

        vm.startPrank(user);
        stakingToken.approve(address(vault), stakeAmount);
        vault.stake(1);
        vm.stopPrank();

        (uint128 accumulatedPerTokenNow,) = vault.rewardsPerToken();
        uint256 rewards = vault.rewards(user);
        assertEq(rewards, vault.userStake(user) * accumulatedPerTokenNow / 1e18);
    }


    function testRewards() public {
        (uint32 start,) = vault.rewardsInterval();
        uint256 elapsed = interval / 10;
        vm.warp(start + elapsed);

        uint256 rewardsOther = vault.rewards(other);
        uint256 calculatedRewards = totalRewards * elapsed / interval;

        assertEq(rewardsOther, calculatedRewards);
    }

    function testClaim() public {
        (uint32 start,) = vault.rewardsInterval();
        uint256 elapsed = interval / 10;
        vm.warp(start + elapsed);

        uint256 rewardsOther = vault.rewards(other);
        uint256 calculatedRewards = totalRewards * elapsed / interval;

        vm.expectEmit(true, true, false, false);
        emit Claimed(other, calculatedRewards);
        vm.prank(other);
        vault.claim();

        assertEq(rewardsOther, calculatedRewards);
        assertEq(rewardsToken.balanceOf(other), calculatedRewards);
    }
}

abstract contract AfterIntervalEnd is DuringInterval {
    function setUp() public override virtual {
        super.setUp();

        (, uint256 end) = vault.rewardsInterval();

        vm.warp(end + 1);
    }
}

contract AfterIntervalEndTest is AfterIntervalEnd {

    function testAccumulateNoMore() public {

        vm.startPrank(user);
        stakingToken.approve(address(vault), stakeAmount);
        vault.stake(stakeAmount);
        vm.stopPrank();

        uint256 userRewards = vault.rewards(user);
        uint256 otherRewards = vault.rewards(other);

        assertEq(otherRewards, totalRewards);
        assertEq(userRewards, 0);
    }
}