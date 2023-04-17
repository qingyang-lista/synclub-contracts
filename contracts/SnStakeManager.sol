//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import {IStakeManager} from "./interfaces/IStakeManager.sol";
import {ISnBnb} from "./interfaces/ISnBnb.sol";
import {IStaking} from "./interfaces/INativeStaking.sol";

/**
 * @title Stake Manager Contract
 * @dev Handles Staking of BNB on BSC
 */
contract SnStakeManager is
    IStakeManager,
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeMath for uint256;
    
    uint256 public totalSnBnbToBurn;
    uint256 public totalClaimableBnb; // total BNB available to be claimed and resides in contract
    
    uint256 public totalDelegated; // total BNB delegated
    uint256 public amountToDelegate; // total BNB to delegate for next batch

    uint256 public nextUndelegateUUID;
    uint256 public confirmedUndelegatedUUID;
    uint256 public minDelegateThreshold;
    uint256 public minUndelegateThreshold;

    address private snBnb;
    address private bcValidator;

    mapping(uint256 => BotUndelegateRequest)
        private uuidToBotUndelegateRequestMap;
    mapping(address => WithdrawalRequest[]) private userWithdrawalRequests;

    uint256 public constant TEN_DECIMALS = 1e10;
    bytes32 public constant BOT = keccak256("BOT");

    address private manager;
    address private proposedManager;
    uint256 public synFee; // range {0-10_000_000_000}
    mapping(uint256 => bool) public rewardsIdUsed;

    address public revenuePool;
    address public redirectAddress;

    address private constant nativeStaking = 0x0000000000000000000000000000000000002001;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _snBnb - Address of SnBnb Token on Binance Smart Chain
     * @param _admin - Address of the admin
     * @param _manager - Address of the manager
     * @param _bot - Address of the Bot
     * @param _synFee - Rewards fee to revenue pool
     * @param _revenuePool - Revenue pool to receive rewards
     * @param _validator - Validator to delegate BNB
     */
    function initialize(
        address _snBnb,
        address _admin,
        address _manager,
        address _bot,
        uint256 _synFee,
        address _revenuePool,
        address _validator
    ) external override initializer {
        __AccessControl_init();
        __Pausable_init();

        require(
            ((_snBnb != address(0)) &&
                (_admin != address(0)) &&
                (_manager != address(0)) &&
                (_validator != address(0)) &&
                (_revenuePool != address(0)) &&
                (_bot != address(0))),
            "zero address provided"
        );
        require(_synFee <= TEN_DECIMALS, "_synFee must not exceed (100%)");

        _setRoleAdmin(BOT, DEFAULT_ADMIN_ROLE);
        _setupRole(DEFAULT_ADMIN_ROLE, _admin);
        _setupRole(BOT, _bot);

        manager = _manager;
        snBnb = _snBnb;
        bcValidator = _validator;
        minDelegateThreshold = 1e18;
        minUndelegateThreshold = 1e18;
        synFee = _synFee;
        revenuePool = _revenuePool;

        emit SetManager(_manager);
        emit SetBotRole(_bot);
        emit SetBCValidator(bcValidator);
        emit SetRevenuePool(revenuePool);
        emit SetMinDelegateThreshold(minDelegateThreshold);
        emit SetMinUndelegateThreshold(minUndelegateThreshold);
        emit SetSynFee(_synFee);
    }

    /**
     * @dev Allows user to deposit Bnb at BSC and mints SnBnb for the user
     */
    function deposit() external payable override whenNotPaused {
        uint256 amount = msg.value;
        require(amount > 0, "Invalid Amount");

        uint256 snBnbToMint = convertBnbToSnBnb(amount);

        amountToDelegate += amount;

        ISnBnb(snBnb).mint(msg.sender, snBnbToMint);
    }

    /**
     * @dev Allows bot to delegate users' funds to native staking contract
     * @return _amount - Amount of funds transferred for staking
     * @notice The amount should be greater than minimum delegation on native staking contract
     */
    function delegate()
        external
        payable
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _amount)
    {
        uint256 relayFee = IStaking(nativeStaking).getRelayerFee();
        uint256 relayFeeReceived = msg.value;
        _amount = amountToDelegate - (amountToDelegate % TEN_DECIMALS);

        require(relayFeeReceived >= relayFee, "Insufficient RelayFee");
        require(_amount >= minDelegateThreshold, "Insufficient Deposit Amount");

        // delegate through native staking contract
        IStaking(nativeStaking).delegate{value: _amount + msg.value}(bcValidator, _amount);
        amountToDelegate = amountToDelegate - _amount;
        totalDelegated += _amount;

        emit Delegate(_amount);
    }

    function redelegate(address srcValidator, address dstValidator, uint256 amount)
        external
        payable
        override
        whenNotPaused
        onlyManager
        returns (uint256 _amount) 
    {
        uint256 relayFee = IStaking(nativeStaking).getRelayerFee();
        uint256 relayFeeReceived = msg.value;

        require(relayFeeReceived >= relayFee, "Insufficient RelayFee");
        require(amount >= minDelegateThreshold, "Insufficient Deposit Amount");

        // redelegate through native staking contract
        IStaking(nativeStaking).redelegate{value: msg.value}(srcValidator, dstValidator, amount);

        emit ReDelegate(srcValidator, dstValidator, amount);
        
        return amount;
    }
    /**
     * @dev Allows bot to compound rewards
     */
    function compoundRewards()
        external
        override
        whenNotPaused
        onlyRole(BOT)
    {
        require(totalDelegated > 0, "No funds delegated");

        uint256 amount = IStaking(nativeStaking).claimReward();
        
        if (synFee > 0) {
            uint256 fee = amount.mul(synFee).div(TEN_DECIMALS);
            require(revenuePool != address(0x0), "revenue pool not set");
            AddressUpgradeable.sendValue(payable(revenuePool), fee);
            amount -= fee;
        }

        amountToDelegate += amount;

        emit RewardsCompounded(amount);
    }

    /**
     * @dev Allows user to request for unstake/withdraw funds
     * @param _amountInSnBnb - Amount of SnBnb to swap for withdraw
     * @notice User must have approved this contract to spend SnBnb
     */
    function requestWithdraw(uint256 _amountInSnBnb)
        external
        override
        whenNotPaused
    {
        require(_amountInSnBnb > 0, "Invalid Amount");

        totalSnBnbToBurn += _amountInSnBnb;
        uint256 totalBnbToWithdraw = convertSnBnbToBnb(totalSnBnbToBurn);
        require(
            totalBnbToWithdraw <= totalDelegated,
            "Not enough BNB to withdraw"
        );

        userWithdrawalRequests[msg.sender].push(
            WithdrawalRequest({
                uuid: nextUndelegateUUID,
                amountInSnBnb: _amountInSnBnb,
                startTime: block.timestamp
            })
        );

        IERC20Upgradeable(snBnb).safeTransferFrom(
            msg.sender,
            address(this),
            _amountInSnBnb
        );

        emit RequestWithdraw(msg.sender, _amountInSnBnb);
    }

    function claimWithdraw(uint256 _idx) external override whenNotPaused {
        address user = msg.sender;
        WithdrawalRequest[] storage userRequests = userWithdrawalRequests[user];

        require(_idx < userRequests.length, "Invalid index");

        WithdrawalRequest storage withdrawRequest = userRequests[_idx];
        uint256 uuid = withdrawRequest.uuid;
        uint256 amountInSnBnb = withdrawRequest.amountInSnBnb;

        BotUndelegateRequest
            storage botUndelegateRequest = uuidToBotUndelegateRequestMap[uuid];
        require(botUndelegateRequest.endTime != 0, "Not able to claim yet");
        userRequests[_idx] = userRequests[userRequests.length - 1];
        userRequests.pop();

        uint256 totalBnbToWithdraw_ = botUndelegateRequest.amount;
        uint256 totalSnBnbToBurn_ = botUndelegateRequest.amountInSnBnb;
        uint256 amount = (totalBnbToWithdraw_ * amountInSnBnb) /
            totalSnBnbToBurn_;

        AddressUpgradeable.sendValue(payable(user), amount);

        emit ClaimWithdrawal(user, _idx, amount);
    }

    /**
     * @dev Bot uses this function to get amount of BNB to withdraw
     * @return _uuid - unique id against which this Undelegation event was logged
     * @return _amount - Amount of funds required to Unstake
     */
    function undelegate()
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _uuid, uint256 _amount)
    {
        _uuid = nextUndelegateUUID++; 
        uint256 totalSnBnbToBurn_ = totalSnBnbToBurn; // To avoid Reentrancy attack
        _amount = convertSnBnbToBnb(totalSnBnbToBurn_);
        _amount -= _amount % TEN_DECIMALS;

        require(
            _amount >= minUndelegateThreshold,
            "Insufficient Withdraw Amount"
        );

        uuidToBotUndelegateRequestMap[_uuid] = BotUndelegateRequest({
            startTime: 0,
            endTime: 0,
            amount: _amount,
            amountInSnBnb: totalSnBnbToBurn_
        });

        totalDelegated -= _amount;
        totalSnBnbToBurn = 0;

        ISnBnb(snBnb).burn(address(this), totalSnBnbToBurn_);

        IStaking(nativeStaking).undelegate(bcValidator, _amount);
    }

    function claimUndelegated()
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _uuid, uint256 _amount) 
    {
        uint256 undelegatedAmount = IStaking(nativeStaking).claimUndelegated();
        require(undelegatedAmount > 0, "Nothing to undelegate");
        for (uint256 i = confirmedUndelegatedUUID; i <= nextUndelegateUUID - 1; i++) {
            BotUndelegateRequest
                storage botUndelegateRequest = uuidToBotUndelegateRequestMap[i];
            botUndelegateRequest.endTime = block.timestamp;
            confirmedUndelegatedUUID++;
        }
        _uuid = confirmedUndelegatedUUID;
        _amount = undelegatedAmount;
    }

    function claimFailedDelegation()
        external
        override
        whenNotPaused
        onlyRole(BOT)
        returns (uint256 _amount)
    {
        uint256 failedAmount = IStaking(nativeStaking).claimUndelegated();
        amountToDelegate += failedAmount;
        return failedAmount;
    }

    function proposeNewManager(address _address) external override onlyManager {
        require(manager != _address, "Old address == new address");
        require(_address != address(0), "zero address provided");

        proposedManager = _address;

        emit ProposeManager(_address);
    }

    function acceptNewManager() external override {
        require(
            msg.sender == proposedManager,
            "Accessible only by Proposed Manager"
        );

        manager = proposedManager;
        proposedManager = address(0);

        emit SetManager(manager);
    }

    function setBotRole(address _address) external override onlyManager {
        require(_address != address(0), "zero address provided");

        _setupRole(BOT, _address);

        emit SetBotRole(_address);
    }

    function revokeBotRole(address _address) external override onlyManager {
        require(_address != address(0), "zero address provided");

        _revokeRole(BOT, _address);

        emit RevokeBotRole(_address);
    }

    /// @param _address - Beck32 decoding of Address of Validator Wallet on Beacon Chain with `0x` prefix
    function setBCValidator(address _address)
        external
        override
        onlyManager
    {
        require(bcValidator != _address, "Old address == new address");
        require(_address != address(0), "zero address provided");

        bcValidator = _address;

        emit SetBCValidator(_address);
    }

    function setMinDelegateThreshold(uint256 _minDelegateThreshold)
        external
        override
        onlyManager
    {
        require(_minDelegateThreshold > 0, "Invalid Threshold");
        minDelegateThreshold = _minDelegateThreshold;

        emit SetMinDelegateThreshold(_minDelegateThreshold);
    }

    function setMinUndelegateThreshold(uint256 _minUndelegateThreshold)
        external
        override
        onlyManager
    {
        require(_minUndelegateThreshold > 0, "Invalid Threshold");
        minUndelegateThreshold = _minUndelegateThreshold;

        emit SetMinUndelegateThreshold(_minUndelegateThreshold);
    }

    function setSynFee(uint256 _synFee)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_synFee <= TEN_DECIMALS, "_synFee must not exceed 10000 (100%)");

        synFee = _synFee;

        emit SetSynFee(_synFee);
    }

    function setRedirectAddress(address _address)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(redirectAddress != _address, "Old address == new address");
        require(_address != address(0), "zero address provided");

        redirectAddress = _address;

        emit SetRedirectAddress(_address);
    }

    function getTotalPooledBnb() public view override returns (uint256) {
        return (amountToDelegate + totalDelegated);
    }

    function getContracts()
        external
        view
        override
        returns (
            address _manager,
            address _snBnb,
            address _bcValidator
        )
    {
        _manager = manager;
        _snBnb = snBnb;
        _bcValidator = bcValidator;
    }


    function getBotUndelegateRequest(uint256 _uuid)
        external
        view
        override
        returns (BotUndelegateRequest memory)
    {
        return uuidToBotUndelegateRequestMap[_uuid];
    }

    /**
     * @dev Retrieves all withdrawal requests initiated by the given address
     * @param _address - Address of an user
     * @return userWithdrawalRequests array of user withdrawal requests
     */
    function getUserWithdrawalRequests(address _address)
        external
        view
        override
        returns (WithdrawalRequest[] memory)
    {
        return userWithdrawalRequests[_address];
    }

    /**
     * @dev Checks if the withdrawRequest is ready to claim
     * @param _user - Address of the user who raised WithdrawRequest
     * @param _idx - index of request in UserWithdrawls Array
     * @return _isClaimable - if the withdraw is ready to claim yet
     * @return _amount - Amount of BNB user would receive on withdraw claim
     * @notice Use `getUserWithdrawalRequests` to get the userWithdrawlRequests Array
     */
    function getUserRequestStatus(address _user, uint256 _idx)
        external
        view
        override
        returns (bool _isClaimable, uint256 _amount)
    {
        WithdrawalRequest[] storage userRequests = userWithdrawalRequests[
            _user
        ];

        require(_idx < userRequests.length, "Invalid index");

        WithdrawalRequest storage withdrawRequest = userRequests[_idx];
        uint256 uuid = withdrawRequest.uuid;
        uint256 amountInSnBnb = withdrawRequest.amountInSnBnb;

        BotUndelegateRequest
            storage botUndelegateRequest = uuidToBotUndelegateRequestMap[uuid];

        // bot has triggered startUndelegation
        if (botUndelegateRequest.amount > 0) {
            uint256 totalBnbToWithdraw_ = botUndelegateRequest.amount;
            uint256 totalSnBnbToBurn_ = botUndelegateRequest.amountInSnBnb;
            _amount = (totalBnbToWithdraw_ * amountInSnBnb) / totalSnBnbToBurn_;
        }
        // bot has not triggered startUndelegation yet
        else {
            _amount = convertSnBnbToBnb(amountInSnBnb);
        }
        _isClaimable = (botUndelegateRequest.endTime != 0);
    }

    function getSnBnbWithdrawLimit()
        external
        view
        override
        returns (uint256 _snBnbWithdrawLimit)
    {
        _snBnbWithdrawLimit =
            convertBnbToSnBnb(totalDelegated) -
            totalSnBnbToBurn;
    }

    /**
     * @return relayFee required by TokenHub contract to transfer funds from BSC -> BC
     */
    function getTokenHubRelayFee() public view override returns (uint256) {
        return IStaking(nativeStaking).getRelayerFee();
    }

    /**
     * @dev Calculates amount of SnBnb for `_amount` Bnb
     */
    function convertBnbToSnBnb(uint256 _amount)
        public
        view
        override
        returns (uint256)
    {
        uint256 totalShares = ISnBnb(snBnb).totalSupply();
        totalShares = totalShares == 0 ? 1 : totalShares;

        uint256 totalPooledBnb = getTotalPooledBnb();
        totalPooledBnb = totalPooledBnb == 0 ? 1 : totalPooledBnb;

        uint256 amountInSnBnb = (_amount * totalShares) / totalPooledBnb;

        return amountInSnBnb;
    }

    /**
     * @dev Calculates amount of Bnb for `_amountInSnBnb` SnBnb
     */
    function convertSnBnbToBnb(uint256 _amountInSnBnb)
        public
        view
        override
        returns (uint256)
    {
        uint256 totalShares = ISnBnb(snBnb).totalSupply();
        totalShares = totalShares == 0 ? 1 : totalShares;

        uint256 totalPooledBnb = getTotalPooledBnb();
        totalPooledBnb = totalPooledBnb == 0 ? 1 : totalPooledBnb;

        uint256 amountInBnb = (_amountInSnBnb * totalPooledBnb) / totalShares;

        return amountInBnb;
    }

    /**
     * @dev Flips the pause state
     */
    function togglePause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused() ? _unpause() : _pause();
    }

    receive() external payable {
        if (msg.sender != nativeStaking && msg.sender != redirectAddress) {
            AddressUpgradeable.sendValue(payable(redirectAddress), msg.value);
        }
    }

    modifier onlyManager() {
        require(msg.sender == manager, "Accessible only by Manager");
        _;
    }
}