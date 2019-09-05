#Errors lib.
import ../../../lib/Errors

#Hash lib.
import ../../../lib/Hash

#MinerWallet lib.
import ../../../Wallet/MinerWallet

#GlobalFunctionBox object.
import ../../../objects/GlobalFunctionBoxObj

#Consensus DB lib.
import ../../Filesystem/DB/ConsensusDB

#ConsensusIndex object.
import ../../common/objects/ConsensusIndexObj

#Transaction object.
import ../../Transactions/Transaction

#Element objects.
import ElementObj
import VerificationObj
import MeritRemovalObj

#TransactionStatus object.
import TransactionStatusObj
export TransactionStatusObj

#State lib.
import ../../Merit/State

#SpamFilter object.
import SpamFilterObj

#MeritHolder object.
import MeritHolderObj

#Tables standard lib.
import tables

#Finals lib.
import finals

#Consensus object.
type Consensus* = ref object
    #Global Functions.
    functions: GlobalFunctionBox
    #DB.
    db*: DB

    #Filters.
    filters*: tuple[send: SpamFilter, data: SpamFilter]

    #BLS Public Key -> MeritHolder.
    holders: Table[string, MeritHolder]
    #BLS Public Key -> MeritRemoval.
    malicious*: Table[string, seq[MeritRemoval]]

    #Statuses of Transactions not yet out of Epochs.
    statuses: Table[string, TransactionStatus]
    #Statuses which have been updated.
    updated: Table[string, bool]
    #Verifications of unknown Transactions.
    unknowns*: Table[string, seq[BLSPublicKey]]

#Consensus constructor.
proc newConsensusObj*(
    functions: GlobalFunctionBox,
    db: DB,
    sendDiff: Hash[384],
    dataDiff: Hash[384]
): Consensus {.forceCheck: [].} =
    #Create the Consensus object.
    result = Consensus(
        functions: functions,
        db: db,

        filters: (
            send: newSpamFilterObj(sendDiff),
            data: newSpamFilterObj(dataDiff)
        ),

        holders: initTable[string, MeritHolder](),
        malicious: initTable[string, seq[MeritRemoval]](),

        statuses: initTable[string, TransactionStatus](),
        updated: initTable[string, bool](),
        unknowns: initTable[string, seq[BLSPublicKey]]()
    )

    #Grab the MeritHolders, if any exist.
    var holders: seq[string]
    try:
        holders = result.db.loadHolders()
    #If none exist, return.
    except DBReadError:
        return

    #Load each MeritHolder.
    for holder in holders:
        try:
            result.holders[holder] = newMeritHolderObj(result.db, newBLSPublicKey(holder))
        except BLSError as e:
            doAssert(false, "Couldn't create a BLS Public Key for a known MeritHolder: " & e.msg)

#Creates a new MeritHolder on the Consensus.
proc add(
    consensus: Consensus,
    holder: BLSPublicKey
) {.forceCheck: [].} =
    #Create a string of the holder.
    var holderStr: string = holder.toString()

    #Make sure the holder doesn't already exist.
    if consensus.holders.hasKey(holderStr):
        return

    #Create a new MeritHolder.
    consensus.holders[holderStr] = newMeritHolderObj(consensus.db, holder)

    #Add the MeritHolder to the DB.
    try:
        consensus.db.save(holder, consensus.holders[holderStr].archived)
    except KeyError as e:
        doAssert(false, "Couldn't get a newly created MeritHolder's archived: " & e.msg)

#Gets a MeritHolder by their key.
proc `[]`*(
    consensus: Consensus,
    holder: BLSPublicKey
): var MeritHolder {.forceCheck: [].} =
    #Call add, which will only create a new MeritHolder if one doesn't exist.
    consensus.add(holder)

    #Return the holder.
    try:
        result = consensus.holders[holder.toString()]
    except KeyError as e:
        doAssert(false, "Couldn't grab a MeritHolder despite just calling `add` for that MeritHolder: " & e.msg)

#Set a Transaction's status.
proc setStatus*(
    consensus: Consensus,
    hash: Hash[384],
    status: TransactionStatus
) {.forceCheck: [].} =
    consensus.statuses[hash.toString()] = status
    consensus.updated[hash.toString()] = true

#Get a Transaction's statuses.
proc getStatus*(
    consensus: Consensus,
    hash: Hash[384]
): TransactionStatus {.forceCheck: [
    IndexError
].} =
    if consensus.statuses.hasKey(hash.toString()):
        try:
            return consensus.statuses[hash.toString()]
        except KeyError as e:
            doAssert(false, "Couldn't get a Status from the cache when the cache has the key: " & e.msg)

    try:
        result = consensus.db.load(hash)
    except DBReadError:
        raise newException(IndexError, "Transaction doesn't have a status.")

    #Add the Transaction to the cache if it's not yet out of Epochs.
    if result.merit == -1:
        consensus.statuses[hash.toString()] = result

#Calculate a Transaction's Merit.
proc calculateMeritSingle(
    consensus: Consensus,
    state: var State,
    tx: Transaction,
    status: TransactionStatus
) {.forceCheck: [].} =
    #If the Transaction is already verified, or it needs to default, return.
    if status.verified or status.defaulting:
        return

    #Calculate Merit.
    var merit: int = 0
    for verifier in status.verifiers:
        #Skip malicious MeritHolders from Merit calculations.
        if not consensus.malicious.hasKey(verifier.toString()):
            merit += state[verifier]

    #Check if the Transaction crossed its threshold.
    if merit >= state.nodeThresholdAt(status.epoch):
        #Make sure all parents are verified.
        try:
            for input in tx.inputs:
                if (tx of Data) and (cast[Data](tx).isFirstData):
                    break

                if (
                    (not (consensus.functions.transactions.getTransaction(input.hash) of Mint)) and
                    (not consensus.getStatus(input.hash).verified)
                ):
                    return
        except IndexError as e:
            doAssert(false, "Couldn't get the Status of a Transaction that was the parent to this Transaction: " & e.msg)

        #Mark the Transaction as verified.
        status.verified = true
        consensus.functions.transactions.verify(tx.hash)

