// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test{

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedsMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();

    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address weth;
    address wbtc;
    address ethUSDPriceFeed;

    address USER = makeAddr("user");

    uint256 private constant STARTING_BALANCE = 100 ether;
    uint256 private constant STARING_ERC20_BALANCE = 100 ether;
    uint256 private constant AMOUNT_TO_MINT = 100 ether;
    uint256 amountToMint = 100 ether;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUSDPriceFeed,, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_BALANCE);
    }

    /////////////////////////
    ////CONSTRUCTOR TEST////
    //////////////////////// 
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;
    function testRevertIfTokenLengthDoesNotMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);
        priceFeedAddresses.push(ethUSDPriceFeed);
        vm.expectRevert(DSCEngine__TokenAddressesAndPriceFeedsMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////////
    ////PRICEFEED TEST////
    //////////////////////
    function testgetUSDpriceFeed() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUSD = 30000e18;
        uint256 actualUSD = dscEngine.getUSDValue(weth, ethAmount);
        console2.log("the actual ETH price is: {}", actualUSD);
        assertEq(expectedUSD, actualUSD);
    }

    function testGetTokenAmountFromUSD() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenCollateralAmountFromUSD(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    //////////////////////////////
    ////depositCollateral TEST////
    /////////////////////////////
    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), STARTING_BALANCE);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank(); 
    }

    function testRevertIfUnapprovedCollateral() public {
        ERC20Mock testToken = new ERC20Mock("TEST", "TEST", USER, STARING_ERC20_BALANCE);
        vm.prank(USER);
        vm.expectRevert(DSCEngine__TokenNotAllowed.selector);
        dscEngine.depositCollateral(address(testToken), STARING_ERC20_BALANCE);
    }

    modifier depositedCollateral {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), STARING_ERC20_BALANCE);
        dscEngine.depositCollateral(weth, STARING_ERC20_BALANCE);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), STARING_ERC20_BALANCE);
        dscEngine.depositCollateral(weth, STARING_ERC20_BALANCE);
        dscEngine.mintDSC(amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInformation() public depositedCollateral {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = dscEngine.getAccountInformation(USER);
        uint256 expectedDSCMinted = 0;
        uint256 expectedCollateralDepositAmount = dscEngine.getTokenCollateralAmountFromUSD(weth, collateralValueInUSD);

        assertEq(totalDSCMinted, expectedDSCMinted);
        assertEq(STARING_ERC20_BALANCE, expectedCollateralDepositAmount);
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userDSCBalance = dsc.balanceOf(USER);
        assertEq(userDSCBalance, 0);
    }

    function testCanMintWWithDepositedCollateral() public depositedCollateralAndMintedDsc{
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        amountToMint = 150000 ether;
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), STARTING_BALANCE);
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.depositCollateralAndMintDSC(weth, STARTING_BALANCE, amountToMint);
        vm.stopPrank();
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    //////////////////////////////
    ////mintDSC Tests////////////
    /////////////////////////////
    function testRevertIfMintAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDSC(0);
        vm.stopPrank();
    }

    function testCanMintDSC() public depositedCollateral {
        vm.startPrank(USER);
        dscEngine.mintDSC(amountToMint);
        vm.stopPrank();
        
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(ethUSDPriceFeed).latestRoundData();
        amountToMint = (STARTING_BALANCE * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.mintDSC(amountToMint);
        vm.stopPrank();
    }

     

    //////////////////////////////
    ////burnDSC Tests////////////
    /////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDSC(0);
        vm.stopPrank();
    }

    function testCanBurnDSC() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), 50 ether);
        dscEngine.burnDSC(50 ether);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        uint256 expectedBalance = 50 ether;
        assertEq(userBalance, expectedBalance);
    }   

    function testRevertIfUserTriesToBurnBalance() public {
        vm.prank(USER);
        vm.expectRevert();
        dscEngine.burnDSC(STARTING_BALANCE);
    }


    //////////////////////////////////////
    ////redeemCollateral Tests////////////
    //////////////////////////////////////
    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), STARTING_BALANCE);
        dscEngine.depositCollateralAndMintDSC(weth, STARTING_BALANCE, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), STARTING_BALANCE);
        dscEngine.depositCollateralAndMintDSC(weth, STARTING_BALANCE, AMOUNT_TO_MINT);
        dscEngine.redeemCollateral(weth, 10 ether);
        vm.stopPrank();

        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 expectedBalance = 10 ether;
        assertEq(userBalance, expectedBalance);
    }

    function testRevertsIfRedeemAmountBreaksHealthFactor() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), STARTING_BALANCE);
        dscEngine.depositCollateralAndMintDSC(weth, STARTING_BALANCE, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.redeemCollateral(weth, STARTING_BALANCE);
        vm.stopPrank();
    }

    function testCanRedeemCollateralForDSC() public {
        uint256 collateralToRedeem = 10 ether;
        uint256 amountToBurn = 10 ether;
        
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), STARTING_BALANCE);
        dscEngine.depositCollateralAndMintDSC(weth, STARTING_BALANCE, AMOUNT_TO_MINT);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);
        dscEngine.redeemCollateralForDSC(weth, collateralToRedeem, amountToBurn);
        vm.stopPrank();

        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);  
        assertEq(userBalance, collateralToRedeem);
        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, AMOUNT_TO_MINT - amountToBurn);
    }

    function testRevertsIfRedeemCollateralForDSCBreaksHealthFactor() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), STARTING_BALANCE);
        dscEngine.depositCollateralAndMintDSC(weth, STARTING_BALANCE, AMOUNT_TO_MINT);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT / 2);
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.redeemCollateralForDSC(weth, STARTING_BALANCE, AMOUNT_TO_MINT / 2);
        vm.stopPrank();
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 1000 ether;
        uint256 healthFactor = dscEngine.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 200,000 * 0.5 = 100,000
        // 100,000 / 100 = 1000 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUSDUpdatedPrice = 1.8e8; // 1 ETH = $18
        // Rememeber, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUSDPriceFeed).updateAnswer(ethUSDUpdatedPrice);

        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        console2.log("User healthFactor: ", userHealthFactor);
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////////////////
    // healthFactor Tests ////////////
    //////////////////////////////////
    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDSC(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotEligbleForLiquidation.selector);
        dscEngine.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        collateralToCover = 100 ether;
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), STARTING_BALANCE);
        dscEngine.depositCollateralAndMintDSC(weth, STARTING_BALANCE, 100000 ether);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 1400e8; // 1 ETH = $18

        MockV3Aggregator(ethUSDPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDSC(weth, collateralToCover, 1000 ether);
        dsc.approve(address(dscEngine), 1000 ether);
        dscEngine.liquidate(weth, USER, 1000 ether); // We are covering part of the debt debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dscEngine.getTokenCollateralAmountFromUSD(weth, 1000 ether)
            + (dscEngine.getTokenCollateralAmountFromUSD(weth, 1000 ether) / dscEngine.getLiquidationBonus());
        console2.log("Liquidator Weth Balance: ", liquidatorWethBalance);
        console2.log("Expected Weth Balance: ", expectedWeth);
        uint256 hardCodedExpected = 785_714_285_714_285_713;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = dscEngine.getTokenCollateralAmountFromUSD(weth, 1000 ether)
            + (dscEngine.getTokenCollateralAmountFromUSD(weth, 1000 ether) / dscEngine.getLiquidationBonus());

        uint256 usdAmountLiquidated = dscEngine.getUSDValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dscEngine.getUSDValue(weth, STARTING_BALANCE) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 138900000000000000001800;
        console2.log("User Collateral Balance: ", userCollateralValueInUsd);
        console2.log("Expected Collateral Balance: ", expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dscEngine.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, 1000 ether);
    }


    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dscEngine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUSDPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 expectedMinHealthFactor = 1e18;
        uint256 actualMinimumHealthFactor = dscEngine.getMinHealthFactor();
        assertEq(expectedMinHealthFactor, actualMinimumHealthFactor);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = dscEngine.getLiquidationThreshold();
        uint256 expectedLiquidationThreshold = 50;
        assertEq(liquidationThreshold, expectedLiquidationThreshold);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = dscEngine.getAccountInformation(USER);
        uint256 expectedCollateralValue = dscEngine.getUSDValue(weth, STARTING_BALANCE);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public depositedCollateral {
        uint256 collateralBalance = dscEngine.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, STARTING_BALANCE);
    }

}