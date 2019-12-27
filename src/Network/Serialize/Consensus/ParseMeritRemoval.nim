#Errors lib.
import ../../../lib/Errors

#MinerWallet lib.
import ../../../Wallet/MinerWallet

#MeritRemoval object.
import ../../../Database/Consensus/Elements/objects/MeritRemovalObj

#Serialize/Deserialize functions.
import ../SerializeCommon

#Parse Element libs.
import ParseElement
import ParseVerification
import ParseVerificationPacket

#Parse an Element in a MeritRemoval.
proc parseMeritRemovalElement(
    data: string,
    i: int,
    holder: string = ""
): tuple[
    element: Element,
    len: int
] {.forceCheck: [
    ValueError
].} =
    try:
        result.len = 0
        if int(data[i]) == VERIFICATION_PACKET_PREFIX:
            result.len = {
                int8(VERIFICATION_PACKET_PREFIX)
            }.getLength(data[i])

        result.len += MERIT_REMOVAL_ELEMENT_SET.getLength(
            data[i],
            data[i + 1 .. i + result.len].fromBinary(),
            MERIT_REMOVAL_PREFIX
        )
    except ValueError as e:
        raise e

    inc(result.len)
    if i + result.len > data.len:
        raise newException(ValueError, "parseMeritRemovalElement not handed enough data to parse the next Element.")

    try:
        case int(data[i]):
            of VERIFICATION_PREFIX:
                result.element = parseVerification(holder & data[i + 1 ..< i + result.len])
            of VERIFICATION_PACKET_PREFIX:
                result.element = parseMeritRemovalVerificationPacket(data[i + 1 ..< i + result.len])
            of SEND_DIFFICULTY_PREFIX:
                doAssert(false, "SendDifficulties are not supported.")
            of DATA_DIFFICULTY_PREFIX:
                doAssert(false, "DataDifficulties are not supported.")
            of GAS_PRICE_PREFIX:
                doAssert(false, "GasPrices are not supported.")
            else:
                doAssert(false, "Possible Element wasn't supported.")
    except ValueError as e:
        raise e

#Parse a MeritRemoval.
proc parseMeritRemoval*(
    mrStr: string
): MeritRemoval {.forceCheck: [
    ValueError
].} =
    #Holder's Nickname | Partial | Element Prefix | Serialized Element without Holder | Element Prefix | Serialized Element without Holder
    var
        mrSeq: seq[string] = mrStr.deserialize(
            NICKNAME_LEN,
            BYTE_LEN
        )
        partial: bool

        pmreResult: tuple[
            element: Element,
            len: int
        ]
        i: int = NICKNAME_LEN + BYTE_LEN

        element1: Element
        element2: Element

    if mrSeq[1].len != 1:
        raise newException(ValueError, "MeritRemoval not handed enough data to get if it's partial.")
    case int(mrSeq[1][0]):
        of 0:
            partial = false
        of 1:
            partial = true
        else:
            raise newException(ValueError, "MeritRemoval has an invalid partial field.")

    try:
        pmreResult = mrStr.parseMeritRemovalElement(i, mrSeq[0])
        i += pmreResult.len
        element1 = pmreResult.element
    except ValueError as e:
        raise e

    try:
        pmreResult = mrStr.parseMeritRemovalElement(i, mrSeq[0])
        element2 = pmreResult.element
    except ValueError as e:
        raise e

    #Create the MeritRemoval.
    result = newMeritRemovalObj(
        uint16(mrSeq[0].fromBinary()),
        partial,
        element1,
        element2
    )

#Parse a Signed MeritRemoval.
proc parseSignedMeritRemoval*(
    mrStr: string
): SignedMeritRemoval {.forceCheck: [
    ValueError
].} =
    #Holder's Nickname | Partial | Element Prefix | Serialized Element without Holder | Element Prefix | Serialized Element without Holder
    var
        mrSeq: seq[string] = mrStr.deserialize(
            NICKNAME_LEN,
            BYTE_LEN
        )
        partial: bool

        i: int = NICKNAME_LEN + BYTE_LEN
        pmreResult: tuple[
            element: Element,
            len: int
        ]

        element1: Element
        element2: Element

    if mrSeq[1].len != 1:
        raise newException(ValueError, "MeritRemoval not handed enough data to get if it's partial.")
    case int(mrSeq[1][0]):
        of 0:
            partial = false
        of 1:
            partial = true
        else:
            raise newException(ValueError, "MeritRemoval has an invalid partial field.")

    try:
        pmreResult = mrStr.parseMeritRemovalElement(i, mrSeq[0])
        i += pmreResult.len
        element1 = pmreResult.element
    except ValueError as e:
        raise e

    try:
        pmreResult = mrStr.parseMeritRemovalElement(i, mrSeq[0])
        element2 = pmreResult.element
    except ValueError as e:
        raise e

    #Create the SignedMeritRemoval.
    try:
        result = newSignedMeritRemovalObj(
            uint16(mrSeq[0].fromBinary()),
            partial,
            element1,
            element2,
            newBLSSignature(mrStr[mrStr.len - BLS_SIGNATURE_LEN ..< mrStr.len])
        )
    except BLSError:
        raise newException(ValueError, "Invalid Signature.")
