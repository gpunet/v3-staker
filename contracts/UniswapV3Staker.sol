// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './interfaces/IUniswapV3Staker.sol';
import './libraries/IncentiveId.sol';
import './libraries/RewardMath.sol';
import './libraries/NFTPositionInfo.sol';
import './libraries/TransferHelperExtended.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';

import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/base/Multicall.sol';

import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title Uniswap V3 canonical staking interface
contract UniswapV3Staker is IUniswapV3Staker, Multicall, AccessControl {
    /// @notice Represents a staking incentive
    struct Incentive {
        uint128 totalRewardUnclaimed;
        uint128 totalRefeUnclaimed;
        uint160 totalSecondsClaimedX128;
        uint96 numberOfStakes;
    }

    /// @notice Represents the deposit of a liquidity NFT
    struct Deposit {
        address owner;
        uint48 numberOfStakes;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Represents a staked liquidity NFT
    struct Stake {
        uint160 secondsPerLiquidityInsideInitialX128;
        uint96 liquidityNoOverflow;
        uint128 liquidityIfOverflow;
        uint64 incentiveId;
        uint64 startTime;
    }
    /// @inheritdoc IUniswapV3Staker
    uint256[5] public override refRate = [2500, 2000, 1500, 1000, 500];
    /// @inheritdoc IUniswapV3Staker
    IUniswapV3Factory public immutable override factory;
    /// @inheritdoc IUniswapV3Staker
    INonfungiblePositionManager public immutable override nonfungiblePositionManager;

    /// @inheritdoc IUniswapV3Staker
    uint256 public immutable override maxIncentiveStartLeadTime;
    /// @inheritdoc IUniswapV3Staker
    uint256 public immutable override maxIncentiveDuration;

    uint256 public override numberOfIncentives;

    // user's depositBalance
    mapping(address => uint256) public override depositBalance;
    // Mapping from owner to list of owned deposit IDs
    mapping(address => mapping(uint256 => uint256)) private _ownedDeposits;

    // Mapping from deposit ID to index of the owner deposits list
    mapping(uint256 => uint256) private _ownedDepositsIndex;
    
    /// @dev incentiveKeys[incentiveId] => IncentiveKey
    mapping(uint256 => IncentiveKey) public override incentiveKeys;
    /// @dev incentives[incentiveId] => Incentive
    mapping(uint256 => Incentive) public override incentives;

    /// @dev deposits[tokenId] => Deposit
    mapping(uint256 => Deposit) public override deposits;

    /// @dev stakes[tokenId] => Stake
    mapping(uint256 => Stake) private _stakes;
    
    /// @dev referrer[user] => user
    mapping(address => address) public override referrer;

    /// @inheritdoc IUniswapV3Staker
    function stakes(uint256 tokenId)
        public
        view
        override
        returns (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity, uint64 incentiveId, uint64 startTime)
    {
        Stake storage stake = _stakes[tokenId];
        secondsPerLiquidityInsideInitialX128 = stake.secondsPerLiquidityInsideInitialX128;
        incentiveId = stake.incentiveId;
        startTime = stake.startTime;
        liquidity = stake.liquidityNoOverflow;
        if (liquidity == type(uint96).max) {
            liquidity = stake.liquidityIfOverflow;
        }
    }

    /// @dev rewards[rewardToken][owner] => uint256
    /// @inheritdoc IUniswapV3Staker
    mapping(IERC20Minimal => mapping(address => uint256)) public override rewards;

    /// @param _factory the Uniswap V3 factory
    /// @param _nonfungiblePositionManager the NFT position manager contract address
    /// @param _maxIncentiveStartLeadTime the max duration of an incentive in seconds
    /// @param _maxIncentiveDuration the max amount of seconds into the future the incentive startTime can be set
    constructor(
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        uint256 _maxIncentiveStartLeadTime,
        uint256 _maxIncentiveDuration
    ) {
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        maxIncentiveStartLeadTime = _maxIncentiveStartLeadTime;
        maxIncentiveDuration = _maxIncentiveDuration;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    ///
    function initUser(address to) external override {
        require(referrer[msg.sender] == address(0), 'UniswapV3Staker::addReferrer: alreday add!');
        require(referrer[to] != address(0), 'UniswapV3Staker::addReferrer: invalid referrer!');
        require(depositBalance[to] != 0, 'UniswapV3Staker::addReferrer: invalid referrer!');
        _addReferrer(msg.sender, to);
    }

    ///
    function addReferrer(address from, address to) external override {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not admin");
        _addReferrer(from, to);
    }

    ///
    function _addReferrer(address from, address to) private {
        referrer[from] = to;
        emit ReferrerAdded(to, from);
    }

    ///
    function modifyRefRate(uint256 id, uint256 rate) external override {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not admin");
        refRate[id] = rate;
    }

    ///
    function refundToken(address token, address to, uint256 amount) external override {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not admin");
        TransferHelperExtended.safeTransfer(token, to, amount);
    }

    /// 
    function incentiveInfo(uint256 incentiveId) external view override
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
    ) {
        IncentiveKey memory key = incentiveKeys[incentiveId];
        Incentive memory it = incentives[incentiveId];
        
        rewardToken = key.rewardToken;
        startTime = key.startTime;
        endTime = key.endTime;
        minDuration = key.minDuration;
        token0 = key.pool.token0();
        token1 = key.pool.token1();
        fee = key.pool.fee();
        totalRewardUnclaimed = it.totalRewardUnclaimed;
        totalSecondsClaimedX128 = it.totalSecondsClaimedX128;
        numberOfStakes = it.numberOfStakes;
    }

    ///
    function depositOfOwnerByIndex(address owner, uint256 index) external view virtual override returns (uint256) {
        require(index < depositBalance[owner], "UniswapV3Staker::Enumerable: owner index out of bounds");
        return _ownedDeposits[owner][index];
    }

    /// @inheritdoc IUniswapV3Staker
    function createIncentive(IncentiveKey memory key, uint256 reward) external override returns (uint256 incentiveId) {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not admin");
        require(reward > 0, 'UniswapV3Staker::createIncentive: reward must be positive');
        require(
            block.timestamp <= key.startTime,
            'UniswapV3Staker::createIncentive: start time must be now or in the future'
        );
        require(
            key.startTime - block.timestamp <= maxIncentiveStartLeadTime,
            'UniswapV3Staker::createIncentive: start time too far into future'
        );
        require(key.startTime < key.endTime, 'UniswapV3Staker::createIncentive: start time must be before end time');
        require(
            key.endTime - key.startTime <= maxIncentiveDuration,
            'UniswapV3Staker::createIncentive: incentive duration is too long'
        );
        incentiveId = numberOfIncentives;
        incentiveKeys[incentiveId] = key;
        numberOfIncentives += 1;

        uint256 ref = 0;
        for(uint i=0; i<5; ++i) {
            ref += reward * refRate[i] / 10000;
        }
        incentives[incentiveId].totalRewardUnclaimed += uint128(reward);
        incentives[incentiveId].totalRefeUnclaimed += uint128(ref);

        TransferHelperExtended.safeTransferFrom(address(key.rewardToken), msg.sender, address(this), reward + ref);

        emit IncentiveCreated(incentiveId, key.rewardToken, key.pool, key.startTime, key.endTime, key.refundee, reward);
    }

    /// @inheritdoc IUniswapV3Staker
    function endIncentive(uint256 incentiveId) external override returns (uint256 refund) {
        IncentiveKey memory key = incentiveKeys[incentiveId];
        require(block.timestamp >= key.endTime, 'UniswapV3Staker::endIncentive: cannot end incentive before end time');

        Incentive storage incentive = incentives[incentiveId];

        refund = incentive.totalRewardUnclaimed + incentive.totalRefeUnclaimed;

        require(refund > 0, 'UniswapV3Staker::endIncentive: no refund available');
        require(
            incentive.numberOfStakes == 0,
            'UniswapV3Staker::endIncentive: cannot end incentive while deposits are staked'
        );

        // issue the refund
        incentive.totalRewardUnclaimed = 0;
        incentive.totalRefeUnclaimed = 0;
        TransferHelperExtended.safeTransfer(address(key.rewardToken), key.refundee, refund);

        // note we never clear totalSecondsClaimedX128

        emit IncentiveEnded(incentiveId, refund);
    }

    /// @notice Upon receiving a Uniswap V3 ERC721, creates the token deposit setting owner to `from`. Also stakes token
    /// in one or more incentives if properly formatted `data` has a length > 0.
    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        require(
            msg.sender == address(nonfungiblePositionManager),
            'UniswapV3Staker::onERC721Received: not a univ3 nft'
        );

        (, , , , , int24 tickLower, int24 tickUpper, , , , , ) = nonfungiblePositionManager.positions(tokenId);

        _addDepositToOwnerEnumeration(from, tokenId);
        deposits[tokenId] = Deposit({owner: from, numberOfStakes: 0, tickLower: tickLower, tickUpper: tickUpper});
        emit DepositTransferred(tokenId, address(0), from);

        if (data.length > 0) {
            if (data.length == 32) {
                _stakeToken(abi.decode(data, (uint256)), tokenId);
            } else {
                uint256[] memory ids = abi.decode(data, (uint256[]));
                for (uint256 i = 0; i < ids.length; i++) {
                    _stakeToken(ids[i], tokenId);
                }
            }
        }
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IUniswapV3Staker
    function transferDeposit(uint256 tokenId, address to) external override {
        require(to != address(0), 'UniswapV3Staker::transferDeposit: invalid transfer recipient');
        address owner = deposits[tokenId].owner;
        require(owner == msg.sender, 'UniswapV3Staker::transferDeposit: can only be called by deposit owner');
        deposits[tokenId].owner = to;
        _addDepositToOwnerEnumeration(to, tokenId);
        _removeDepositFromOwnerEnumeration(msg.sender, tokenId);
        emit DepositTransferred(tokenId, owner, to);
    }

    /// @inheritdoc IUniswapV3Staker
    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data
    ) external override {
        require(to != address(this), 'UniswapV3Staker::withdrawToken: cannot withdraw to staker');
        Deposit memory deposit = deposits[tokenId];
        require(deposit.numberOfStakes == 0, 'UniswapV3Staker::withdrawToken: cannot withdraw token while staked');
        require(deposit.owner == msg.sender, 'UniswapV3Staker::withdrawToken: only owner can withdraw token');
        
        _removeDepositFromOwnerEnumeration(deposit.owner, tokenId);
        delete deposits[tokenId];
        emit DepositTransferred(tokenId, deposit.owner, address(0));

        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId, data);
    }

    /// @inheritdoc IUniswapV3Staker
    function stakeToken(uint256 incentiveId, uint256 tokenId) external override {
        require(deposits[tokenId].owner == msg.sender, 'UniswapV3Staker::stakeToken: only owner can stake token');

        _stakeToken(incentiveId, tokenId);
    }

    /// @inheritdoc IUniswapV3Staker
    function unstakeToken(uint256 tokenId, bytes memory data) external override {
        (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity, uint64 incentiveId, uint64 startTime) = stakes(tokenId);
        require(liquidity != 0, 'UniswapV3Staker::unstakeToken: stake does not exist');

        IncentiveKey memory key = incentiveKeys[incentiveId];
        Deposit memory deposit = deposits[tokenId];
        // anyone can call unstakeToken if the block time is after the end time of the incentive
        if (block.timestamp < key.endTime) {
            require(
                startTime + key.minDuration < block.timestamp,
                'UniswapV3Staker::unstakeToken: it is not time yet!'
            );
            require(
                deposit.owner == msg.sender,
                'UniswapV3Staker::unstakeToken: only owner can withdraw token before incentive end time'
            );
        }

        Incentive storage incentive = incentives[incentiveId];

        deposits[tokenId].numberOfStakes--;
        incentive.numberOfStakes--;

        (, uint160 secondsPerLiquidityInsideX128, ) =
            key.pool.snapshotCumulativesInside(deposit.tickLower, deposit.tickUpper);
        (uint256 reward, uint160 secondsInsideX128) =
            RewardMath.computeRewardAmount(
                incentive.totalRewardUnclaimed,
                incentive.totalSecondsClaimedX128,
                key.startTime,
                key.endTime,
                liquidity,
                secondsPerLiquidityInsideInitialX128,
                secondsPerLiquidityInsideX128,
                block.timestamp
            );

        // if this overflows, e.g. after 2^32-1 full liquidity seconds have been claimed,
        // reward rate will fall drastically so it's safe
        incentive.totalSecondsClaimedX128 += secondsInsideX128;
        // reward is never greater than total reward unclaimed
        incentive.totalRewardUnclaimed -= uint128(reward);
        // this only overflows if a token has a total supply greater than type(uint256).max
        rewards[key.rewardToken][deposit.owner] += reward;
        //update ref
        for ((uint i, address from) = (0, deposit.owner); i < 5; ++i) {
            if (referrer[from] != address(0)) {
                uint128 ref = uint128(reward * refRate[i] / 10000);
                rewards[key.rewardToken][referrer[from]] += ref;
                incentive.totalRefeUnclaimed -= ref;
                from = referrer[from];
                emit RefDistributed(from, ref);
            } else {
                break;
            }         
        }
        // withdraw token
        _removeDepositFromOwnerEnumeration(deposit.owner, tokenId);
        delete deposits[tokenId];
        emit DepositTransferred(tokenId, deposit.owner, address(0));

        nonfungiblePositionManager.safeTransferFrom(address(this), deposit.owner, tokenId, data);

        delete _stakes[tokenId];
        emit TokenUnstaked(tokenId, incentiveId);
    }

    /// @inheritdoc IUniswapV3Staker
    function claimReward(
        IERC20Minimal rewardToken,
        address to,
        uint256 amountRequested
    ) external override returns (uint256 reward) {
        reward = rewards[rewardToken][msg.sender];
        if (amountRequested != 0 && amountRequested < reward) {
            reward = amountRequested;
        }

        rewards[rewardToken][msg.sender] -= reward;
        TransferHelperExtended.safeTransfer(address(rewardToken), to, reward);

        emit RewardClaimed(to, reward);
    }

    /// @inheritdoc IUniswapV3Staker
    function getRewardInfo(uint256 tokenId)
        external
        view
        override
        returns (uint256 reward, uint160 secondsInsideX128)
    {
        (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity, uint64 incentiveId, ) = stakes(tokenId);
        require(liquidity > 0, 'UniswapV3Staker::getRewardInfo: stake does not exist');

        IncentiveKey memory key = incentiveKeys[incentiveId];
        Deposit memory deposit = deposits[tokenId];
        Incentive memory incentive = incentives[incentiveId];

        (, uint160 secondsPerLiquidityInsideX128, ) =
            key.pool.snapshotCumulativesInside(deposit.tickLower, deposit.tickUpper);

        (reward, secondsInsideX128) = RewardMath.computeRewardAmount(
            incentive.totalRewardUnclaimed,
            incentive.totalSecondsClaimedX128,
            key.startTime,
            key.endTime,
            liquidity,
            secondsPerLiquidityInsideInitialX128,
            secondsPerLiquidityInsideX128,
            block.timestamp
        );
    }

    /// @dev Stakes a deposited token without doing an ownership check
    function _stakeToken(uint256 incentiveId, uint256 tokenId) private {
        IncentiveKey memory key = incentiveKeys[incentiveId];
        require(block.timestamp >= key.startTime, 'UniswapV3Staker::stakeToken: incentive not started');
        require(block.timestamp < key.endTime, 'UniswapV3Staker::stakeToken: incentive ended');

        require(
            incentives[incentiveId].totalRewardUnclaimed > 0,
            'UniswapV3Staker::stakeToken: non-existent incentive'
        );
        require(
            _stakes[tokenId].liquidityNoOverflow == 0,
            'UniswapV3Staker::stakeToken: token already staked'
        );
        // new feature
        require(
            deposits[tokenId].numberOfStakes == 0,
            'UniswapV3Staker::stakeToken: token can only be staked once'
        );

        (IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            NFTPositionInfo.getPositionInfo(factory, nonfungiblePositionManager, tokenId);

        require(pool == key.pool, 'UniswapV3Staker::stakeToken: token pool is not the incentive pool');
        require(liquidity > 0, 'UniswapV3Staker::stakeToken: cannot stake token with 0 liquidity');

        deposits[tokenId].numberOfStakes++;
        incentives[incentiveId].numberOfStakes++;

        (, uint160 secondsPerLiquidityInsideX128, ) = pool.snapshotCumulativesInside(tickLower, tickUpper);

        if (liquidity >= type(uint96).max) {
            _stakes[tokenId] = Stake({
                secondsPerLiquidityInsideInitialX128: secondsPerLiquidityInsideX128,
                liquidityNoOverflow: type(uint96).max,
                liquidityIfOverflow: liquidity,
                incentiveId: uint64(incentiveId),
                startTime: uint64(block.timestamp)
            });
        } else {
            _stakes[tokenId] = Stake({
                secondsPerLiquidityInsideInitialX128: secondsPerLiquidityInsideX128,
                liquidityNoOverflow: uint96(liquidity),
                liquidityIfOverflow: 0,
                incentiveId: uint64(incentiveId),
                startTime: uint64(block.timestamp)
            });
        }

        emit TokenStaked(tokenId, incentiveId, liquidity);
    }

    ///
    function _addDepositToOwnerEnumeration(address to, uint256 tokenId) private {
        uint256 length = depositBalance[to];
        _ownedDeposits[to][length] = tokenId;
        _ownedDepositsIndex[tokenId] = length;
        depositBalance[to] += 1;
    }

    ///
    function _removeDepositFromOwnerEnumeration(address from, uint256 tokenId) private {
        // To prevent a gap in from's tokens array, we store the last token in the index of the token to delete, and
        // then delete the last slot (swap and pop).

        uint256 lastTokenIndex = depositBalance[from] - 1;
        uint256 tokenIndex = _ownedDepositsIndex[tokenId];

        // When the token to delete is the last token, the swap operation is unnecessary
        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = _ownedDeposits[from][lastTokenIndex];

            _ownedDeposits[from][tokenIndex] = lastTokenId; // Move the last token to the slot of the to-delete token
            _ownedDepositsIndex[lastTokenId] = tokenIndex; // Update the moved token's index
        }

        depositBalance[from] -= 1;
        // This also deletes the contents at the last position of the array
        delete _ownedDepositsIndex[tokenId];
        delete _ownedDeposits[from][lastTokenIndex];
    }

}
