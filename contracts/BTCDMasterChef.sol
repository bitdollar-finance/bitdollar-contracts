pragma solidity 0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";

import "./libs/SafeBEP20.sol";
import "./BTCDToken.sol";

// BTCDMasterChef is the master of BTCD. He can make BTCD and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once BTCD is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract BTCDMasterChef is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of BTCDs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accBTCDPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accBTCDPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken; // Address of LP token contract.
        uint256 lpSupply; // Pool lp supply
        uint256 allocPoint; // How many allocation points assigned to this pool. BTCDs to distribute per block.
        uint256 lastRewardBlock; // Last block number that BTCDs distribution occurs.
        uint256 accBTCDPerShare; // Accumulated BTCDs per share, times 1e12. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
    }

    // The BTCD TOKEN!
    BTCDToken public btcdToken;
    // Dev address.
    address public devAddress;
    // Deposit Fee address
    address public feeAddress;
    // BTCD tokens created per block.
    uint256 public btcdPerBlock;
    // The block number when BTCD mining starts.
    uint256 public startBlock;

    // Staked BTCD balance from the pools
    uint256 private stakedBTCDBalance;

    // Bonus muliplier for early BTCD makers.
    uint256 public BONUS_MULTIPLIER = 1;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // Maximum emission rate
    uint256 public constant MAXIMUM_EMISSON_RATE = 10**24;
    // Max deposit fee per pools: 20%
    uint16 public constant MAX_DEPOSIT_FEE = 2000;

    event Deposited(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdrawn(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event FeeAddressUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );
    event DevAddressUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );
    event EmissionRateUpdated(uint256 oldRate, uint256 newRate);
    event StartBlockUpdated(uint256 oldBlock, uint256 newBlock);

    constructor(
        BTCDToken _btcdToken,
        address _devAddress,
        address _feeAddress,
        uint256 _btcdPerBlock,
        uint256 _startBlock
    ) public {
        btcdToken = _btcdToken;
        devAddress = _devAddress;
        feeAddress = _feeAddress;
        btcdPerBlock = _btcdPerBlock;
        startBlock = _startBlock;

        // staking pool
        poolInfo.push(
            PoolInfo({
                lpToken: _btcdToken,
                lpSupply: 0,
                allocPoint: 1000,
                lastRewardBlock: startBlock,
                depositFeeBP: 0,
                accBTCDPerShare: 0
            })
        );

        totalAllocPoint = 1000;
    }

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IBEP20 _lpToken,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) external onlyOwner {
        require(
            _depositFeeBP <= MAX_DEPOSIT_FEE,
            "add: invalid deposit fee basis points"
        );
        _lpToken.balanceOf(address(this)); // Check if lptoken is the actual token contract

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                lpSupply: 0,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accBTCDPerShare: 0,
                depositFeeBP: _depositFeeBP
            })
        );
        updateStakingPool();
    }

    // Update the given pool's BTCD allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) external onlyOwner {
        require(
            _depositFeeBP < MAX_DEPOSIT_FEE,
            "set: invalid deposit fee basis points"
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(
                _allocPoint
            );
            updateStakingPool();
        }
    }

    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points.add(poolInfo[pid].allocPoint);
        }
        if (points != 0) {
            points = points.div(3);
            totalAllocPoint = totalAllocPoint.sub(poolInfo[0].allocPoint).add(
                points
            );
            poolInfo[0].allocPoint = points;
        }
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending BTCDs on frontend.
    function pendingBTCD(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accBTCDPerShare = pool.accBTCDPerShare;
        if (
            block.number > pool.lastRewardBlock &&
            pool.lpSupply != 0 &&
            totalAllocPoint > 0
        ) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 btcdReward = multiplier
                .mul(btcdPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accBTCDPerShare = accBTCDPerShare.add(
                btcdReward.mul(1e12).div(pool.lpSupply)
            );
        }
        return user.amount.mul(accBTCDPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        if (pool.lpSupply == 0 || totalAllocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 btcdReward = multiplier
            .mul(btcdPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);

        // Mint rewards
        btcdToken.mint(devAddress, btcdReward.div(10));
        btcdToken.mint(btcdReward);

        pool.accBTCDPerShare = pool.accBTCDPerShare.add(
            btcdReward.mul(1e12).div(pool.lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for BTCD allocation.
    function deposit(uint256 _pid, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pending = user
                .amount
                .mul(pool.accBTCDPerShare)
                .div(1e12)
                .sub(user.rewardDebt);
            if (pending > 0) {
                safeBTCDTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            uint256 balanceBefore = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            _amount = pool.lpToken.balanceOf(address(this)).sub(balanceBefore);
            uint256 depositFee = 0;
            if (pool.depositFeeBP > 0) {
                depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                if (depositFee > 0) {
                    pool.lpToken.safeTransfer(feeAddress, depositFee);
                }
            }
            user.amount = user.amount.add(_amount).sub(depositFee);
            pool.lpSupply = pool.lpSupply.add(_amount).sub(depositFee);
            // For the BTCD pool, it needs to update `stakedBTCDBalance` variable
            if (address(pool.lpToken) == address(btcdToken)) {
                stakedBTCDBalance = stakedBTCDBalance.add(_amount).sub(
                    depositFee
                );
            }
        }
        user.rewardDebt = user.amount.mul(pool.accBTCDPerShare).div(1e12);
        emit Deposited(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(
            user.amount >= _amount,
            "withdraw: not good(user balance not enough)"
        );
        require(
            pool.lpSupply >= _amount,
            "withdraw: not good(pool balance not enough)"
        );

        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accBTCDPerShare).div(1e12).sub(
            user.rewardDebt
        );
        if (pending > 0) {
            safeBTCDTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpSupply = pool.lpSupply.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);

            // For the BTCD pool, it needs to update `stakedBTCDBalance` variable
            if (address(pool.lpToken) == address(btcdToken)) {
                stakedBTCDBalance = stakedBTCDBalance.sub(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accBTCDPerShare).div(1e12);
        emit Withdrawn(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        // For the BTCD pool, it needs to update `stakedBTCDBalance` variable
        if (address(pool.lpToken) == address(btcdToken)) {
            stakedBTCDBalance = stakedBTCDBalance.sub(user.amount);
        }

        pool.lpSupply = pool.lpSupply.sub(user.amount);
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);

        emit EmergencyWithdrawn(msg.sender, _pid, user.amount);

        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe BTCD transfer function, just in case if rounding error causes pool to not have enough BTCDs.
    function safeBTCDTransfer(address _to, uint256 _amount) internal {
        // It must not access staked BTCD tokens
        uint256 availableBTCDBalance = btcdToken.balanceOf(address(this));
        if (availableBTCDBalance <= stakedBTCDBalance) {
            return;
        }
        availableBTCDBalance = availableBTCDBalance.sub(stakedBTCDBalance);
        if (_amount > availableBTCDBalance) {
            btcdToken.transfer(_to, availableBTCDBalance);
        } else {
            btcdToken.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev
    function updateDevAddress(address _devAddress) external {
        require(msg.sender == devAddress, "Only dev allowed");
        require(_devAddress != address(0), "Non zero address");
        emit DevAddressUpdated(devAddress, _devAddress);
        devAddress = _devAddress;
    }

    // Update fee receiver by the previous fee receiver
    function updateFeeAddress(address _feeAddress) external {
        require(msg.sender == feeAddress, "Only fee receiver allowed");
        require(_feeAddress != address(0), "Non zero address");
        emit FeeAddressUpdated(feeAddress, _feeAddress);
        feeAddress = _feeAddress;
    }

    // Update emission rate
    function updateEmissionRate(uint256 _btcdPerBlock) external onlyOwner {
        require(_btcdPerBlock <= MAXIMUM_EMISSON_RATE, "Too high");
        massUpdatePools();
        emit EmissionRateUpdated(btcdPerBlock, _btcdPerBlock);
        btcdPerBlock = _btcdPerBlock;
    }

    // Update start block
    function updateStartBlock(uint256 _startBlock) external onlyOwner {
        require(startBlock > block.number, "Farming started already");
        require(_startBlock > block.number, "Invalid past block");
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            poolInfo[pid].lastRewardBlock = _startBlock;
        }
        StartBlockUpdated(startBlock, _startBlock);
        startBlock = _startBlock;
    }
}
