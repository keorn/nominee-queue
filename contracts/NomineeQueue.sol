pragma solidity ^0.4.6;

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
// Engine ensures each validator receives 
contract NomineeQueue {
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
    }

	uint nominationDivisor = 1000; // minimalNomination = totalStake/nominationDivisor
	mapping(address => NomineeStatus) nominees; // Status of the nominees.
	address highestNominee; // Nominee with the most stake behind him that is keen to be a validator.
	uint totalStake = 2 ether; // Total number of tokens held as validator stake.
	uint validatorCount = 3; // Number of validator slots.
	uint validatorTerm = 100; // Number of blocks after which the validator can be removed.
	// Accounts used for testing: "0".sha3() and "1".sha3(), they are staking one Ether each
    address[] public validatorList;
    mapping(address => ValidatorStatus) validators;
    uint slashingDivisor = 20; // Proportion of stake removed on benign misbehaviour.
    uint totalSupply = 0;

    uint initialStake = 1 ether;
    function NomineeQueue() {
        validatorList.push(0x7d577a597b2742b498cb5cf0c26cdcd726d39e6e);

        for (uint i = 0; i < validatorList.length; i++) {
            address validator = validatorList[i];
            nominees[validator] = NomineeStatus({
                stake: initialStake,
                inputStake: initialStake,
                validator: true
            });
            nominees[validator].nominators[validator] = initialStake;
            validators[validator] = ValidatorStatus({
                index: i,
                added: block.number,
                benign: ReportTracker(0),
                malicious: ReportTracker(0)
            });
        }
    }

    // Called on every block to update node validator list.
    function getValidators() constant returns (address[]) {
        return validatorList;
    }

    // Commit stake to a given address.
    function nominate(address nominee) payable minimumStake(nominee) {
        nominees[nominee].stake += msg.value;
        nominees[nominee].inputStake += msg.value;
        nominees[nominee].nominators[msg.sender] += msg.value;
        totalSupply -= msg.value;
    }

    function nomineeStake(address nominee) constant returns(uint) {
        return nominees[nominee].stake;
    }

    // Remove stake if its not validating.
    function withdraw(address nominee) isNotValidator(nominee) {
        uint stake = nominees[nominee].nominators[msg.sender];
        nominees[nominee].nominators[msg.sender] = 0;
        nominees[nominee].stake -= stake;
        uint allowance = stake * nominees[nominee].stake / nominees[nominee].inputStake;
        totalSupply += allowance;
        if (msg.sender.send(allowance)) return;
    }

    // Called by nominee when he thinks he has the most stake and is keen to become a validator.
    function claimHighest() onlyHighest {
        highestNominee = msg.sender;
        addValidator();
    }

    // Claim highest and kick old in one tx.
    function replaceOld(address old) {
        claimHighest();
        kickOldValidator(old);
    }

    function addValidator() private emptySlot hasHighest {
        validators[highestNominee].index = validatorList.length;
        validatorList.push(highestNominee);
        totalStake += nominees[highestNominee].stake;
        validators[highestNominee].added = block.number;
        highestNominee = 0;
    }

    function kickOldValidator(address validator) {
        removeValidator(validator);
        addValidator();
    }

    // Called when a validator is bad.
    function reportMalicious(address validator) onlyValidator notReportedMalicious(validator) {
        validators[validator].malicious.votes++;
        validators[validator].malicious.voted[msg.sender] = true;
        removeValidator(validator);
        addValidator();
    }

    // Called on benign validator misbehaviour.
    function reportBenign(address validator) onlyValidator {
        validators[validator].benign.votes++;
        validators[validator].benign.voted[msg.sender] = true;
        slash(validator);
    }

    function slash(address validator) isBenign(validator) {
        uint toSlash = nominees[validator].stake / slashingDivisor;
        nominees[validator].stake -= toSlash;
        totalStake -= toSlash;
    }

    // Remove a validator without enough support.
    function removeValidator(address validator) private  isMaliciousOrOld(validator) {
        totalStake -= nominees[validator].stake;
        uint removedIndex = validators[validator].index;
        uint lastIndex = validatorList.length-1;
        address lastValidator = validatorList[lastIndex];
        // Override the removed validator with the last one.
        validatorList[removedIndex] = lastValidator;
        // Update the index of the last validator.
        validators[lastValidator].index = removedIndex;
        delete validatorList[lastIndex];
        validatorList.length--;
        validators[validator].index = 0;
    }

    // Called to receive rewards for a given validator.
    function claimRewards(address validator) isValidator(validator) {
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
        return totalTokens * saturatingSub(60, stakePercentage) / (stakePercentage**2*100+10000);
    }

    modifier minimumStake(address nominee) {
        if (nominees[nominee].stake + msg.value < totalStake / nominationDivisor) throw; _;
    }

    modifier onlyValidator() {
        if (!nominees[msg.sender].validator) throw; _;
    }

    modifier notReportedMalicious(address validator) {
        if (validators[validator].malicious.voted[msg.sender]) throw; _;
    }

    modifier notReportedBenign(address validator) {
        if (validators[validator].benign.voted[msg.sender]) throw; _;
    }

    modifier onlyHighest() {
        if (nominees[msg.sender].stake <= nominees[highestNominee].stake) throw; _;
    }

    modifier hasHighest() {
        if (highestNominee != 0) _;
    }

    modifier emptySlot() {
        if (validatorCount > validatorList.length) _;
    }

    modifier isValidator(address validator) {
        if (nominees[validator].validator) _;
    }

    modifier isNotValidator(address validator) {
        if (!nominees[validator].validator) _;
    }

    modifier isMaliciousOrOld(address validator) {
        if (validators[validator].malicious.votes > validatorList.length / 2
          || block.number > validators[validator].added + validatorTerm) _;
    }

    modifier isBenign(address validator) {
        if (validators[validator].benign.votes > validatorList.length / 2) _;
    }
}
