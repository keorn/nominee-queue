pragma solidity ^0.4.8;

contract ValidatorSet {
    event InitiateChange(bytes32 indexed _parent_hash, address[] _new_set);

    function getValidators() constant returns (address[] _validators);
    function finalizeChange();
}

// ToAdHiReMaAlMaPe

// Anyone can nominate an addresses.
// Nominee has to have stake of at least totalStake/1000.
// Anyone can claim to be the highest nominee,
// if they are higher than the previous highest they become the highest.
// When someone becomes the highest nominee and there is a validator slot they become a validator.
// If nominee is not a validator, nomination can be removed.
// When a nomination is removed the highest nominee is updated if necessary.
// Addresses supported by more than half of the existing validators are the validators.
// Reports count towards relevant tracker.
// When tracker reaches majority of validators:
//   if its malicious the validator gets kicked,
//   if its benign the validator gets slashed 5% of its stake.
// When validator gets kicked or reaches the end of staking period he gets removed.
// When a validator is removed the highest nominee if it exists takes the validator slot
// and is removed from the nominee list.
contract NomineeQueue is ValidatorSet {
    // CONSTANTS

    // System address, used by the block sealer.
    address constant SYSTEM_ADDRESS = 0xfffffffffffffffffffffffffffffffffffffffe;
    // minimalNomination = totalStake/NOMINATION_DIVISOR
    uint public constant NOMINATION_DIVISOR = 1000;
    // Number of validator slots.
    uint public constant MAX_VALIDATORS = 3;
    // Number of blocks after which the validator can be removed.
    uint public constant VALIDATOR_TERM = 100;
    // Proportion of stake removed on benign misbehaviour.
    uint public constant SLASHING_DIVISOR = 20;
    // Stake proportion targeting.
    uint public constant STAKE_TARGET = 60;

    // EVENTS

    event Report(address indexed reporter, address indexed reported, bool indexed malicious);
    event ChangeFinalized(address[] current_set);

    // STRUCTS

    struct ValidatorStatus {
        // Index in the validatorList.
        uint index;
        // Block at which the validator was added.
        uint added;
        // Validator addresses which reported the validator.
        ReportTracker benign;
        ReportTracker malicious;
    }

    // Tracks the reports about current validator.
    struct ReportTracker {
        uint votes;
        // Prevent double voting.
        mapping(address => bool) voted;
    }

    // Nomination status.
    struct NomineeStatus {
        uint stake;
        // Input stake counter, used to determine withdrawal stake.
        uint inputStake;
        // Keep track of nomination balances.
        mapping(address => uint) nominators;
        // Keep track of nominator reward claims.
        mapping(address => uint) lastClaim;
        // Is the nominee currently a validator.
        bool validator;
        // Pointer to a nominee with a higher stake, 0 if the highest.
        address higherNominee;
    }

    // STATE

    uint public totalSupply;
    // Total number of tokens held as validator stake.
    uint public totalStake;

    // Status of the nominees.
    mapping(address => NomineeStatus) nominees;
     // Nominee with the most stake behind him that is keen to be a validator.
    address highestNominee;
    // List of validators to be finalized.
    address[] pendingList;
    // Was the last validator change finalized.
    bool finalized;
    // Current list of validators.
    address[] public validatorList;
    // Status of the validators.
    mapping(address => ValidatorStatus) validators;

    // CONSTRUCTOR

    uint public constant initialStake = 1 ether;
    function NomineeQueue() {
        pendingList.push(0x7d577a597b2742b498cb5cf0c26cdcd726d39e6e);

        address lastValidator;
        for (uint i = 0; i < pendingList.length; i++) {
            totalStake += initialStake;
            address validator = pendingList[i];
            nominees[validator] = NomineeStatus({
                stake: initialStake,
                inputStake: initialStake,
                validator: true,
                higherNominee: lastValidator
            });
            nominees[validator].nominators[validator] = initialStake;
            validators[validator] = ValidatorStatus({
                index: i,
                added: block.number,
                benign: ReportTracker(0),
                malicious: ReportTracker(0)
            });
            lastValidator = validator;
        }
        validatorList = pendingList;
        finalized = true;
    }

    // Called on every block to update node validator list.
    function getValidators() constant returns (address[]) {
        return validatorList;
    }

    // Log desire to change the current list.
    function initiateChange() private when_finalized {
        finalized = false;
        InitiateChange(block.blockhash(block.number - 1), pendingList);
    }

    function finalizeChange() only_system_and_not_finalized {
        validatorList = pendingList;
        finalized = true;
        ChangeFinalized(validatorsList);
    }

    // NOMINEE METHODS

    // Commit stake to a given address tries to traverse the queue from the existing place.
    function nominate(address nominee) payable minimum_stake(nominee) {
        nominateHint(nominee, nominee);
    }

    // Commit stake to a given address and give a hint about the resulting place in the nominee queue.
    // Necessary if the default nomination traversal takes too much gas.
    // Pointer has to be lower than the actual position.
    function nominateHint(address nominee, address hint) payable minimum_stake(nominee) {
        nominees[nominee].stake += msg.value;
        nominees[nominee].inputStake += msg.value;
        nominees[nominee].nominators[msg.sender] += msg.value;
        totalSupply -= msg.value;
        placeNominee(nominee, hint);
    }

    // Adjust `highestNominee` of a nominee until it is correct.
    function placeNominee(address nominee, address hint)
    is_misaligned(nominee)
    is_good_hint(nominee, hint) {
        uint targetStake = nominees[nominee].stake;
        while (nominees[hint].stake < targetStake) {
            hint = nominees[hint].higherNominee;
        }
        nominees[nominee].higherNominee = nominees[hint].higherNominee;
        nominees[hint].higherNominee = nominee;
        claimHighest(nominee);
    }

    function nomineeStake(address nominee) constant returns(uint) {
        return nominees[nominee].stake;
    }

    // Remove stake if its not validating.
    function withdraw(address nominee) is_not_validator(nominee) {
        uint stake = nominees[nominee].nominators[msg.sender];
        nominees[nominee].nominators[msg.sender] = 0;
        nominees[nominee].stake -= stake;
        uint allowance = stake * nominees[nominee].stake / nominees[nominee].inputStake;
        totalSupply += allowance;
        if (msg.sender.send(allowance)) return;
    }

    // NEW VALIDATOR

    function addValidator() private empty_slot has_highest {
        validators[highestNominee].index = pendingList.length;
        pendingList.push(highestNominee);
        totalStake += nominees[highestNominee].stake;
        validators[highestNominee].added = block.number;
        highestNominee = 0;
        initiateChange();
    }

    function kickOldValidator(address validator) {
        removeValidator(validator);
        addValidator();
    }

    function claimHighest(address nominee) private is_highest(nominee) {
        highestNominee = nominee;
    }

    // MALICIOUS MISBEHAVIOUR REPORTING

    // Called when a validator is bad.
    function reportMalicious(address validator) only_validator not_reported_malicious(validator) {
        validators[validator].malicious.votes++;
        validators[validator].malicious.voted[msg.sender] = true;
        removeValidator(validator);
        addValidator();
    }

    // Remove a validator without enough support.
    function removeValidator(address validator) private is_malicious_or_old(validator) {
        totalStake -= nominees[validator].stake;
        uint removedIndex = validators[validator].index;
        uint lastIndex = pendingList.length-1;
        address lastValidator = pendingList[lastIndex];
        // Override the removed validator with the last one.
        pendingList[removedIndex] = lastValidator;
        // Update the index of the last validator.
        validators[lastValidator].index = removedIndex;
        delete pendingList[lastIndex];
        pendingList.length--;
        validators[validator].index = 0;
        initiateChange();
    }

    // BENIGN MISBEHAVIOUR REPORTING

    // Called on benign validator misbehaviour.
    function reportBenign(address validator) only_validator {
        validators[validator].benign.votes++;
        validators[validator].benign.voted[msg.sender] = true;
        slash(validator);
    }

    function slash(address validator) is_benign(validator) {
        uint toSlash = nominees[validator].stake / SLASHING_DIVISOR;
        nominees[validator].stake -= toSlash;
        totalStake -= toSlash;
    }

    // REWARD CLAIMING

    // Called to receive rewards for a given validator.
    function claimRewards(address validator) is_validator(validator) {
        var nominee = nominees[validator];
        // Number of blocks for which rewards can be claimed.
        uint timeElapsed = block.number - max(validators[validator].added, nominee.lastClaim[msg.sender]);
        // Total issuance at the current issuance level.
        uint currentTotal = issuance() * timeElapsed;
        // Reward scaled by current nominee and nominator stake.
        // everyone * nomineeProportion   *  slashedNominator (scaled as proportion of nominee)
        // total * (nominee / totalStake) * ((nominator * (nominee / initial)) / nominee)
        // total * nominee * nominator / initial / totalStake
        uint reward = currentTotal * nominee.stake * nominee.nominators[msg.sender] / nominee.inputStake / totalStake;
        nominee.lastClaim[msg.sender] = block.number;
        totalSupply += reward;
        if (!msg.sender.send(reward)) throw;
    }

    // CONSTANT UTILITY FUNCTIONS

    function max(uint one, uint two) constant returns(uint) {
        if (one > two) {
            return one;
        } else {
            return two;
        }
    }

    function saturatingSub(uint one, uint two) constant returns(uint) {
        if (two >= one) {
            return 0;
        } else {
            return one - two;
        }
    }

    function issuance() constant returns(uint) {
        uint totalTokens = totalStake + totalSupply;
        uint stakePercentage = 100 * totalStake / totalTokens;
        return totalTokens * saturatingSub(STAKE_TARGET, stakePercentage) / (stakePercentage**2*100+10000);
    }

    // MODIFIERS

    modifier minimum_stake(address nominee) {
        if (nominees[nominee].stake + msg.value < totalStake / NOMINATION_DIVISOR) {
            throw;
        }
        _;
    }

    modifier only_validator() {
        if (!nominees[msg.sender].validator) {
            throw;
        }
        _;
    }

    modifier not_reported_malicious(address validator) {
        if (validators[validator].malicious.voted[msg.sender]) {
            throw;
        }
        _;
    }

    modifier not_reported_benign(address validator) {
        if (validators[validator].benign.voted[msg.sender]) {
            throw;
        }
        _;
    }

    modifier only_highest() {
        if (nominees[msg.sender].stake <= nominees[highestNominee].stake) {
            throw;
        }
        _;
    }

    modifier has_highest() {
        if (highestNominee != 0) {
            _;
        }
    }

    modifier is_highest(address nominee) {
        if (nominees[nominee].higherNominee == 0) {
            _;
        }
    }

    modifier is_misaligned(address nominee) {
        if (nominees[nominees[nominee].higherNominee].stake < nominees[nominee].stake) {
            _;
        }
    }

    modifier is_good_hint(address nominee, address hint) {
        if (nominees[hint].stake > nominees[nominee].stake) {
            throw;
        }
        _;
    }

    modifier empty_slot() {
        if (MAX_VALIDATORS > pendingList.length) {
            _;
        }
    }

    modifier is_validator(address validator) {
        if (nominees[validator].validator) {
            _;
        }
    }

    modifier is_not_validator(address validator) {
        if (!nominees[validator].validator) {
            _;
        }
    }

    modifier is_malicious_or_old(address validator) {
        if (validators[validator].malicious.votes > pendingList.length / 2
          || block.number > validators[validator].added + VALIDATOR_TERM) {
              _;
          }
    }

    modifier is_benign(address validator) {
        if (validators[validator].benign.votes > pendingList.length / 2) {
            _;
        }
    }

    modifier only_system_and_not_finalized() {
        if (msg.sender != SYSTEM_ADDRESS || finalized) { throw; }
        _;
    }

    modifier when_finalized() {
        if (!finalized) { throw; }
        _;
    }

    // Fallback function throws when called.
    function() {
        throw;
    }
}
