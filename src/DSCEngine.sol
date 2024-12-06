// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions


pragma solidity ^0.8.19;

/**
 * @title DSCEngine
 * @author Muazu Fadhilullahi
 * @notice This contract is the core of the DSC system, it handles all the logic for minting and redeeming DSC, as well as depositing and withdrawing collateral
 * 
 * The system is desinged to be as minimal as possible and have the token maintain a 1 token == $1 peg
 * The stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithimically stable
 * 
 * It is similar to DAI, if DAI has no governance, no fees and was only backed by WETH and WBTC
 * 
 * Our DSC System should always be overcollateralized. At no point should the value of all collateral <= the $ backed value of all the DSC
 * 
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system
 */

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

contract DSCEngine is ReentrancyGuard {

    ////////////////// 
    ////ERRORS////
    //////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedsMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor();
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorNotEligbleForLiquidation();
    error DSCEngine__HealthFactorNotImproved();

    using OracleLib for AggregatorV3Interface;

    ////////////////// 
    ////STATE VAR////
    //////////////////
    mapping (address token => address pricefeed) s_pricefeed;
    mapping (address user => mapping (address tokenAddress => uint256 amount)) private s_collateralDeposited;
    mapping (address user => uint256 amountDSCMinted) private s_DSCMinted; 
    address[] s_collateralTokens;

    uint256 private constant PRICEFEEDPRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////// 
    ////EVENTS///////
    //////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 tokenAmount);

    ////////////////// 
    ////MODIFIERS////
    //////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0){
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }
    modifier isAllowedToken(address token) {
        if (s_pricefeed[token] == address(0)){
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }
    

    ////////////////// 
    ////FUNCTIONS////
    //////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length){
            revert DSCEngine__TokenAddressesAndPriceFeedsMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++){
            s_pricefeed[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    //EXTERNAL FUNCTIONS////
    ///////////////////////

    /**
     * 
     * @param tokenCollateralAddress The address of the token you want to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDSCToMint The amount of decentralized stablecoin to mint
     * @notice This function will deposit collateral and mint DSC in one transaction.
     */
    function depositCollateralAndMintDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSCToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDSCToMint);
    }

    /**
     * @notice follows CEI pattern
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of the collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success){
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * 
     * @param tokenCollateralAddress The address of the token used as collateral
     * @param amountCollateral The amount of collateral
     * @param amountDSCToBeBurned The amount of Decentralized Stable Coin to be burned 
     * @notice This function burns DSC and redeems underlying collateral in one tranasaction
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSCToBeBurned) external {
        _burnDSC(amountDSCToBeBurned, msg.sender, msg.sender);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor and reverts if broken
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant{
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDSC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // probably not needed 
    }

    /**
     * @notice follows CEI
     * @param amountDSCToMint amount of DSC to mint
     * @notice They must have more collateral value than the minimum threshold 
     */
    function mintDSC(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDSCToMint;
        // Check if the user has enough collateral to mint the requested amount of DSC
        _revertIfHealthFactorIsBroken(msg.sender); 
        bool minted = i_dsc.mint(msg.sender, amountDSCToMint);
        if (!minted){
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * 
     * @param tokenCollateral The ERC20 collateral token address to liquidate
     * @param user The user who has a broken health factor
     * @param debtToCover The amount of DSC you want to burn to improve the user's health factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking users funds
     * @notice The function assumes the protocol is overcollateralized
     * @notice A known bug would be if the protocol was 100% collateralzed or less, then the liquidation bonus would not be possible
     */
    function liquidate(address tokenCollateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        // check healthFactor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorNotEligbleForLiquidation();
        }
        uint256 tokenCollateralAmountFromDebtCovered = getTokenCollateralAmountFromUSD(tokenCollateral, debtToCover);
        
        // give 10% bonus incentive for liquidating a bad user
        uint256 bonusCollateral = (tokenCollateralAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralRedeemed = tokenCollateralAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(tokenCollateral, totalCollateralRedeemed, user, msg.sender);
        _burnDSC(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor){
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);


    }

    function getHealthFactor() external {}

    //////////////////////////////////
    //PRIVATE & INTERNAL FUNCTIONS////
    //////////////////////////////////

    /**
     * 
     * @param amountDSCToBurn Amount of DSC to burn
     * @param onBehalfOf The address that own the DSC
     * @param dscFrom The address that the DSC is held in
     * @dev Low-level internal function, do not call unless called from another function that checks for healthFactor
     */
    function _burnDSC(uint256 amountDSCToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDSCToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDSCToBurn);
        if (!success){
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDSCToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success){
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user) private view returns(uint256 totalDSCMinted, uint256 collateralValueInUSD) {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUSD = getAccountCollateralValueInUSD(user);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) internal pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, they can get liquidated
     */
    function _healthFactor(address user) private view returns(uint256 ) {
        // TOTAL DSC MINTED AND TOTAL COLLATERAL VALUE
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUSD);

    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR){
            revert DSCEngine__BreaksHealthFactor();
        }
    }


    //////////////////////////////////
    //PUBLIC & EXTERNAL FUNCTIONS////
    //////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) external pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getTokenCollateralAmountFromUSD(address tokenCollateral, uint256 usdInWei) public view returns (uint256) {
        // price of ETH Token
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_pricefeed[tokenCollateral]);
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return ((usdInWei * PRECISION) / (uint256(price) * PRICEFEEDPRECISION));
    }

    function getAccountCollateralValueInUSD(address user) public view returns (uint256 totalCollateralValueInUSD){
        // Loop through each collateral token to get the total amount deposited and map it to the price, to get the usd value
        for (uint256 i = 0; i < s_collateralTokens.length; i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUSD += getUSDValue(token, amount);
        }
        return totalCollateralValueInUSD;
    }

    function getUSDValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_pricefeed[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * PRICEFEEDPRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user) external view returns(uint256 totalDSCMinted, uint256 collateralValueInUSD) {
        (totalDSCMinted, collateralValueInUSD) = _getAccountInformation(user);
    }

    function getHealthFactor(address user) external view returns(uint256 healtFactor) {
        healtFactor = _healthFactor(user);
    }

    function getCollateralTokenPriceFeed(address tokenCollateral) external view returns (address priceFeed) {
        priceFeed = s_pricefeed[tokenCollateral];
    }

    function getCollateralTokens() external view returns (address[] memory collateralTokens) {
        collateralTokens = s_collateralTokens;
    }

    function getMinHealthFactor() external pure returns (uint256 healthFactor) {
        healthFactor = MIN_HEALTH_FACTOR;
    }

    function getLiquidationThreshold() external pure returns (uint256 liqThreshold){
        liqThreshold = LIQUIDATION_THRESHOLD;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256 collateralBalance) {
        collateralBalance = s_collateralDeposited[user][token];
    }

    function getAdditionalFeedPrecision() external pure returns (uint256 precision) {
        precision = PRICEFEEDPRECISION;
    }

    function getPrecision() external pure returns (uint256 precision) {
        precision = PRECISION;
    }    

    function getLiquidationBonus() external pure returns (uint256 _LIQUIDATION_BONUS) {
        _LIQUIDATION_BONUS = LIQUIDATION_BONUS;
    }
}