#Calculate a Transaction's Merit. If it's verified, also check every descendant
proc calculateMerit*(
    consensus: Consensus,
    state: var State,
    hash: Hash[384],
    statusArg: TransactionStatus
) {.forceCheck: [].} =
    var
        children: seq[Hash[384]] = @[hash]
        child: Hash[384]
        tx: Transaction
        status: TransactionStatus = statusArg
        wasVerified: bool

    while children.len != 0:
        child = children.pop()
        try:
            tx = consensus.functions.transactions.getTransaction(child)
            if child != hash:
                status = consensus.getStatus(child)
        except IndexError as e:
            echo e.msg
            doAssert(false, "Couldn't get the Transaction/Status for a Transaction we're calculating the Merit of.")
        wasVerified = status.verified

        consensus.calculateMeritSingle(
            state,
            tx,
            status
        )

        if (not wasVerified) and (status.verified):
            try:
                for o in 0 ..< tx.outputs.len:
                    var spenders: seq[Hash[384]] = consensus.functions.transactions.getSpenders(newSendInput(child, o))
                    for spender in spenders:
                        children.add(spender)
            except IndexError as e:
                doAssert(false, "Couldn't get a child Transaction/child Transaction's Status we've marked as a spender of this Transaction: " & e.msg)

#Update a Status with a new verifier.
proc update*(
    consensus: Consensus,
    state: var State,
    hash: Hash[384],
    verifier: BLSPublicKey
) {.forceCheck: [].} =
    #Grab the status.
    var status: TransactionStatus
    try:
        status = consensus.getStatus(hash)
    except IndexError:
        doAssert(false, "Transaction was either not registered.")

    #Don't change the status of finalized Transactions.
    if status.merit != -1:
        return

    #Make sure this isn't a duplicate.
    for existing in status.verifiers:
        if existing == verifier:
            return

    #Add the Verifier.
    status.verifiers.add(verifier)

    #Calculate Merit.
    consensus.calculateMerit(state, hash, status)

    #Mark the Status as updated.
    consensus.updated[hash.toString()] = true

#Finalize a TransactionStatus.
proc finalize*(
    consensus: Consensus,
    state: var State,
    hash: Hash[384]
) {.forceCheck: [].} =
    #Get the Status.
    var status: TransactionStatus
    try:
        status = consensus.getStatus(hash)
    except IndexError as e:
        doAssert(false, "Couldn't get the Status of a Transaction we're finalizing: " & e.msg)

    #Calculate the final Merit tally.
    var merit: int = 0
    for verifier in status.verifiers:
        #Ignore Verifiers who didn't get their Verifications archived.
        var skip: bool = false
        try:
            for e in consensus[verifier].archived + 1 ..< consensus[verifier].height:
                if consensus[verifier][e] of Verification:
                    if cast[Verification](consensus[verifier][e]).hash == hash:
                        skip = true
                        break
        except IndexError as e:
            doAssert(false, "Couldn't get an Element despite iterating from .archived + 1 ..< .height: " & e.msg)
        if skip:
            continue

        #Add the Merit.
        merit += state[verifier]

    #Make sure the Merit is above the node protocol threshold.
    if (status.verified) and (merit < state.protocolThresholdAt(state.processedBlocks)):
        doAssert(false, "Verified Transaction was finalized as unverified.")
    elif (not status.verified) and (merit >= state.protocolThresholdAt(state.processedBlocks)):
        status.verified = true

    #Save the Status.
    consensus.db.save(hash.toString(), status)

    #Remove it from the cache.
    consensus.statuses.del(hash.toString())
    consensus.updated.del(hash.toString())

#Save updated statuses.
proc saveStatuses*(
    consensus: Consensus
) {.forceCheck: [].} =
    try:
        for hash in consensus.updated.keys():
            consensus.db.save(hash, consensus.statuses[hash])
    except KeyError as e:
        doAssert(false, "Couldn't get a TransactionStatus by a key from .keys(): " & e.msg)
    consensus.updated = initTable[string, bool]()

#Gets a Element by its Index.
proc `[]`*(
    consensus: Consensus,
    index: ConsensusIndex
): Element {.forceCheck: [
    IndexError
].} =
    #Check the nonce isn't out of bounds.
    if consensus[index.key].height <= index.nonce:
        raise newException(IndexError, "MeritHolder doesn't have an Element for that nonce.")

    try:
        result = consensus.holders[index.key.toString()][index.nonce]
    except KeyError as e:
        doAssert(false, "Couldn't grab a MeritHolder despite just calling `add` for that MeritHolder: " & e.msg)
    except IndexError as e:
        fcRaise e

#Iterate over every MeritHolder.
iterator holders*(
    consensus: Consensus
): BLSPublicKey {.forceCheck: [].} =
    for holder in consensus.holders.keys():
        try:
            yield consensus.holders[holder].key
        except KeyError as e:
            doAssert(false, "Couldn't grab a MeritHolder despite only asking for it because of the keys iterator: " & e.msg)

#Iterate over every status.
iterator statuses*(
    consensus: Consensus
): string {.forceCheck: [].} =
    for status in consensus.statuses.keys():
        yield status
