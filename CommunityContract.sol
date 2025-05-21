// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract CommunityContract {
    // This should be a MultiSignerERC7913Weighted multisig account
    address public admin;

    // ======= Admin Management =======
    
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }
    
    constructor(address _admin) {
        require(_admin != address(0), "Admin address cannot be zero");
        admin = _admin;
        emit AdminChanged(address(0), _admin);
    }
    
    function changeAdmin(address _newAdmin) external onlyAdmin {
        require(_newAdmin != address(0), "New admin address cannot be zero");
        address oldAdmin = admin;
        admin = _newAdmin;
        emit AdminChanged(oldAdmin, _newAdmin);
    }

    receive() external payable {}

    // ======= Item Management =======

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

    mapping(uint256 => Item) public items;
    uint256 public itemCount;
    
    event ItemAdded(uint256 indexed itemId, bytes32 itemHash, uint256 initialPrice, uint256 minimalPrice, uint256 depreciationRate, uint256 depreciationInterval, uint256 taxRate);
    event ItemRented(uint256 indexed itemId, address indexed renter, uint256 price);
    event ItemReleased(uint256 indexed itemId, address indexed renter);
    event CitizenDepositReceived(address indexed citizenAddress, uint256 amount);
    
    error ErrorItemDoesNotExist(uint256 itemId);
    error ErrorInsufficientBalanceToRent(uint256 required, uint256 available);
    error ErrorPaymentFailed();
    error ErrorItemIsNotRented(uint256 itemId);
    error ErrorItemIsNotRentedBySender(uint256 itemId, address sender);

    function addItem(
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

        uint256 itemId = itemCount;
        items[itemId] = Item({
            itemHash: _itemHash,
            initialPrice: _initialPrice,
            minimalPrice: _minimalPrice,
            depreciationRate: _depreciationRate,
            depreciationInterval: _depreciationInterval,
            taxRate: _taxRate,
            // Initially lastReleaseTimestamp is equal to creation timestamp
            lastReleaseTimestamp: block.timestamp,
            noticePeriod: _releaseInterval,
            isRented: false,
            rentedByCitizenAddress: address(0),
            currentPrice: _initialPrice
        });
        
        itemCount++;
        
        emit ItemAdded(itemId, _itemHash, _initialPrice, _minimalPrice, _depreciationRate, _depreciationInterval, _taxRate);
    }

    function getItem(uint256 _itemId) external view returns (Item memory) {
        Item storage item = items[_itemId];
        if (item.lastReleaseTimestamp == 0) {
            revert ErrorItemDoesNotExist(_itemId);
        }

        return item;
    }

    function rentItem(uint256 _itemId, uint256 _newPrice) external payable {
        Item storage item = items[_itemId];

        if (item.lastReleaseTimestamp == 0) {
            revert ErrorItemDoesNotExist(_itemId);
        }

        uint256 currentPrice = getItemPrice(_itemId);
        uint256 newRenterCitizenId = citizenIdByAddress[msg.sender];

        if (citizens[newRenterCitizenId].balance < int256(currentPrice)) {
            revert ErrorInsufficientBalanceToRent(currentPrice, msg.value);
        }

        if (item.isRented) {
            // if item is rented, refund the previous renter
            uint256 oldRenterCitizenId = citizenIdByAddress[item.rentedByCitizenAddress];
            citizens[oldRenterCitizenId].balance += int256(item.currentPrice);

            for (uint256 i = 0; i < citizens[oldRenterCitizenId].rentedItems.length; i++) {
                RentedItemMetadata storage rentedItem = citizens[oldRenterCitizenId].rentedItems[i];
                if (rentedItem.itemId == _itemId) {
                    rentedItem.rentedUntil = block.timestamp + item.noticePeriod;
                    break;
                }
            }
        }

        citizens[newRenterCitizenId].balance -= int256(currentPrice);

        item.currentPrice = _newPrice;
        item.rentedByCitizenAddress = msg.sender;
        item.isRented = true;

        citizens[newRenterCitizenId].rentedItems.push(RentedItemMetadata({
            itemId: _itemId,
            rentedFrom: block.timestamp + item.noticePeriod,
            rentedUntil: 0,
            price: _newPrice
        }));

        emit ItemRented(_itemId, msg.sender, _newPrice);
    }

    function releaseItem(uint256 _itemId) external {
        Item storage item = items[_itemId];

        if (item.lastReleaseTimestamp == 0) {
            revert ErrorItemDoesNotExist(_itemId);
        }

        if (!item.isRented) {
            revert ErrorItemIsNotRented(_itemId);
        }

        if (item.rentedByCitizenAddress != msg.sender) {
            revert ErrorItemIsNotRentedBySender(_itemId, msg.sender);
        }

        uint256 citizenId = citizenIdByAddress[msg.sender];
        citizens[citizenId].balance += int256(item.currentPrice);

        item.isRented = false;
        item.lastReleaseTimestamp = block.timestamp;
        item.rentedByCitizenAddress = address(0);
        item.currentPrice = item.initialPrice;

        for (uint256 i = 0; i < citizens[citizenId].rentedItems.length; i++) {
            RentedItemMetadata storage rentedItem = citizens[citizenId].rentedItems[i];
            if (rentedItem.itemId == _itemId) {
                rentedItem.rentedUntil = block.timestamp;
                break;
            }
        }

        emit ItemReleased(_itemId, msg.sender);
    }

    function getCurrentItemRenter(uint256 _itemId) public view returns (address) {
        Item storage item = items[_itemId];
        if (item.lastReleaseTimestamp == 0) {
            revert ErrorItemDoesNotExist(_itemId);
        }

        if (!item.isRented) {
            return address(0);
        }
        
        return item.rentedByCitizenAddress;
    }

    function getItemPrice(uint256 _itemId) public view returns (uint256) {
        Item storage item = items[_itemId];
        if (item.lastReleaseTimestamp == 0) {
            revert ErrorItemDoesNotExist(_itemId);
        }

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
    
    struct Citizen {
        address citizenAddress;
        int256 balance;
        uint256 tokens;
        RentedItemMetadata[] rentedItems;
        uint256 lastTaxUpdateTimestamp;
    }

    struct RentedItemMetadata {
        uint256 itemId;
        uint256 rentedFrom;
        uint256 rentedUntil;
        uint256 price;
    }
    
    mapping(uint256 => Citizen) public citizens;
    uint256 public citizenCount;

    mapping(address => uint256) public citizenIdByAddress;
    
    event CitizenRegistered(address indexed citizenAddress, uint256 indexed citizenId);
    
    function registerCitizen(address _citizenAddress) external {                
        citizens[citizenCount] = Citizen({
            citizenAddress: _citizenAddress,
            balance: 0,
            tokens: 0,
            rentedItems: new RentedItemMetadata[](0),
            lastTaxUpdateTimestamp: block.timestamp
        });
        citizenIdByAddress[_citizenAddress] = citizenCount;

        citizenCount++;
        
        emit CitizenRegistered(msg.sender, citizenCount);
    }

    /* This function is called by the citizen to deposit funds into their balance
    */
    function depositFunds() external payable {
        citizens[citizenIdByAddress[msg.sender]].balance += int256(msg.value);

        emit CitizenDepositReceived(msg.sender, msg.value);
    }

    /* This function is triggered periodically to pay tax for each citizen
    */
    function payTaxes() external {
        for (uint256 i = 0; i < citizenCount; i++) {
            Citizen storage citizen = citizens[i];
            for (uint256 j = 0; j < citizen.rentedItems.length; j++) {
                RentedItemMetadata storage rentedItem = citizen.rentedItems[j];

                uint256 usageStart = citizen.lastTaxUpdateTimestamp;
                if (rentedItem.rentedFrom > citizen.lastTaxUpdateTimestamp) {
                    usageStart = rentedItem.rentedFrom;
                }

                uint256 usageEnd = block.timestamp;
                if (rentedItem.rentedUntil != 0) {
                    usageEnd = rentedItem.rentedUntil;
                }

                uint256 usage = usageEnd - usageStart;

                uint256 amountToPay = rentedItem.price * (items[rentedItem.itemId].taxRate / 100) * usage / (block.timestamp - citizen.lastTaxUpdateTimestamp);

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

    /* Withdrawal of the funds is guarded by the multisig account
     */
    function withdrawFunds(uint256 amount, address to) external onlyAdmin {
        (bool success, ) = to.call{value: amount}("");
        if (!success) {
            revert ErrorPaymentFailed();
        }
    }
}
