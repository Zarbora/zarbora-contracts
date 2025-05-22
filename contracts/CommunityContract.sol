// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "lib/community-contracts/contracts/utils/cryptography/MultiSignerERC7913Weighted.sol";

contract CommunityContract {
    // ======= Admin Management ======= 

    // This should be a MultiSignerERC7913Weighted multisig account
    address public admin;
    IERC20 public usdcToken;
    
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event USDCAddressChanged(address indexed previousUSDC, address indexed newUSDC);
    
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }
    
    constructor(address _admin, address _usdcToken) {
        require(_admin != address(0), "Admin address cannot be zero");
        require(_usdcToken != address(0), "USDC token address cannot be zero");
        admin = _admin;
        usdcToken = IERC20(_usdcToken);
        emit AdminChanged(address(0), _admin);
        emit USDCAddressChanged(address(0), _usdcToken);
    }
    
    function changeAdmin(address _newAdmin) external onlyAdmin {
        require(_newAdmin != address(0), "New admin address cannot be zero");
        address oldAdmin = admin;
        admin = _newAdmin;
        emit AdminChanged(oldAdmin, _newAdmin);
    }

    function changeUSDCAddress(address _newUSDC) external onlyAdmin {
        require(_newUSDC != address(0), "New USDC address cannot be zero");
        address oldUSDC = address(usdcToken);
        usdcToken = IERC20(_newUSDC);
        emit USDCAddressChanged(oldUSDC, _newUSDC);
    }

    /* Withdrawal of the funds is guarded by the multisig account
     */
    function withdrawFunds(uint256 amount, address to) external onlyAdmin {
        bool success = usdcToken.transfer(to, amount);
        if (!success) {
            revert ErrorPaymentFailed();
        }
    }

    // ======= Data Structures =======

    struct Item {
        // Base item settings
        bytes32 itemHash;
        uint256 initialPrice;
        uint256 minimalPrice;
        uint256 depreciationRate;
        uint256 depreciationInterval;
        // if item gets rerented by another citizen, this is the notice period for the current item holder
        uint256 noticePeriod;
        uint256 taxRate;

        // Info about the current rent
        uint256 lastReleaseTimestamp;
        bool isRented;
        address rentedByCitizenAddress;
        uint256 currentPrice;
    }

    struct CityZone {
        bytes32 cityZoneHash;
        uint256 itemCount;
        mapping(uint256 => Item) items;
        mapping(bytes32 => uint256) itemIdByHash;
    }

    struct Society {
        bytes32 societyHash;

        uint256 cityZoneCount;
        mapping(uint256 => CityZone) cityZones;
        mapping(bytes32 => uint256) cityZoneIdByHash;

        uint256 citizenCount;
        mapping(uint256 => Citizen) citizens;
        mapping(address => uint256) citizenIdByAddress;
    }

    struct Citizen {
        address citizenAddress;
        int256 balance;
        uint256 tokens;
        RentedItemMetadata[] rentedItems;
        uint256 lastTaxUpdateTimestamp;
    }

    struct RentedItemMetadata {
        bytes32 itemHash;

        uint256 rentedFrom;
        uint256 rentedUntil;

        uint256 price;
        uint256 taxRate;
    }
        
    event CitizenRegistered(bytes32 indexed societyHash, address indexed citizenAddress, uint256 indexed citizenId);
    event ItemAdded(uint256 indexed itemId, bytes32 itemHash, uint256 initialPrice, uint256 minimalPrice, uint256 depreciationRate, uint256 depreciationInterval, uint256 taxRate);
    event ItemRented(bytes32 indexed societyHash, bytes32 indexed cityZoneHash, bytes32 indexed itemHash, uint256 price, address renter);
    event ItemReleased(bytes32 indexed societyHash, bytes32 indexed cityZoneHash, bytes32 indexed itemHash, address renter);
    event CitizenDepositReceived(bytes32 indexed societyHash, address indexed citizenAddress, uint256 amount);
    
    error ErrorItemDoesNotExist(bytes32 _societyHash, bytes32 _cityZoneHash, bytes32 _itemHash);
    error ErrorInsufficientBalanceToRent(uint256 required, uint256 available);
    error ErrorPaymentFailed();
    error ErrorItemIsNotRented(bytes32 _societyHash, bytes32 _cityZoneHash, bytes32 _itemHash);
    error ErrorItemIsNotRentedBySender(bytes32 _societyHash, bytes32 _cityZoneHash, bytes32 _itemHash, address sender);
    error ErrorSocietyDoesNotExist(bytes32 societyHash);
    error ErrorCityZoneDoesNotExist(bytes32 societyHash, bytes32 cityZoneHash);
    error ErrorCitizenDoesNotExist(bytes32 societyHash, address citizenAddress);

    uint256 public societyCount;
    mapping(uint256 => Society) public societies;
    mapping(bytes32 => uint256) societyIdByHash;

    function addSociety(bytes32 _societyHash) external onlyAdmin {
        societyCount++;

        Society storage society = societies[societyCount];
        society.societyHash = _societyHash;
        society.cityZoneCount = 0;
        
        societyIdByHash[_societyHash] = societyCount;
    }

    function addCityZone(bytes32 _societyHash, bytes32 _cityZoneHash) external onlyAdmin {
        uint256 societyId = societyIdByHash[_societyHash];
        if (societyId == 0) {
            revert ErrorSocietyDoesNotExist(_societyHash);
        }
        Society storage society = societies[societyId];

        society.cityZoneCount++;

        CityZone storage newCityZone = society.cityZones[society.cityZoneCount];
        newCityZone.cityZoneHash = _cityZoneHash;
        newCityZone.itemCount = 0;
        
        society.cityZoneIdByHash[_cityZoneHash] = society.cityZoneCount;
    }

    // ======= Item Management =======

    function addItem(
        bytes32 _societyHash, 
        bytes32 _cityZoneHash,
        bytes32 _itemHash,
        uint256 _initialPrice,
        uint256 _minimalPrice,
        uint256 _depreciationRate,
        uint256 _depreciationInterval,
        uint256 _releaseInterval,
        uint256 _taxRate
    ) external onlyAdmin {
        require(_initialPrice > 0, "Initial price must be greater than 0");
        require(_minimalPrice > 0, "Minimal price must be greater than 0");
        require(_minimalPrice <= _initialPrice, "Minimal price cannot be greater than initial price");
        require(_depreciationRate > 0, "Depreciation rate must be greater than 0");
        require(_depreciationInterval > 0, "Depreciation interval must be greater than 0");
        require(_taxRate >= 0, "Tax rate must be greater than or equal to 0");
        require(_taxRate <= 100, "Tax rate must be less than or equal to 100");

        uint256 societyId = societyIdByHash[_societyHash];
        if (societyId == 0) {
            revert ErrorSocietyDoesNotExist(_societyHash);
        }
        Society storage society = societies[societyId];

        uint256 cityZoneId = society.cityZoneIdByHash[_cityZoneHash];
        if (cityZoneId == 0) {
            revert ErrorCityZoneDoesNotExist(_societyHash, _cityZoneHash);
        }
        CityZone storage cityZone = society.cityZones[cityZoneId];

        cityZone.itemCount++;

        cityZone.items[cityZone.itemCount] = Item({
            itemHash: _itemHash,
            initialPrice: _initialPrice,
            minimalPrice: _minimalPrice,
            depreciationRate: _depreciationRate,
            depreciationInterval: _depreciationInterval,
            taxRate: _taxRate,
            noticePeriod: _releaseInterval,
            // Initially lastReleaseTimestamp is equal to creation timestamp
            lastReleaseTimestamp: block.timestamp,
            isRented: false,
            rentedByCitizenAddress: address(0),
            currentPrice: _initialPrice
        });
        cityZone.itemIdByHash[_itemHash] = cityZone.itemCount;
                
        emit ItemAdded(cityZone.itemCount, _itemHash, _initialPrice, _minimalPrice, _depreciationRate, _depreciationInterval, _taxRate);
    }

    function getItem(bytes32 _societyHash, bytes32 _cityZoneHash, bytes32 _itemHash) public view returns (Item memory) {
        uint256 societyId = societyIdByHash[_societyHash];
        if (societyId == 0) {
            revert ErrorSocietyDoesNotExist(_societyHash);
        }
        Society storage society = societies[societyId];

        uint256 cityZoneId = society.cityZoneIdByHash[_cityZoneHash];
        if (cityZoneId == 0) {
            revert ErrorCityZoneDoesNotExist(_societyHash, _cityZoneHash);
        }
        CityZone storage cityZone = society.cityZones[cityZoneId];

        uint256 itemId = cityZone.itemIdByHash[_itemHash];
        if (itemId == 0) {
            revert ErrorItemDoesNotExist(_societyHash, _cityZoneHash, _itemHash);
        }

        return cityZone.items[itemId];
    }

    /* This function is called by the citizen to rent the item
    */
    function rentItem(bytes32 _societyHash, bytes32 _cityZoneHash, bytes32 _itemHash, uint256 _newPrice) external {
        uint256 societyId = societyIdByHash[_societyHash];
        if (societyId == 0) {
            revert ErrorSocietyDoesNotExist(_societyHash);
        }
        Society storage society = societies[societyId];

        uint256 cityZoneId = society.cityZoneIdByHash[_cityZoneHash];
        if (cityZoneId == 0) {
            revert ErrorCityZoneDoesNotExist(_societyHash, _cityZoneHash);
        }
        CityZone storage cityZone = society.cityZones[cityZoneId];

        uint256 itemId = cityZone.itemIdByHash[_itemHash];
        if (itemId == 0) {
            revert ErrorItemDoesNotExist(_societyHash, _cityZoneHash, _itemHash);
        }
        Item storage item = cityZone.items[itemId];

        uint256 currentPrice = getItemPrice(_societyHash, _cityZoneHash, _itemHash);
        uint256 newRenterCitizenId = society.citizenIdByAddress[msg.sender];

        if (society.citizens[newRenterCitizenId].balance < int256(currentPrice)) {
            revert ErrorInsufficientBalanceToRent(currentPrice, uint256(society.citizens[newRenterCitizenId].balance));
        }

        if (item.isRented) {
            // if item is rented, refund the previous renter
            uint256 oldRenterCitizenId = society.citizenIdByAddress[item.rentedByCitizenAddress];
            society.citizens[oldRenterCitizenId].balance += int256(item.currentPrice);

            for (uint256 i = 0; i < society.citizens[oldRenterCitizenId].rentedItems.length; i++) {
                RentedItemMetadata storage rentedItem = society.citizens[oldRenterCitizenId].rentedItems[i];
                if (rentedItem.itemHash == _itemHash) {
                    rentedItem.rentedUntil = block.timestamp + item.noticePeriod;
                    break;
                }
            }
        }

        society.citizens[newRenterCitizenId].balance -= int256(currentPrice);

        item.currentPrice = _newPrice;
        item.rentedByCitizenAddress = msg.sender;
        item.isRented = true;

        society.citizens[newRenterCitizenId].rentedItems.push(RentedItemMetadata({
            itemHash: _itemHash,
            rentedFrom: block.timestamp + item.noticePeriod,
            rentedUntil: 0,
            price: _newPrice,
            taxRate: item.taxRate
        }));

        emit ItemRented(_societyHash, _cityZoneHash, _itemHash, _newPrice, msg.sender);
    }

    /* This function is called by the renter to release the item
    */
    function releaseItem(bytes32 _societyHash, bytes32 _cityZoneHash, bytes32 _itemHash) external {
        uint256 societyId = societyIdByHash[_societyHash];
        if (societyId == 0) {
            revert ErrorSocietyDoesNotExist(_societyHash);
        }
        Society storage society = societies[societyId];

        uint256 cityZoneId = society.cityZoneIdByHash[_cityZoneHash];
        if (cityZoneId == 0) {
            revert ErrorCityZoneDoesNotExist(_societyHash, _cityZoneHash);
        }
        CityZone storage cityZone = society.cityZones[cityZoneId];

        uint256 itemId = cityZone.itemIdByHash[_itemHash];
        if (itemId == 0) {
            revert ErrorItemDoesNotExist(_societyHash, _cityZoneHash, _itemHash);
        }
        Item storage item = cityZone.items[itemId];

        if (!item.isRented) {
            revert ErrorItemIsNotRented(_societyHash, _cityZoneHash, _itemHash);
        }

        if (item.rentedByCitizenAddress != msg.sender) {
            revert ErrorItemIsNotRentedBySender(_societyHash, _cityZoneHash, _itemHash, msg.sender);
        }

        uint256 citizenId = society.citizenIdByAddress[msg.sender];
        society.citizens[citizenId].balance += int256(item.currentPrice);

        item.isRented = false;
        item.lastReleaseTimestamp = block.timestamp;
        item.rentedByCitizenAddress = address(0);
        item.currentPrice = item.initialPrice;

        for (uint256 i = 0; i < society.citizens[citizenId].rentedItems.length; i++) {
            RentedItemMetadata storage rentedItem = society.citizens[citizenId].rentedItems[i];
            if (rentedItem.itemHash == _itemHash) {
                rentedItem.rentedUntil = block.timestamp;
                break;
            }
        }

        emit ItemReleased(_societyHash, _cityZoneHash, _itemHash, msg.sender);
    }

    function getCurrentItemRenter(bytes32 _societyHash, bytes32 _cityZoneHash, bytes32 _itemHash) public view returns (address) {
        Item memory item = getItem(_societyHash, _cityZoneHash, _itemHash);

        if (!item.isRented) {
            return address(0);
        }
        
        return item.rentedByCitizenAddress;
    }

    /* Returns the current price of the item,
    /* If the item is unoccupied, then depreciation logic is applied
    */
    function getItemPrice(bytes32 _societyHash, bytes32 _cityZoneHash, bytes32 _itemHash) public view returns (uint256) {
        Item memory item = getItem(_societyHash, _cityZoneHash, _itemHash);

        if (item.isRented) {
            return item.currentPrice;
        }

        // item is unoccupied, apply depreciation logic based on the Dutch Auction model
        uint256 depreciation = (block.timestamp - item.lastReleaseTimestamp) / item.depreciationInterval;
        uint256 depreciatedPrice = item.initialPrice - item.depreciationRate * depreciation;

        if (depreciatedPrice < item.minimalPrice) {
            return item.minimalPrice;
        }

        return depreciatedPrice;
    }
    
    // ======= Citizen Management =======
        
    function registerCitizen(bytes32 _societyHash, address _citizenAddress) external {                
        uint256 societyId = societyIdByHash[_societyHash];
        if (societyId == 0) {
            revert ErrorSocietyDoesNotExist(_societyHash);
        }
        Society storage society = societies[societyId];

        society.citizenCount++;

        Citizen storage citizen = society.citizens[society.citizenCount];
        citizen.citizenAddress = _citizenAddress;
        citizen.balance = 0;
        citizen.tokens = 0;
        citizen.rentedItems = new RentedItemMetadata[](0);
        citizen.lastTaxUpdateTimestamp = block.timestamp;

        society.citizenIdByAddress[_citizenAddress] = society.citizenCount;

        emit CitizenRegistered(_societyHash, _citizenAddress, society.citizenCount);
    }

    /* This function is called by the citizen to deposit funds into their balance
    */
    function depositFunds(bytes32 _societyHash, uint256 amount) external {
        uint256 societyId = societyIdByHash[_societyHash];
        if (societyId == 0) {
            revert ErrorSocietyDoesNotExist(_societyHash);
        }
        Society storage society = societies[societyId];

        uint256 citizenId = society.citizenIdByAddress[msg.sender];
        if (citizenId == 0) {
            revert ErrorCitizenDoesNotExist(_societyHash, msg.sender);
        }

        bool success = usdcToken.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert ErrorPaymentFailed();
        }

        society.citizens[citizenId].balance += int256(amount);
        
        emit CitizenDepositReceived(_societyHash, msg.sender, amount);
    }

    /* This function is triggered periodically to pay tax for each citizen
    */
    function payTaxes(bytes32 _societyHash) external {
        uint256 societyId = societyIdByHash[_societyHash];
        if (societyId == 0) {
            revert ErrorSocietyDoesNotExist(_societyHash);
        }
        Society storage society = societies[societyId];

        for (uint256 i = 0; i < society.citizenCount; i++) {
            Citizen storage citizen = society.citizens[i];
            for (uint256 j = 0; j < citizen.rentedItems.length; j++) {
                RentedItemMetadata storage rentedItem = citizen.rentedItems[j];

                // item was never used, skip it
                if (rentedItem.rentedUntil != 0 && rentedItem.rentedFrom > rentedItem.rentedUntil) {
                    continue;
                }

                uint256 usageStart = citizen.lastTaxUpdateTimestamp;
                if (rentedItem.rentedFrom > citizen.lastTaxUpdateTimestamp) {
                    usageStart = rentedItem.rentedFrom;
                }

                uint256 usageEnd = block.timestamp;
                if (rentedItem.rentedUntil != 0) {
                    usageEnd = rentedItem.rentedUntil;
                }

                uint256 usage = usageEnd - usageStart;

                uint256 amountToPay = rentedItem.price * rentedItem.taxRate * usage / (block.timestamp - citizen.lastTaxUpdateTimestamp) / 100;

                citizen.balance -= int256(amountToPay);
                citizen.tokens += amountToPay;
            }

            // delete released items from the citizen's rentedItems array
            for (uint256 j = 0; j < citizen.rentedItems.length; j++) {
                RentedItemMetadata storage rentedItem = citizen.rentedItems[j];
                if (rentedItem.rentedUntil != 0) {
                    for (uint256 k = j + 1; k < citizen.rentedItems.length; k++) {
                        citizen.rentedItems[k - 1] = citizen.rentedItems[k];
                    }
                    citizen.rentedItems.pop();
                }
            }

            citizen.lastTaxUpdateTimestamp = block.timestamp;
        }
    }
}
