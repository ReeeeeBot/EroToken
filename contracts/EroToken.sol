// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./Libraries.sol";

////////////////////////////////////////////////////////////////////////////////////////////////////////
//EroToken Contract ////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////

contract ErgoToken is IBEP20, Ownable
{
    using Address for address;
    using EnumerableSet for EnumerableSet.AddressSet;
    
    mapping (address => uint256) private _balances;
    mapping (address => mapping (address => uint256)) private _allowances;
    mapping (address => uint256) private _sellLock;
    mapping (address => bool) private _NoDiamondPaws;

    EnumerableSet.AddressSet private _excluded;
    EnumerableSet.AddressSet private _whiteList;
    EnumerableSet.AddressSet private _excludedFromSellLock;
    EnumerableSet.AddressSet private _excludedFromStaking;
    //Token Info
    string private constant _name = 'BabyDot';
    string private constant _symbol = 'bDOT';
    uint8 private constant _decimals = 18;
    uint256 public constant _totalSupply= 101 * 10**_decimals;//equals 101

    //BotProtection values
    bool private _botProtection;
    uint8 constant BotMaxTax=99;
    uint256 constant BotTaxTime=10 minutes;
    uint256 public launchTimestamp;
    uint8 private constant _whiteListBonus=20;

    //Divider for the Minimal MaxBalance based on circulating Supply (1%)
    uint8 public constant BalanceLimitDivider=100;
    //Divider for Minimal sellLimit based on circulating Supply (0.05%)
    uint16 public constant SellLimitDivider=2000;
    //Sellers get locked for MaxSellLockTime so they can't dump repeatedly
    uint16 public constant MaxSellLockTime= 2 hours;
    //The time Liquidity gets locked at start and prolonged once it gets released
    uint256 private constant DefaultLiquidityLockTime=7 days;
    //Limits max tax, only gets applied for tax changes, doesn't affect inital Tax
    uint8 public constant MaxTax=20;
    //Tracks the current Taxes, different Taxes can be applied for buy/sell/transfer
    uint8 private _liquidityTax;
    uint8 private _stakingTax;  
    uint8 private _buyTax;
    uint8 private _sellTax;
    uint8 private _transferTax;


    
    
    
    //The Team Wallet is a Multisig wallet that reqires 3 signatures for each action
    address public constant TeamWallet=0x06Fc243b2728CbF85C0ea156F2348E59FBaE3F8F;
    //TODO: Change to Mainnet
    //TestNet
    //address private constant PancakeRouter=0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3;
    address private constant PancakeRouter=0xfd51DF2Ca9A27e79f3494d2AA316c129C6dFE341;
    //MainNet
    // address private constant PancakeRouter=0x10ED43C718714eb63d5aA57B78B54704E256024E;
    //TODO: Change to Mainnet
    // address tokenToClaim=0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402;//DOT
    //Testnet BUSD
    address tokenToClaim=0xEEe39353dD59993CBA9C0EF76FfBC5Ac6BbCfB11;
    //address tokenToClaim=0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7;


    //variables that track balanceLimit and sellLimit,
    //can be updated based on circulating supply and Sell- and BalanceLimitDividers
    uint256 public  balanceLimit;
    uint256 public  sellLimit;


    


       
    address private _pancakePairAddress; 
    IPancakeRouter02 private  _pancakeRouter;
    
    //modifier for functions only the team can call
    modifier onlyTeam() {
        require(_isTeam(msg.sender), "Caller not in Team");
        _;
    }
    //Checks if address is in Team, is needed to give Team access even if contract is renounced
    //Team doesn't have access to critical Functions that could turn this into a Rugpull(Exept liquidity unlocks)
    function _isTeam(address addr) private view returns (bool){
        return addr==owner()||addr==TeamWallet;
    }


    ////////////////////////////////////////////////////////////////////////////////////////////////////////
    //Constructor///////////////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////////////////////////////
    constructor () {
        // Pancake Router
        _pancakeRouter = IPancakeRouter02(PancakeRouter);
        //Creates a Pancake Pair
        _pancakePairAddress = IPancakeFactory(_pancakeRouter.factory()).createPair(address(this), _pancakeRouter.WETH());
        
        //excludes Pancake Router, pair, contract and burn address from staking
        _excludedFromStaking.add(address(this));
        _excludedFromStaking.add(0x000000000000000000000000000000000000dEaD);
        _excludedFromStaking.add(address(_pancakeRouter));
        _excludedFromStaking.add(_pancakePairAddress);

        _addToken(address(this),_totalSupply);
        emit Transfer(address(0), address(this), _totalSupply);


        
        //Sets Buy/Sell limits
        sellLimit=_totalSupply/SellLimitDivider;
        balanceLimit=_totalSupply/BalanceLimitDivider;

        //Limits start disabled
        sellLockDisabled=true;
        
       //Sets sellLockTime to be max by default
        sellLockTime=MaxSellLockTime;
        _transferTax=50;
        _buyTax=10;
        _sellTax=20;

        //100% of the tax goes to Liquidity at start to generate a lot of liquidity during
        //bot Protection
        _stakingTax=0;
        _liquidityTax=100;

        //Team wallet and deployer are excluded from Taxes
        _excluded.add(msg.sender);
        _excluded.add(TeamWallet);


    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////
    //Transfer functionality////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////////////////////////////
    //Address that is excluded for one transaction
    address private oneTimeExcluced;

    //transfer function, every transfer runs through this function
    function _transfer(address sender, address recipient, uint256 amount) private{
        require(sender != address(0), "Transfer from zero");
        require(recipient != address(0), "Transfer to zero");
        
        //Manually Excluded adresses are transfering tax and lock free
        bool isExcluded = (_excluded.contains(sender) || _excluded.contains(recipient));
        if(oneTimeExcluced==recipient){
            oneTimeExcluced=address(0);
            isExcluded=true;
        }
        //Transactions from and to the contract are always tax and lock free
        bool isContractTransfer=(sender==address(this) || recipient==address(this));
        
        //transfers between PancakeRouter and PancakePair are tax and lock free
        address pancakeRouter=address(_pancakeRouter);
        bool isLiquidityTransfer = ((sender == _pancakePairAddress && recipient == pancakeRouter) 
        || (recipient == _pancakePairAddress && sender == pancakeRouter));

        //differentiate between buy/sell/transfer to apply different taxes/restrictions
        bool isSell=recipient==_pancakePairAddress|| recipient == pancakeRouter;
        bool isBuy=sender==_pancakePairAddress|| sender == pancakeRouter;


        //Pick transfer
        if(isContractTransfer || isLiquidityTransfer || isExcluded){
            _feelessTransfer(sender, recipient, amount);
        }
        else{ 
            //once trading is enabled, it can't be turned off again
            require(tradingEnabled,"trading not yet enabled");
            _taxedTransfer(sender,recipient,amount,isBuy,isSell);                  
        }
    }

    //applies taxes, checks for limits, locks generates autoLP and stakingBNB, and autostakes
    function _taxedTransfer(address sender, address recipient, uint256 amount,bool isBuy,bool isSell) private{
        uint256 recipientBalance = _balances[recipient];
        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "Transfer exceeds balance");

        uint8 tax;
        if(isSell){
            if(!sellLockDisabled&&!_excludedFromSellLock.contains(sender)){
                require(_sellLock[sender]<=block.timestamp,"Seller in sellLock");
                //Sets the time sellers get locked(2 hours by default)
                _sellLock[sender]=block.timestamp+sellLockTime;
                //Sells can't exceed the sell limit(50.000 Tokens at start, can be updated to circulating supply)
                require(amount<=sellLimit,"Dump protection");
            }
            //As soon someone sells, diamondPaws are gone
            _NoDiamondPaws[sender]=true;
            tax=_sellTax;

        } else if(isBuy){
            //Checks If the recipient balance(excluding Taxes) would exceed Balance Limit
            require(recipientBalance+amount<=balanceLimit,"whale protection");
            tax=_getBuyTax(recipient);

        } else {//Transfer
            //withdraws BNB when sending less or equal to 1 Token
            //that way you can withdraw without connecting to any dApp.
            //might needs higher gas limit
            if(amount<=10**(_decimals)) claimToken(sender,tokenToClaim,0);
            //Checks If the recipient balance(excluding Taxes) would exceed Balance Limit
            require(recipientBalance+amount<=balanceLimit,"whale protection");
            //Transfers are disabled in sell lock, this doesn't stop someone from transfering before
            //selling, but there is no satisfying solution for that, and you would need to pax additional tax
            if(!_excludedFromSellLock.contains(sender))
                require(_sellLock[sender]<=block.timestamp||sellLockDisabled,"Sender in Lock");
            tax=_transferTax;

        }     
        //Swapping AutoLP and MarketingBNB is only possible if sender is not pancake pair, 
        //if its not manually disabled, if its not already swapping and if its a Sell to avoid
        // people from causing a large price impact from repeatedly transfering when theres a large backlog of Tokens
        if((sender!=_pancakePairAddress)&&(!manualConversion)&&(!_isSwappingContractModifier)&&isSell)
            _swapContractToken(AutoLPTreshold,false);
        
        //Calculates the exact token amount for each tax
        //staking and liquidity Tax get treated the same, only during conversion they get split
        uint256 contractToken=_calculateFee(amount, tax, _stakingTax+_liquidityTax);
        //Subtract the Taxed Tokens from the amount
        uint256 taxedAmount=amount-contractToken;

        //Removes token and handles staking
        _removeToken(sender,amount);
        
        //Adds the taxed tokens to the contract wallet
       _addToken(address(this), contractToken);

        //Adds token and handles staking
        _addToken(recipient, taxedAmount);
        
        emit Transfer(sender,recipient,taxedAmount);
    }

    function _getBuyTax(address recipient) private returns (uint8)
    {
        if(!_botProtection) return _buyTax;
        if(block.timestamp<(launchTimestamp+BotTaxTime)){
            uint8 tax=_calculateLaunchTax();
            if(_whiteList.contains(recipient)){
                if(tax<(_buyTax+_whiteListBonus)) tax=_buyTax;
                else tax-=_whiteListBonus;
            }
            return tax;
        }
        _botProtection=false;
        _liquidityTax=50;
        _stakingTax=50;
        return _buyTax;
    }
    //Calculates the buy tax right after Launch
    function _calculateLaunchTax() private view returns (uint8){
        if(block.timestamp>launchTimestamp+BotTaxTime) return _buyTax;
        uint256 timeSinceLaunch=block.timestamp-launchTimestamp;
        uint8 Tax=uint8(BotMaxTax-((BotMaxTax-_buyTax)*timeSinceLaunch/BotTaxTime));
        return Tax;
    }



    //Feeless transfer only transfers and autostakes
    function _feelessTransfer(address sender, address recipient, uint256 amount) private{
        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "Transfer exceeds balance");
        //Removes token and handles staking
        _removeToken(sender,amount);
        //Adds token and handles staking
        _addToken(recipient, amount);
        
        emit Transfer(sender,recipient,amount);

    }
    //Calculates the token that should be taxed
    function _calculateFee(uint256 amount, uint8 tax, uint8 taxPercent) private pure returns (uint256) {
        return (amount*tax*taxPercent) / 10000;
    }
    ////////////////////////////////////////////////////////////////////////////////////////////////////////
    //BNB Autostake/////////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////////////////////// 
    //Autostake uses the balances of each holder to redistribute auto generated BNB.
    //Each transaction _addToken and _removeToken gets called for the transaction amount
    //WithdrawBNB can be used for any holder to withdraw BNB at any time, like true Staking,
    //so unlike MRAT clones you can leave and forget your Token and claim after a while

    //lock for the withdraw
    bool private _isWithdrawing;
    //Multiplier to add some accuracy to profitPerShare
    uint256 private constant DistributionMultiplier = 2**64;
    //profit for each share a holder holds, a share equals a token.
    uint256 public profitPerShare;
    //The total shares + _totalSupply to avoid an underflow when substracting
    //need to use getTotalShares to get the actual shares
    uint256 private _totalShares=_totalSupply;
    //the total reward distributed through staking, for tracking purposes
    uint256 public totalStakingReward;
    //the total payout through staking, for tracking purposes
    uint256 public totalPayouts;
    
    //marketing share starts at 50% to push initial marketing, after start
    //its capped to 50% max, the percentage of the staking that gets used for
    //marketing/paying the team
    uint8 public marketingShare=50;
    //balance that is claimable by the team
    uint256 public marketingBalance;

    //Mapping of the already paid out(or missed) shares of each staker
    mapping(address => uint256) private alreadyPaidShares;
    //Mapping of shares that are reserved for payout
    mapping(address => uint256) private toBePaid;

    function getTotalShares() public view returns (uint256){
        return _totalShares-_totalSupply;
    }
    //Contract, pancake and burnAddress are excluded, other addresses like CEX
    //can be manually excluded, excluded list is limited to 30 entries to avoid a
    //out of gas exeption during sells
    function isExcludedFromStaking(address addr) public view returns (bool){
        return _excludedFromStaking.contains(addr);
    }

    //adds Token to balances, adds new BNB to the toBePaid mapping and resets staking
    function _addToken(address addr, uint256 amount) private {
        //the amount of token after transfer
        uint256 newAmount=_balances[addr]+amount;
        
        if(isExcludedFromStaking(addr)){
           _balances[addr]=newAmount;
           return;
        }
        _totalShares+=amount;
        //gets the payout before the change
        uint256 payment=_newDividentsOf(addr);
        //resets dividents to 0 for newAmount
        alreadyPaidShares[addr] = profitPerShare * newAmount;
        //adds dividents to the toBePaid mapping
        toBePaid[addr]+=payment; 
        //sets newBalance
        _balances[addr]=newAmount;
    }
    
    
    //removes Token, adds BNB to the toBePaid mapping and resets staking
    function _removeToken(address addr, uint256 amount) private {
        //the amount of token after transfer
        uint256 newAmount=_balances[addr]-amount;
        
        if(isExcludedFromStaking(addr)){
           _balances[addr]=newAmount;
           return;
        }
        _totalShares-=amount;
        //gets the payout before the change
        uint256 payment=_newDividentsOf(addr);
        //sets newBalance
        _balances[addr]=newAmount;
        //resets dividents to 0 for newAmount
        alreadyPaidShares[addr] = profitPerShare * newAmount;
        //adds dividents to the toBePaid mapping
        toBePaid[addr]+=payment; 
    }
    
    
    //gets the not dividents of a staker that aren't in the toBePaid mapping 
    //returns wrong value for excluded accounts
    function _newDividentsOf(address staker) private view returns (uint256) {
        uint256 fullPayout = profitPerShare * _balances[staker];
        // if theres an overflow for some unexpected reason, return 0, instead of 
        // an exeption to still make trades possible
        if(fullPayout<alreadyPaidShares[staker]) return 0;
        return (fullPayout - alreadyPaidShares[staker]) / DistributionMultiplier;
    }

    //distributes bnb between marketing share and dividents 
    function _distributeStake(uint256 BNBamount,bool newStakingReward) private {
        // Deduct marketing Tax
        uint256 marketingSplit = (BNBamount * marketingShare) / 100;
        uint256 amount = BNBamount - marketingSplit;

       marketingBalance+=marketingSplit;
       
        if (amount > 0) {
            if(newStakingReward){
                totalStakingReward += amount;
            }
            uint256 totalShares=getTotalShares();
            //when there are 0 shares, add everything to marketing budget
            if (totalShares == 0) {
                marketingBalance += amount;
            }else{
                //Increases profit per share based on current total shares
                profitPerShare += ((amount * DistributionMultiplier) / totalShares);
            }
        }
    }
    event OnWithdrawToken(uint256 amount, address token, address recipient);

    function TeamSetDiamondPaws(uint8 fee, bool feeOn) public onlyTeam{
        require(fee<=50,"diamond paws Fee is capped to 50%");
        noDiamondPawsFeeOn=feeOn;
        noDiamondPawsFeePercent=fee;
    }
    uint8 public noDiamondPawsFeePercent=50;
    bool public noDiamondPawsFeeOn=true;

    //withdraws all dividents of address
    function claimToken(address addr, address token, uint256 payableAmount) private{
        require(!_isWithdrawing);
        _isWithdrawing=true;
        uint256 amount;
        if(isExcludedFromStaking(addr)){
            //if excluded just withdraw remaining toBePaid BNB
            amount=toBePaid[addr];
            toBePaid[addr]=0;
        }
        else{
            uint256 newAmount=_newDividentsOf(addr);
            //sets payout mapping to current amount
            alreadyPaidShares[addr] = profitPerShare * _balances[addr];
            //the amount to be paid 
            amount=toBePaid[addr]+newAmount;
            toBePaid[addr]=0;
        }
        if(amount==0&&payableAmount==0){//no withdraw if 0 amount
            _isWithdrawing=false;
            return;
        }
        //If you don't have diamond paws you are redistributing a part of your reward
        //Compound wont be punished
        if(noDiamondPawsFeeOn&&_NoDiamondPaws[addr]&&token!=address(this)){
            uint256 noDiamondPawsFee=amount*noDiamondPawsFeePercent/100;
            amount=amount-noDiamondPawsFee;
            _distributeStake(noDiamondPawsFee,false);
        }

        totalPayouts+=amount;
        amount+=payableAmount;
        address[] memory path = new address[](2);
        path[0] = _pancakeRouter.WETH(); //BNB
        path[1] = token;

        _pancakeRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
        0,
        path,
        addr,
        block.timestamp);
        
        emit OnWithdrawToken(amount,token, addr);
        _isWithdrawing=false;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////
    //Swap Contract Tokens//////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////////////////////////////
    
    //tracks auto generated BNB, useful for ticker etc
    uint256 public totalLPBNB;
    //Locks the swap if already swapping
    bool private _isSwappingContractModifier;
    modifier lockTheSwap {
        _isSwappingContractModifier = true;
        _;
        _isSwappingContractModifier = false;
    }

    //swaps the token on the contract for Marketing BNB and LP Token.
    //always swaps the sellLimit of token to avoid a large price impact
    function _swapContractToken(uint16 permilleOfPancake,bool ignoreLimits) private lockTheSwap{
        require(permilleOfPancake<=500);
        uint256 contractBalance=_balances[address(this)];
        uint16 totalTax=_liquidityTax+_stakingTax;
        if(totalTax==0) return;

        uint256 tokenToSwap=_balances[_pancakePairAddress]*permilleOfPancake/1000;
        if(tokenToSwap>sellLimit&&!ignoreLimits) tokenToSwap=sellLimit;
        
        //only swap if contractBalance is larger than tokenToSwap, and totalTax is unequal to 0
        bool NotEnoughToken=contractBalance<tokenToSwap;
        if(NotEnoughToken){
            if(ignoreLimits)
                tokenToSwap=contractBalance;
            else return;
        }

        //splits the token in TokenForLiquidity and tokenForMarketing
        uint256 tokenForLiquidity=(tokenToSwap*_liquidityTax)/totalTax;
        uint256 tokenForMarketing= tokenToSwap-tokenForLiquidity;

        //splits tokenForLiquidity in 2 halves
        uint256 liqToken=tokenForLiquidity/2;
        uint256 liqBNBToken=tokenForLiquidity-liqToken;

        //swaps marktetingToken and the liquidity token half for BNB
        uint256 swapToken=liqBNBToken+tokenForMarketing;
        //Gets the initial BNB balance, so swap won't touch any staked BNB
        uint256 initialBNBBalance = address(this).balance;
        _swapTokenForBNB(swapToken);
        uint256 newBNB=(address(this).balance - initialBNBBalance);
        //calculates the amount of BNB belonging to the LP-Pair and converts them to LP
        uint256 liqBNB = (newBNB*liqBNBToken)/swapToken;
        _addLiquidity(liqToken, liqBNB);
        //Get the BNB balance after LP generation to get the
        //exact amount of token left for Staking
        uint256 distributeBNB=(address(this).balance - initialBNBBalance);
        //distributes remaining BNB between stakers and Marketing
        _distributeStake(distributeBNB,true);
    }
    //swaps tokens on the contract for BNB
    function _swapTokenForBNB(uint256 amount) private {
        _approve(address(this), address(_pancakeRouter), amount);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _pancakeRouter.WETH();

        _pancakeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }
    //Adds Liquidity directly to the contract where LP are locked(unlike safemoon forks, that transfer it to the owner)
    function _addLiquidity(uint256 tokenamount, uint256 bnbamount) private {
        totalLPBNB+=bnbamount;
        _approve(address(this), address(_pancakeRouter), tokenamount);
        _pancakeRouter.addLiquidityETH{value: bnbamount}(
            address(this),
            tokenamount,
            0,
            0,
            address(this),
            block.timestamp
        );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////
    //public functions /////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////////////////////// 
    function getLiquidityReleaseTimeInSeconds() public view returns (uint256){
        if(block.timestamp<_liquidityUnlockTime){
            return _liquidityUnlockTime-block.timestamp;
        }
        return 0;
    }

    function getLimits() public view returns(uint256 balance, uint256 sell){
        return(balanceLimit/10, sellLimit/10);
    }

    function getTaxes() public view returns(uint256 liquidityTax,uint256 marketingTax, uint256 buyTax, uint256 sellTax, uint256 transferTax){
        if(_botProtection) buyTax=_calculateLaunchTax();
        else buyTax= _buyTax;
       
        return (_liquidityTax,_stakingTax,buyTax,_sellTax,_transferTax);
    }

    function getWhitelistedStatus(address AddressToCheck) public view returns(bool){
        return _whiteList.contains(AddressToCheck);
    }

    function hasDiamondPaws(address AddressToCheck) public view returns(bool){
        return !_NoDiamondPaws[AddressToCheck];
    }

    //How long is a given address still locked from selling
    function getAddressSellLockTimeInSeconds(address AddressToCheck) public view returns (uint256){
       uint256 lockTime=_sellLock[AddressToCheck];
       if(lockTime<=block.timestamp){
           return 0;
       }
       return lockTime-block.timestamp;
    }
    function getSellLockTimeInSeconds() public view returns(uint256){
        return sellLockTime;
    }
    
    

    bool allowTaxFreeCompound=true;
    function TeamSetCompoundTaxFree(bool taxFree) public onlyTeam{
        allowTaxFreeCompound=taxFree;
    }

    //withdraws dividents of sender
    function ClaimDOT() public {
        claimToken(msg.sender,tokenToClaim,0);
    }
    function Compound() public{
        if(allowTaxFreeCompound)
            oneTimeExcluced=msg.sender;
        claimToken(msg.sender,address(this),0);
    }
    
    function ClaimAnyToken(address token) public payable{
        claimToken(msg.sender,token,msg.value);
    }
    
    
    function getDividents(address addr) private view returns (uint256){
        if(isExcludedFromStaking(addr)) return toBePaid[addr];
        return _newDividentsOf(addr)+toBePaid[addr];
    }

    function getDividentsOf(address addr) public view returns (uint256){
        uint256 amount=getDividents(addr);
        if(noDiamondPawsFeeOn&&_NoDiamondPaws[addr])
            amount-=amount*noDiamondPawsFeePercent/100;
        return amount;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////
    //Settings//////////////////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////////////////////////////

    bool public sellLockDisabled;
    uint256 public sellLockTime;
    bool public manualConversion;
    uint16 public AutoLPTreshold=50;
    
    function TeamSetAutoLPTreshold(uint16 treshold) public onlyTeam{
        require(treshold>0,"treshold needs to be more than 0");
        require(treshold<=50,"treshold needs to be below 50");
        AutoLPTreshold=treshold;
    }
    
    //Excludes account from Staking total 
    function TeamExcludeFromStaking(address addr) public onlyTeam{
        require(!isExcludedFromStaking(addr));
        _totalShares-=_balances[addr];
        uint256 newDividents=_newDividentsOf(addr);
        alreadyPaidShares[addr]=_balances[addr]*profitPerShare;
        toBePaid[addr]+=newDividents;
        _excludedFromStaking.add(addr);
    }    

    //Includes excluded Account to staking
    function TeamIncludeToStaking(address addr) public onlyTeam{
        require(isExcludedFromStaking(addr));
        _totalShares+=_balances[addr];
        _excludedFromStaking.remove(addr);
        //sets alreadyPaidShares to the current amount
        alreadyPaidShares[addr]=_balances[addr]*profitPerShare;
    }

    function TeamWithdrawMarketingBNB() public onlyTeam{
        uint256 amount=marketingBalance;
        marketingBalance=0;
        (bool sent,) =TeamWallet.call{value: (amount)}("");
        require(sent,"withdraw failed");
    } 
    function TeamWithdrawMarketingBNB(uint256 amount) public onlyTeam{
        require(amount<=marketingBalance);
        marketingBalance-=amount;
        (bool sent,) =TeamWallet.call{value: (amount)}("");
        require(sent,"withdraw failed");
    } 

    //switches autoLiquidity and marketing BNB generation during transfers
    function TeamSwitchManualBNBConversion(bool manual) public onlyTeam{
        manualConversion=manual;
    }
    //Sets SellLockTime, needs to be lower than MaxSellLockTime
    function TeamSetSellLockTime(uint256 sellLockSeconds)public onlyTeam{
            require(sellLockSeconds<=MaxSellLockTime,"Sell Lock time too high");
            sellLockTime=sellLockSeconds;
    } 

    //Sets Taxes, is limited by MaxTax(20%) to make it impossible to create honeypot
    function TeamSetTaxes(uint8 liquidityTaxes, uint8 stakingTaxes,uint8 buyTax, uint8 sellTax, uint8 transferTax) public onlyTeam{
        uint8 totalTax=liquidityTaxes+stakingTaxes;
        require(totalTax==100, "liq+staking needs to equal 100%");
        require(buyTax<=MaxTax&&sellTax<=MaxTax,"taxes higher than max tax");
        require(transferTax<=50,"transferTax higher than max transferTax");        
        _liquidityTax=liquidityTaxes;
        _stakingTax=stakingTaxes;
        
        _buyTax=buyTax;
        _sellTax=sellTax;
        _transferTax=transferTax;
    }
    //How much of the staking tax should be allocated for marketing
    function TeamChangeMarketingShare(uint8 newShare) public onlyTeam{
        require(newShare<=50); 
        marketingShare=newShare;
    }
    
    //manually converts contract token to LP and staking BNB
    function TeamCreateLPandBNB(uint16 PermilleOfPancake, bool ignoreLimits) public onlyTeam{
    _swapContractToken(PermilleOfPancake, ignoreLimits);
    }
    
    
    //Exclude/Include account from fees (eg. CEX)
    function TeamExcludeAccountFromFees(address account) public onlyTeam {
        _excluded.add(account);
    }
    function TeamIncludeAccountToFees(address account) public onlyTeam {
        _excluded.remove(account);
    }
    //Exclude/Include account from fees (eg. CEX)
    function TeamExcludeAccountFromSellLock(address account) public onlyTeam {
        _excludedFromSellLock.add(account);
    }
    function TeamIncludeAccountToSellLock(address account) public onlyTeam {
        _excludedFromSellLock.remove(account);
    }
    
     //Limits need to be at least target, to avoid setting value to 0(avoid potential Honeypot)
    function TeamUpdateLimits(uint256 newBalanceLimit, uint256 newSellLimit) public onlyTeam{
 
        //Calculates the target Limits based on supply
        uint256 targetBalanceLimit=_totalSupply/BalanceLimitDivider;
        uint256 targetSellLimit=_totalSupply/SellLimitDivider;

        require((newBalanceLimit>=targetBalanceLimit), 
        "newBalanceLimit needs to be at least target");
        require((newSellLimit>=targetSellLimit), 
        "newSellLimit needs to be at least target");

        balanceLimit = newBalanceLimit;
        sellLimit = newSellLimit;     
    }

    event OnSwitchSellLock(bool disabled);
    //Disables the timeLock after selling for everyone
    function TeamDisableSellLock(bool disabled) public onlyTeam{
        sellLockDisabled=disabled;
        emit OnSwitchSellLock(disabled);
    }
    ////////////////////////////////////////////////////////////////////////////////////////////////////////
    //Setup Functions///////////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////////////////////////////

    function SetupCreateLP(uint8 TeamTokenPercent) public payable onlyTeam{
        require(IBEP20(_pancakePairAddress).totalSupply()==0,"There are alreadyLP");
        
        uint256 Token=_balances[address(this)];
        
        uint256 TeamToken=Token*TeamTokenPercent/100;
        uint256 LPToken=Token-TeamToken;
        
        _removeToken(address(this),TeamToken);  
        _addToken(msg.sender, TeamToken);
        emit Transfer(address(this), msg.sender, TeamToken);
        
        _addLiquidity(LPToken, msg.value);
        
    }

    
    bool public tradingEnabled;
    //Enables trading for everyone
    function SetupEnableTrading(bool BotProtection) public onlyTeam{
        require(IBEP20(_pancakePairAddress).totalSupply()>0,"there are no LP");
        require(!tradingEnabled);
        tradingEnabled=true;
        _botProtection=BotProtection;
        launchTimestamp=block.timestamp;
        //Liquidity gets locked for 7 days at start, needs to be prolonged once
        //start is successful
        _liquidityUnlockTime=block.timestamp+DefaultLiquidityLockTime;
    }

    function SetupAddOrRemoveWhitelist(address[] memory addresses,bool Add) public onlyTeam{
        for(uint i=0; i<addresses.length; i++){
            if(Add) _whiteList.add(addresses[i]);
            else _whiteList.remove(addresses[i]);
        }
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////
    //Liquidity Lock////////////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////////////////////////////
    //the timestamp when Liquidity unlocks
    uint256 private _liquidityUnlockTime;

    //Sets Liquidity Release to 20% at a time and prolongs liquidity Lock for a Week after Release. 
    //Should be called once start was successful.
    bool public liquidityRelease20Percent;
    function TeamlimitLiquidityReleaseTo20Percent() public onlyTeam{
        liquidityRelease20Percent=true;
    }

    function TeamUnlockLiquidityInSeconds(uint256 secondsUntilUnlock) public onlyTeam{
        _prolongLiquidityLock(secondsUntilUnlock+block.timestamp);
    }
    function _prolongLiquidityLock(uint256 newUnlockTime) private{
        // require new unlock time to be longer than old one
        require(newUnlockTime>_liquidityUnlockTime);
        _liquidityUnlockTime=newUnlockTime;
    }

    //Release Liquidity Tokens once unlock time is over
    function TeamReleaseLiquidity() public onlyTeam {
        //Only callable if liquidity Unlock time is over
        require(block.timestamp >= _liquidityUnlockTime, "Not yet unlocked");
        
        IPancakeERC20 liquidityToken = IPancakeERC20(_pancakePairAddress);
        uint256 amount = liquidityToken.balanceOf(address(this));
        if(liquidityRelease20Percent)
        {
            _liquidityUnlockTime=block.timestamp+DefaultLiquidityLockTime;
            //regular liquidity release, only releases 20% at a time and locks liquidity for another week
            amount=amount*2/10;
            liquidityToken.transfer(TeamWallet, amount);
        }
        else
        {
            //Liquidity release if something goes wrong at start
            //liquidityRelease20Percent should be called once everything is clear
            liquidityToken.transfer(TeamWallet, amount);
        }
    }
    //Removes Liquidity once unlock Time is over, 
    function TeamRemoveLiquidity(bool addToStaking) public onlyTeam {
        //Only callable if liquidity Unlock time is over
        require(block.timestamp >= _liquidityUnlockTime, "Not yet unlocked");
        _liquidityUnlockTime=block.timestamp+DefaultLiquidityLockTime;
        IPancakeERC20 liquidityToken = IPancakeERC20(_pancakePairAddress);
        uint256 amount = liquidityToken.balanceOf(address(this));
        if(liquidityRelease20Percent){
            amount=amount*2/10; //only remove 20% each
        } 
        liquidityToken.approve(address(_pancakeRouter),amount);
        //Removes Liquidity and either distributes liquidity BNB to stakers, or 
        // adds them to marketing Balance
        //Token will be converted
        //to Liquidity and Staking BNB again
        uint256 initialBNBBalance = address(this).balance;
        _pancakeRouter.removeLiquidityETHSupportingFeeOnTransferTokens(
            address(this),
            amount,
            0,
            0,
            address(this),
            block.timestamp
            );
        uint256 newBNBBalance = address(this).balance-initialBNBBalance;
        if(addToStaking){
            _distributeStake(newBNBBalance,true);
        }
        else{
            marketingBalance+=newBNBBalance;
        }

    }
    //Releases all remaining BNB on the contract wallet, so BNB wont be burned
    //Can only be called 30 days after Liquidity unlocks 
    function TeamRemoveRemainingBNB() public onlyTeam{
        require(block.timestamp >= _liquidityUnlockTime+30 days, "Not yet unlocked");
        _liquidityUnlockTime=block.timestamp+DefaultLiquidityLockTime;
        (bool sent,) =TeamWallet.call{value: (address(this).balance)}("");
        require(sent);
    }
    function RescueStrandedToken(address tokenAddress) public onlyTeam{
        require(tokenAddress!=_pancakePairAddress&&tokenAddress!=address(this),"can't Rescue LP token or this token");
        IBEP20 token=IBEP20(tokenAddress);
        token.transfer(msg.sender,token.balanceOf(address(this)));
    }
    ////////////////////////////////////////////////////////////////////////////////////////////////////////
    //external//////////////////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////////////////////////////

    receive() external payable {}
    fallback() external payable {}
    // IBEP20

    function getOwner() external view override returns (address) {
        return owner();
    }

    function name() external pure override returns (string memory) {
        return _name;
    }

    function symbol() external pure override returns (string memory) {
        return _symbol;
    }

    function decimals() external pure override returns (uint8) {
        return _decimals;
    }

    function totalSupply() external pure override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address _owner, address spender) external view override returns (uint256) {
        return _allowances[_owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }
    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "Approve from zero");
        require(spender != address(0), "Approve to zero");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "Transfer > allowance");

        _approve(sender, msg.sender, currentAllowance - amount);
        return true;
    }

    // IBEP20 - Helpers

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 currentAllowance = _allowances[msg.sender][spender];
        require(currentAllowance >= subtractedValue, "<0 allowance");

        _approve(msg.sender, spender, currentAllowance - subtractedValue);
        return true;
    }

}