// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';

import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/interfaces/IMulticall.sol';

/// @title Uniswap V3 Staker Interface
/// @notice Allows staking nonfungible liquidity tokens in exchange for reward tokens
interface IUniswapV3Staker is IERC721Receiver, IMulticall {
    /// @param rewardToken The token being distributed as a reward
    /// @param pool The Uniswap V3 pool
    /// @param startTime The time when the incentive program begins
    /// @param endTime The time when rewards stop accruing
    /// @param minDuration The min duration of stake
    /// @param refundee The address which receives any remaining reward tokens when the incentive is ended
    struct IncentiveKey {
        IERC20Minimal rewardToken;
        IUniswapV3Pool pool;
        uint64 startTime;
        uint64 endTime;
        uint64 minDuration;
        address refundee;
    }
    /// ref rate
    function refRate(uint256 id) external view returns (uint256);
    /// referrer
    function referrer(address from) external view returns (address);
    /// @notice The Uniswap V3 Factory
    function factory() external view returns (IUniswapV3Factory);

    /// @notice The nonfungible position manager with which this staking contract is compatible
    function nonfungiblePositionManager() external view returns (INonfungiblePositionManager);

    /// @notice The max duration of an incentive in seconds
    function maxIncentiveDuration() external view returns (uint256);

    /// @notice The number of incentives
    function numberOfIncentives() external view returns (uint256);

    /// @notice The max amount of seconds into the future the incentive startTime can be set
    function maxIncentiveStartLeadTime() external view returns (uint256);

    /// @notice The number of user's balance
    function depositBalance(address user) external view returns (uint256);
    /// @notice deposit Of Owner By Index
    function depositOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    /// info of incentive
    function incentiveInfo(uint256 incentiveId) external view
        returns (
            IERC20Minimal rewardToken,
            address token0,
            address token1,
            uint24  fee,
            uint64  startTime,
            uint64  endTime,
            uint64  minDuration,
            uint256 totalRewardUnclaimed,
            uint160 totalSecondsClaimedX128,
            uint96  numberOfStakes
        );

    /// @notice Represents a staking incentive key
    function incentiveKeys(uint256 incentiveId)
        external
        view
        returns (
            IERC20Minimal rewardToken,
            IUniswapV3Pool pool,
            uint64 startTime,
            uint64 endTime,
            uint64 minDuration,
            address refundee
        );

    /// @notice Represents a staking incentive
    /// @param incentiveId The ID of the incentive computed from its parameters
    /// @return totalRewardUnclaimed The amount of reward token not yet claimed by users
    /// @return totalSecondsClaimedX128 Total liquidity-seconds claimed, represented as a UQ32.128
    /// @return numberOfStakes The count of deposits that are currently staked for the incentive
    function incentives(uint256 incentiveId)
        external
        view
        returns (
            uint128 totalRewardUnclaimed,
            uint128 totalRefeUnclaimed,
            uint160 totalSecondsClaimedX128,
            uint96  numberOfStakes
        );

    /// @notice Returns information about a deposited NFT
    /// @return owner The owner of the deposited NFT
    /// @return numberOfStakes Counter of how many incentives for which the liquidity is staked
    /// @return tickLower The lower tick of the range
    /// @return tickUpper The upper tick of the range
    function deposits(uint256 tokenId)
        external
        view
        returns (
            address owner,
            uint48 numberOfStakes,
            int24 tickLower,
            int24 tickUpper
        );

    /// @notice Returns information about a staked liquidity NFT
    /// @param tokenId The ID of the staked token
    /// @param incentiveId The ID of the incentive for which the token is staked
    /// @return secondsPerLiquidityInsideInitialX128 secondsPerLiquidity represented as a UQ32.128
    /// @return liquidity The amount of liquidity in the NFT as of the last time the rewards were computed
    function stakes(uint256 tokenId)
        external
        view
        returns (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity, uint64 incentiveId, uint64 startTime);

    /// @notice Returns amounts of reward tokens owed to a given address according to the last time all stakes were updated
    /// @param rewardToken The token for which to check rewards
    /// @param owner The owner for which the rewards owed are checked
    /// @return rewardsOwed The amount of the reward token claimable by the owner
    function rewards(IERC20Minimal rewardToken, address owner) external view returns (uint256 rewardsOwed);
    /// init user
    function initUser(address to) external;
    /// add referrer
    function addReferrer(address from, address to) external;
    /// modify ref rate
    function modifyRefRate(uint256 r0, uint256 r1, uint256 r2, uint256 r3, uint256 r4) external;
    /// refund token
    function refundToken(address token, address to, uint256 amount) external;
    /// @notice Creates a new liquidity mining incentive program
    /// @param key Details of the incentive to create
    /// @param reward The amount of reward tokens to be distributed
    function createIncentive(IncentiveKey memory key, uint256 reward) external returns (uint256 incentiveId);

