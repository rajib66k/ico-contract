// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TokenICO (Token Sale)
 * @author Rajib Kumar Pradhan
 *
 * The system is designed to be simple, transparent, and fair, allowing participants to
 * purchase tokens during an Initial Coin Offering (ICO) with built-in vesting mechanisms
 * to prevent immediate token dumps and encourage long-term alignment.
 *
 * This ICO system has the following properties:
 * - Initial token unlock support and built-in vesting for remaining tokens
 * - Linear token vesting with a cliff period for participants
 * - Linear vesting begins when saleFinalized but remains locked until cliff expiry
 * - Cap (hard cap & soft cap) on total token distribution during the sale
 * - Token distribution will not proceed if the soft cap is not reached, and users will be eligible for a full refund.
 *
 * Vesting starts when the sale is finalized. Any initial unlock percentage becomes claimable immediately,
 * while the remaining locked tokens stay inaccessible during the cliff period. After the cliff expires, locked
 * tokens are released linearly over the vesting duration.
 *
 * @notice This contract is the core of the Initial Coin Offering system. It handles all
 * logic for contributing funds, allocating tokens, and managing vesting-based claims.
 *
 */
contract TokenICO is Ownable, ReentrancyGuard {
    /////////////////
    // Errors      //
    /////////////////
    error TokenICO__NeedsMoreThanZero();
    error TokenICO__SaleIsOver();
    error TokenICO__InsufficientAmount();
    error TokenICO__AllTokenSold();
    error TokenICO__MaxTokensPerUserExceeded();
    error TokenICO__InvalidVestingDuration();
    error TokenICO__InvalidCliffDuration();
    error TokenICO__InvalidInitialUnlockPercentage();
    error TokenICO__SaleNotEnded();
    error TokenICO__NoIcoToken();
    error TokenICO__NotEnoughIcoToken();
    error TokenICO__SaleAlreadyFinalized();
    error TokenICO__SaleNotFinalized();
    error TokenICO__SaleAborted();
    error TokenICO__SaleNotFinalizedForRefund();
    error TokenICO__SaleNotFinalizedAsSuccessful();
    error TokenICO__NothingToRefund();
    error TokenICO__NotEnoughFunds();

    /////////////////
    // Types       //
    /////////////////
    using OracleLib for AggregatorV3Interface;
    using SafeERC20 for IERC20;

    /////////////////////
    // Data Types      //
    /////////////////////
    /**
     * @dev Stores per-user ICO participation and claim data
     * @param saleTokenAmount Amount of sale tokens allocated to the user
     * @param claimedAmount Amount of tokens already claimed by the user
     * @param paymentTokenAmount Amount of payment tokens contributed by the user
     */
    struct UserData {
        uint256 saleTokenAmount;
        uint256 claimedAmount;
        uint256 paymentTokenAmount;
    }

    /**
     * @dev Represents the final state of the token sale
     * @param PENDING Sale is not finalized
     * @param SUCCESSFUL Sale completed successfully and tokens are claimable
     * @param REFUND Sale failed and users are eligible for refunds
     */
    enum SaleFinalized {
        PENDING,
        SUCCESSFUL,
        REFUND
    }

    ///////////////////////
    // State Variables   //
    ///////////////////////

    /// @dev Address of the token being sold
    address public sSaleToken;

    /// @dev Total amount of sale tokens purchased by users
    uint256 public sTokensSold;

    /// @dev Total amount of vested tokens claimed by users
    uint256 public sTokensClaimed;

    /// @dev Current sale finalization status
    SaleFinalized public sSaleFinalized;

    /// @dev Timestamp when vesting starts
    uint256 public sFinalizeTime;

    /// @dev Stores purchase and vesting data for each user
    mapping(address user => UserData data) public sUserData;

    ////////////////////
    // Constants      //
    ////////////////////
    uint256 private constant PRECISION = 1e18;
    uint256 private constant PERCENTAGE_PRECISION = 100e18;

    ///////////////////////////
    // Immutable Variables   //
    ///////////////////////////

    /// @dev Address of the payment token
    address public immutable I_PAYMENT_TOKEN;

    /// @dev Address of the Chainlink price feed contract
    address public immutable I_PRICE_FEED;

    /// @dev Price per sale token denominated in payment token units
    uint256 public immutable I_SALE_TOKEN_PRICE;

    /// @dev Timestamp when the token sale ends
    uint256 public immutable I_SALE_END_TIME;

    /// @dev Maximum number of tokens allocated for the sale
    uint256 public immutable I_MAX_TOKEN_FOR_SALE;

    /// @dev Minimum funding goal in usd required for a successful sale
    uint256 public immutable I_SOFT_CAP;

    /// @dev Maximum number of tokens a single user can purchase
    uint256 public immutable I_MAX_TOKEN_PER_USER;

    /// @dev Total duration over which purchased tokens vest
    uint256 public immutable I_VESTING_DURATION;

    /// @dev Duration before locked tokens begin vesting release
    uint256 public immutable I_CLIFF_DURATION;

    /// @dev Initial unlock percentage should be in 18-decimal precision
    uint256 public immutable I_INITIAL_UNLOCK_PERCENTAGE;

    /////////////////
    // Events      //
    /////////////////
    event TokensPurchased(address indexed buyer, uint256 paymentTokenAmount, uint256 saleTokenAmount);
    event TokensClaimed(address indexed user, uint256 amount);
    event SaleFinalizedSuccessfully(uint256 timestamp);
    event PaymentRefund(address indexed user, uint256 amount);
    event SaleRefundEnabled(uint256 timestamp);
    event FundsWithdrawn(uint256 amount);
    event UnsoldTokensWithdrawn(uint256 amount);

    /////////////////
    // Functions   //
    /////////////////
    /**
     * @notice Initializes the TokenICO contract with sale, pricing, and vesting parameters
     * @param paymentTokenAddress The ERC20 token used for payments
     * @param priceFeedAddress Chainlink price feed used for token pricing validation
     * @param saleTokenPrice Price per sale token in payment token units
     * @param saleEndTime Timestamp when the token sale ends
     * @param maxTokenForSale Maximum number of tokens available for sale
     * @param softCap Minimum amount of funds in usd required for a successful sale
     * @param maxTokenPerUser Maximum number of tokens a single user can purchase
     * @param vestingDuration Total duration over which tokens vest
     * @param cliffDuration Duration before vested locked tokens become claimable
     * @param initialUnlockPercentage percentage of token unlock at finalize (should be in 18-decimal precision)
     * @dev Reverts if vestingDuration is zero, cliffDuration exceeds vestingDuration, or vestingStart is before sale end
     * @dev Sets initial sale state to PENDING
     */
    constructor(
        address paymentTokenAddress,
        address priceFeedAddress,
        uint256 saleTokenPrice,
        uint256 saleEndTime,
        uint256 maxTokenForSale,
        uint256 softCap,
        uint256 maxTokenPerUser,
        uint256 vestingDuration,
        uint256 cliffDuration,
        uint256 initialUnlockPercentage
    ) Ownable(msg.sender) {
        if (vestingDuration == 0) revert TokenICO__InvalidVestingDuration();
        if (vestingDuration < cliffDuration) revert TokenICO__InvalidCliffDuration();
        if (initialUnlockPercentage > PERCENTAGE_PRECISION) revert TokenICO__InvalidInitialUnlockPercentage();

        I_PAYMENT_TOKEN = paymentTokenAddress;
        I_PRICE_FEED = priceFeedAddress;
        I_SALE_TOKEN_PRICE = saleTokenPrice;
        I_SALE_END_TIME = saleEndTime;
        I_MAX_TOKEN_FOR_SALE = maxTokenForSale;
        I_SOFT_CAP = softCap;
        I_MAX_TOKEN_PER_USER = maxTokenPerUser;
        I_VESTING_DURATION = vestingDuration;
        I_CLIFF_DURATION = cliffDuration;
        I_INITIAL_UNLOCK_PERCENTAGE = initialUnlockPercentage;

        sSaleFinalized = SaleFinalized.PENDING;
    }

    /////////////////////////
    // OWNER FUNCTIONS     //
    /////////////////////////
    /**
     * @notice Sets the ERC20 token that will be distributed to participants
     * @param saleTokenAddress The address of the sale token contract
     * @dev Only callable by the contract owner
     * @dev Sale token MUST use 18 decimals
     */
    function setSaleToken(address saleTokenAddress) external onlyOwner {
        sSaleToken = saleTokenAddress;
    }

    /**
     * @notice Finalizes the ICO after the sale period has ended
     * @dev If the soft cap is not reached, the sale enters REFUND mode
     *      allowing users to reclaim their contributed payment tokens.
     *      Otherwise, the sale becomes SUCCESSFUL and vesting starts.
     *
     * Requirements:
     * - Sale end time must have passed
     * - Sale token must be configured
     * - Contract must hold enough sale tokens for all buyers
     *
     * Emits a {SaleRefundEnabled} event if soft cap is not reached.
     * Emits a {SaleFinalizedSuccessfully} event if finalized successfully.
     */
    function finalizeSale() external onlyOwner {
        if (sSaleFinalized != SaleFinalized.PENDING) revert TokenICO__SaleAlreadyFinalized();

        uint256 timestamp = block.timestamp;
        if (timestamp <= I_SALE_END_TIME) revert TokenICO__SaleNotEnded();

        uint256 raisedUsd = (sTokensSold * I_SALE_TOKEN_PRICE) / PRECISION;
        if (raisedUsd < I_SOFT_CAP) {
            sSaleFinalized = SaleFinalized.REFUND;
            sTokensSold = 0;
            emit SaleRefundEnabled(timestamp);
            return;
        }

        if (sSaleToken == address(0)) revert TokenICO__NoIcoToken();
        if (IERC20(sSaleToken).balanceOf(address(this)) < sTokensSold) revert TokenICO__NotEnoughIcoToken();

        sFinalizeTime = timestamp;
        sSaleFinalized = SaleFinalized.SUCCESSFUL;

        emit SaleFinalizedSuccessfully(timestamp);
    }

    /**
     * @notice Withdraws all collected payment funds after a successful ICO
     * @dev Can only be called by the contract owner after the sale
     *      has been finalized successfully
     * reverts if sale not finalized as successful & if there are no
     * payment tokens to withdraw
     *
     * Emits a {FundsWithdrawn} event if funds withdrawn completed
     */
    function withdrawFunds() external nonReentrant onlyOwner {
        if (sSaleFinalized != SaleFinalized.SUCCESSFUL) revert TokenICO__SaleNotFinalizedAsSuccessful();

        uint256 balance = IERC20(I_PAYMENT_TOKEN).balanceOf(address(this));
        if (balance == 0) revert TokenICO__NotEnoughFunds();

        IERC20(I_PAYMENT_TOKEN).safeTransfer(owner(), balance);
        emit FundsWithdrawn(balance);
    }

    /**
     * @notice Withdraws unsold ICO tokens after the sale is finalized
     * @dev Ensures enough tokens remain in the contract for users
     * who have purchased but not yet claimed their allocations
     * if the sale is still pending& if there are no excess tokens available for withdrawal
     *
     * Emits a {UnsoldTokensWithdrawn} event if unsold tokens withdrawn completed
     */
    function withdrawUnsoldTokens() external nonReentrant onlyOwner {
        if (sSaleFinalized == SaleFinalized.PENDING) revert TokenICO__SaleNotFinalized();

        uint256 minimumRequiredBalance = sTokensSold - sTokensClaimed;
        address saleToken = sSaleToken;
        uint256 saleTokenBalance = IERC20(saleToken).balanceOf(address(this));

        if (saleTokenBalance <= minimumRequiredBalance) revert TokenICO__NotEnoughIcoToken();

        uint256 unsoldAmount = saleTokenBalance - (minimumRequiredBalance);

        IERC20(saleToken).safeTransfer(msg.sender, unsoldAmount);
        emit UnsoldTokensWithdrawn(unsoldAmount);
    }

    //////////////////////////
    // External Functions   //
    //////////////////////////
    /**
     * @param usdAmount The USD-denominated amount (18 decimals / wei precision)
     *         the user wants to spend to buy sale tokens
     * @notice This function transfers accepted payment tokens from the user
     *         and records the purchased sale token allocation in storage
     * @dev Purchased sale tokens are tracked in a mapping and can be claimed
     *         later through a claim function
     *
     * Emits a {TokensPurchased} event if token purchased successfully
     */
    function buyTokens(uint256 usdAmount) external nonReentrant {
        if (block.timestamp > I_SALE_END_TIME) revert TokenICO__SaleIsOver();
        if (sSaleFinalized != SaleFinalized.PENDING) revert TokenICO__SaleIsOver();
        if (usdAmount < I_SALE_TOKEN_PRICE) revert TokenICO__InsufficientAmount();

        UserData storage userData = sUserData[msg.sender];
        uint256 saleTokensToBuy = getSaleTokenAmountFromUsd(usdAmount);
        uint256 tokensSold = sTokensSold;
        uint256 userSaleAmount = userData.saleTokenAmount;

        if (tokensSold + saleTokensToBuy > I_MAX_TOKEN_FOR_SALE) revert TokenICO__AllTokenSold();
        if (userSaleAmount + saleTokensToBuy > I_MAX_TOKEN_PER_USER) {
            revert TokenICO__MaxTokensPerUserExceeded();
        }

        uint256 paymentTokenAmount = getTokenAmountFromUsd(I_PAYMENT_TOKEN, usdAmount);
        IERC20(I_PAYMENT_TOKEN).safeTransferFrom(msg.sender, address(this), paymentTokenAmount);

        unchecked {
            sTokensSold = tokensSold + saleTokensToBuy;
            userData.saleTokenAmount = userSaleAmount + saleTokensToBuy;
            userData.paymentTokenAmount += paymentTokenAmount;
        }
        emit TokensPurchased(msg.sender, paymentTokenAmount, saleTokensToBuy);
    }

    /**
     * @notice Claims intial unlocked & vested sale tokens allocated to the caller
     * @dev Reverts if no tokens are currently claimable.
     *      Claimable amount includes:
     *      - Initial unlock percentage
     *      - Vested locked tokens that become claimable after the cliff duration
     * @dev Caller must have claimable vested tokens else revert
     *
     * Emits a {TokensClaimed} event if token claimed successfully
     */
    function claim() external nonReentrant {
        uint256 claimableAmount = getClaimableTokenAmount();
        if (claimableAmount == 0) revert TokenICO__NeedsMoreThanZero();

        UserData storage userData = sUserData[msg.sender];

        userData.claimedAmount += claimableAmount;
        sTokensClaimed += claimableAmount;
        IERC20(sSaleToken).safeTransfer(msg.sender, claimableAmount);

        emit TokensClaimed(msg.sender, claimableAmount);
    }

    /**
     * @notice Allows users to claim a refund of their deposited payment tokens
     * if the ICO sale has been finalized in refund mode.
     *
     * @dev Reverts if the sale is not in the REFUND state or if the caller
     * has no refundable balance. User balances are cleared before transferring tokens.
     *
     * Emits a {PaymentRefund} event upon successful refund.
     */
    function refund() external nonReentrant {
        if (sSaleFinalized != SaleFinalized.REFUND) revert TokenICO__SaleNotFinalizedForRefund();

        UserData storage userData = sUserData[msg.sender];
        uint256 depositedAmount = userData.paymentTokenAmount;
        if (depositedAmount == 0) revert TokenICO__NothingToRefund();

        userData.paymentTokenAmount = 0;
        userData.saleTokenAmount = 0;
        IERC20(I_PAYMENT_TOKEN).safeTransfer(msg.sender, depositedAmount);

        emit PaymentRefund(msg.sender, depositedAmount);
    }

    //////////////////////////
    // Internal Functions   //
    //////////////////////////
    function _tokenPrecision(address token) internal view returns (uint256) {
        return 10 ** IERC20Metadata(token).decimals();
    }

    /**
     * @notice Calculates the amount of vested tokens available at a given timestamp
     * @param totalAllocation Total Locked token allocation assigned to a user
     * @param timestamp The timestamp used to calculate vested tokens
     * @return The total vested token amount available at the given timestamp
     * @dev Implements linear vesting starting at sale finalization,
     *      with a cliff period during which vested tokens remain unclaimable
     */
    function _vestedTokenAmount(uint256 totalAllocation, uint256 timestamp) internal view returns (uint256) {
        uint256 vestingStart = sFinalizeTime;
        uint256 cliffEnd = vestingStart + I_CLIFF_DURATION;
        uint256 vestingEnd = vestingStart + I_VESTING_DURATION;

        if (timestamp < cliffEnd) {
            return 0;
        } else if (timestamp >= vestingEnd) {
            return totalAllocation;
        } else {
            return (totalAllocation * (timestamp - vestingStart)) / I_VESTING_DURATION;
        }
    }

    ///////////////////////////////
    // Public & View Functions   //
    ///////////////////////////////
    /**
     * @notice Returns the amount of vested sale tokens claimable by the caller
     * @return claimableToken The amount of tokens currently claimable
     * @dev Claimable amount consists of:
     *      - Initial unlock amount available immediately after finalization
     *      - Additional vested tokens unlocked linearly after cliff duration
     *
     * Reverts if:
     * - Sale is not finalized
     * - Sale entered refund mode
     */
    function getClaimableTokenAmount() public view returns (uint256) {
        if (sSaleFinalized == SaleFinalized.PENDING) revert TokenICO__SaleNotFinalized();
        if (sSaleFinalized == SaleFinalized.REFUND) revert TokenICO__SaleAborted();

        UserData memory userData = sUserData[msg.sender];
        uint256 totalTokenAmount = userData.saleTokenAmount;

        uint256 intialUnlockToken = totalTokenAmount * I_INITIAL_UNLOCK_PERCENTAGE / PERCENTAGE_PRECISION;
        uint256 lockedToken = totalTokenAmount - intialUnlockToken;
        uint256 vestedToken = _vestedTokenAmount(lockedToken, block.timestamp);

        uint256 claimableToken = intialUnlockToken + vestedToken - userData.claimedAmount;

        return claimableToken;
    }

    /**
     * @notice Converts a USD-denominated amount into the equivalent payment token amount
     * @param token The ERC20 payment token address
     * @param usdAmount The USD amount (18 decimals precision)
     * @return The equivalent amount of payment tokens required
     * @dev Uses Chainlink price feeds for token/USD conversion & OracleLib for stale check
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(I_PRICE_FEED);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        uint256 priceFeedDecimals = priceFeed.decimals();

        if (priceFeedDecimals < 18) {
            // casting to 'uint256' is safe because OracleLib guarantees a non-negative answer
            // forge-lint: disable-next-line(unsafe-typecast)
            return (usdAmount * _tokenPrecision(token)) / (uint256(price) * 10 ** (18 - priceFeedDecimals));
        } else {
            // casting to 'uint256' is safe because OracleLib guarantees a non-negative answer
            // forge-lint: disable-next-line(unsafe-typecast)
            return (usdAmount * _tokenPrecision(token) * 10 ** (priceFeedDecimals - 18)) / (uint256(price));
        }
    }

    /**
     * @notice Returns the amount of sale tokens a user will receive for a given USD amount
     * @param usdAmount USD amount in 18-decimal precision
     * @return The amount of sale token in 18-decimal precision
     */
    function getSaleTokenAmountFromUsd(uint256 usdAmount) public view returns (uint256) {
        return usdAmount * PRECISION / I_SALE_TOKEN_PRICE;
    }

    /**
     * @notice Returns the sale token price
     * @return The current sale token price in USD (18 decimals precision)
     */
    function getCurrentPriceInUsd() public view returns (uint256) {
        return I_SALE_TOKEN_PRICE;
    }
}
