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

    /// @dev Stores purchase and vesting data for each user
    mapping(address user => UserData data) public sUserData;

    ////////////////////
    // Constants      //
    ////////////////////
    uint256 private constant PRECISION = 1e18;

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

    /////////////////
    // Events      //
    /////////////////
    event TokensPurchased(address indexed buyer, uint256 paymentTokenAmount, uint256 saleTokenAmount);

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
     * @dev Sets initial sale state to PENDING
     */
    constructor(
        address paymentTokenAddress,
        address priceFeedAddress,
        uint256 saleTokenPrice,
        uint256 saleEndTime,
        uint256 maxTokenForSale,
        uint256 softCap,
        uint256 maxTokenPerUser
    ) Ownable(msg.sender) {
        I_PAYMENT_TOKEN = paymentTokenAddress;
        I_PRICE_FEED = priceFeedAddress;
        I_SALE_TOKEN_PRICE = saleTokenPrice;
        I_SALE_END_TIME = saleEndTime;
        I_MAX_TOKEN_FOR_SALE = maxTokenForSale;
        I_SOFT_CAP = softCap;
        I_MAX_TOKEN_PER_USER = maxTokenPerUser;

        sSaleFinalized = SaleFinalized.PENDING;
    }

    /////////////////////////
    // OWNER FUNCTIONS     //
    /////////////////////////
    /**
     * @notice Sets the ERC20 token that will be distributed to participants
     * @param saleTokenAddress The address of the sale token contract
     * @dev Only callable by the contract owner
     */
    function setSaleToken(address saleTokenAddress) external onlyOwner {
        sSaleToken = saleTokenAddress;
    }

    function finalizeSale() external onlyOwner {}

    function withdrawFunds() external onlyOwner {}

    function withdrawUnsoldTokens() external onlyOwner {}

    //////////////////////////
    // External Functions   //
    //////////////////////////
    /**
     * @param usdAmount The USD-denominated amount (18 decimals / wei precision)
     *         the user wants to spend to buy sale tokens
     * @notice This function transfers accepted payment tokens from the user
     *         and records the purchased sale token allocation in storage
     * @dev Purchased sale tokens are tracked in a mapping and can be claimed
     *         later through a calim function
     */
    function buyTokens(uint256 usdAmount) external nonReentrant {
        if (block.timestamp > I_SALE_END_TIME) revert TokenICO__SaleIsOver();
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

    function claim() external {}

    function refund() external {}

    //////////////////////////
    // Internal Functions   //
    //////////////////////////
    function _tokenPrecision(address token) internal view returns (uint256) {
        return 10 ** IERC20Metadata(token).decimals();
    }

    ///////////////////////////////
    // Public & View Functions   //
    ///////////////////////////////
    function vestedTokenAmount(uint256 totalAllocation, uint256 timestamp) public view returns (uint256) {}

    /**
     * @notice Converts a USD-denominated amount into the equivalent payment token amount
     * @param token The ERC20 payment token address
     * @param usdAmount The USD amount (18 decimals precision)
     * @return The equivalent amount of payment tokens required
     * @dev Uses Chainlink price feeds for token/USD conversion
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