    /// @notice Ends an incentive after the incentive end time has passed and all stakes have been withdrawn
    /// @param incentiveId id of the incentive to end
    /// @return refund The remaining reward tokens when the incentive is ended
    function endIncentive(uint256 incentiveId) external returns (uint256 refund);

    /// @notice Transfers ownership of a deposit from the sender to the given recipient
    /// @param tokenId The ID of the token (and the deposit) to transfer
    /// @param to The new owner of the deposit
    function transferDeposit(uint256 tokenId, address to) external;

    /// @notice Withdraws a Uniswap V3 LP token `tokenId` from this contract to the recipient `to`
    /// @param tokenId The unique identifier of an Uniswap V3 LP token
    /// @param to The address where the LP token will be sent
    /// @param data An optional data array that will be passed along to the `to` address via the NFT safeTransferFrom
    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data
    ) external;

    /// @notice Stakes a Uniswap V3 LP token
    /// @param incentiveId id the incentive for which to stake the NFT
    /// @param tokenId The ID of the token to stake
    function stakeToken(uint256 incentiveId, uint256 tokenId) external;

    /// @notice Unstakes a Uniswap V3 LP token
    /// @param data callback data
    /// @param tokenId The ID of the token to unstake
    function unstakeToken(uint256 tokenId, bytes memory data) external;

    /// @notice Transfers `amountRequested` of accrued `rewardToken` rewards from the contract to the recipient `to`
    /// @param rewardToken The token being distributed as a reward
    /// @param to The address where claimed rewards will be sent to
    /// @param amountRequested The amount of reward tokens to claim. Claims entire reward amount if set to 0.
    /// @return reward The amount of reward tokens claimed
    function claimReward(
        IERC20Minimal rewardToken,
        address to,
        uint256 amountRequested
    ) external returns (uint256 reward);

    /// @notice Calculates the reward amount that will be received for the given stake
    /// @param tokenId The ID of the token
    /// @return reward The reward accrued to the NFT for the given incentive thus far
    function getRewardInfo(uint256 tokenId)
        external
        returns (uint256 reward, uint160 secondsInsideX128);

    /// @notice Event emitted when a liquidity mining incentive has been created
    /// @param incentiveId The ID of the incentive
    /// @param rewardToken The token being distributed as a reward
    /// @param pool The Uniswap V3 pool
    /// @param startTime The time when the incentive program begins
    /// @param endTime The time when rewards stop accruing
    /// @param refundee The address which receives any remaining reward tokens after the end time
    /// @param reward The amount of reward tokens to be distributed
    event IncentiveCreated(
        uint256 indexed incentiveId,
        IERC20Minimal indexed rewardToken,
        IUniswapV3Pool indexed pool,
        uint256 startTime,
        uint256 endTime,
        address refundee,
        uint256 reward
    );

    /// @notice Event that can be emitted when a liquidity mining incentive has ended
    /// @param incentiveId The incentive which is ending
    /// @param refund The amount of reward tokens refunded
    event IncentiveEnded(uint256 indexed incentiveId, uint256 refund);

    /// @notice Emitted when ownership of a deposit changes
    /// @param tokenId The ID of the deposit (and token) that is being transferred
    /// @param oldOwner The owner before the deposit was transferred
    /// @param newOwner The owner after the deposit was transferred
    event DepositTransferred(uint256 indexed tokenId, address indexed oldOwner, address indexed newOwner);

    /// @notice Event emitted when a Uniswap V3 LP token has been staked
    /// @param tokenId The unique identifier of an Uniswap V3 LP token
    /// @param liquidity The amount of liquidity staked
    /// @param incentiveId The incentive in which the token is staking
    event TokenStaked(uint256 indexed tokenId, uint256 indexed incentiveId, uint128 liquidity);

    /// @notice Event emitted when a Uniswap V3 LP token has been unstaked
    /// @param tokenId The unique identifier of an Uniswap V3 LP token
    /// @param incentiveId The incentive in which the token is staking
    event TokenUnstaked(uint256 indexed tokenId, uint256 indexed incentiveId);

    /// @notice Event emitted when a reward token has been claimed
    /// @param to The address where claimed rewards were sent to
    /// @param reward The amount of reward tokens claimed
    event RewardClaimed(address indexed to, uint256 reward);
    /// referrer added
    event ReferrerAdded(address indexed to, address from);
    /// ref distribute
    event RefDistributed(address indexed to, uint256 ref);
}
