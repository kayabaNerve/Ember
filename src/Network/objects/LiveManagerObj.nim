#Errors lib.
import ../../lib/Errors

#Util lib.
import ../../lib/Util

#Hash lib.
import ../../lib/Hash

#BlockHeader object.
import ../../Database/Merit/objects/BlockHeaderObj

#Elements lib.
import ../../Database/Consensus/Elements/Elements

#Transaction lib.
import ../../Database/Transactions/Transaction

#GlobalFunctionBox object.
import ../../objects/GlobalFunctionBoxObj

#Message object.
import MessageObj

#Peer lib.
import ../Peer

#SerializeCommon lib.
import ../Serialize/SerializeCommon

#Parse libs.
import ../Serialize/Merit/ParseBlockHeader

import ../Serialize/Consensus/ParseVerification
import ../Serialize/Consensus/ParseSendDifficulty
import ../Serialize/Consensus/ParseDataDifficulty
import ../Serialize/Consensus/ParseMeritRemoval

import ../Serialize/Transactions/ParseClaim
import ../Serialize/Transactions/ParseSend
import ../Serialize/Transactions/ParseData

#Async standard lib.
import asyncdispatch

#LiveManager object.
type LiveManager* = ref object
    #Network ID.
    network*: int
    #Protocol version.
    protocol*: int
    #Services byte.
    services*: char
    #Server port.
    port*: int

    #Global Function Box.
    functions*: GlobalFunctionBox

#Constructor.
func newLiveManager*(
    network: int,
    protocol: int,
    port: int,
    functions: GlobalFunctionBox
): LiveManager {.forceCheck: [].} =
    LiveManager(
        network: network,
        protocol: protocol,
        port: port,
        functions: functions
    )

#Update the services byte.
func updateServices*(
    manager: LiveManager,
    service: uint8
) {.forceCheck: [].} =
    manager.services = char(uint8(manager.services) and service)

#Handle a new connection.
proc handle*(
    manager: LiveManager,
    peer: Peer
) {.forceCheck: [], async.} =
    #Send our Handshake and get their Handshake.
    var msg: Message
    try:
        await peer.sendLive(newMessage(
            MessageType.Handshake,
            char(manager.protocol) &
            char(manager.network) &
            manager.services &
            manager.port.toBinary(PORT_LEN) &
            manager.functions.merit.getTail().toString()
        ))
        msg = await peer.recvLive()
    except PeerError:
        peer.close()
        return
    except Exception as e:
        doAssert(false, "Handshaking threw an Exception despite catching all thrown Exceptions: " & e.msg)

    if msg.content != MessageType.Handshake:
        peer.close()
        return

    if int(msg.message[0]) != manager.protocol:
        peer.close()
        return

    if int(msg.message[1]) != manager.network:
        peer.close()
        return

    if (uint8(msg.message[2]) and SERVER_SERVICE) == SERVER_SERVICE:
        peer.server = true

    peer.port = msg.message[3 ..< 5].fromBinary()

    var tail: Hash[256]
    try:
        tail = msg.message[5 ..< 37].toHash(256)
    except ValueError as e:
        doAssert(false, "Couldn't create a 32-byte hash from a 32-byte value: " & e.msg)

    #Add the tail.
    try:
        await manager.functions.merit.addBlockByHash(tail, true)
    except ValueError, DataMissing:
        peer.close()
        return
    except DataExists, NotConnected:
        discard
    except Exception as e:
        doAssert(false, "Adding a Block threw an Exception despite catching all thrown Exceptions: " & e.msg)

    #Receive and handle messages forever.
    while true:
        try:
            msg = await peer.recvLive()
        except PeerError:
            peer.close()
            return
        except Exception as e:
            doAssert(false, "Receiving a new message threw an Exception despite catching all thrown Exceptions: " & e.msg)

        try:
            case msg.content:
                of MessageType.Handshake:
                    try:
                        await peer.sendLive(
                            newMessage(
                                MessageType.BlockchainTail,
                                manager.functions.merit.getTail().toString()
                            )
                        )
                    except Exception as e:
                        doAssert(false, "Replying `BlockchainTail` in response to a keep-alive `Handshake` threw an Exception despite catching all thrown Exceptions: " & e.msg)

                    #Add the tail.
                    try:
                        await manager.functions.merit.addBlockByHash(tail, true)
                    except ValueError, DataMissing:
                        peer.close()
                        return
                    except DataExists, NotConnected:
                        discard
                    except Exception as e:
                        doAssert(false, "Adding a Block threw an Exception despite catching all thrown Exceptions: " & e.msg)

                of MessageType.BlockchainTail:
                    #Get the hash.
                    var tail: Hash[256]
                    try:
                        tail = msg.message[0 ..< 32].toHash(256)
                    except ValueError as e:
                        doAssert(false, "Couldn't turn a 32-byte string into a 32-byte hash: " & e.msg)

                    #Add the Block.
                    try:
                        await manager.functions.merit.addBlockByHash(tail, true)
                    except ValueError, DataMissing:
                        peer.close()
                        return
                    except DataExists, NotConnected:
                        discard
                    except Exception as e:
                        doAssert(false, "Adding a Block threw an Exception despite catching all thrown Exceptions: " & e.msg)

                of MessageType.Claim:
                    var claim: Claim = msg.message.parseClaim()
                    manager.functions.transactions.addClaim(claim)

                of MessageType.Send:
                    var send: Send = msg.message.parseSend(manager.functions.consensus.getSendDifficulty())
                    manager.functions.transactions.addSend(send)

                of MessageType.Data:
                    var data: Data = msg.message.parseData(manager.functions.consensus.getDataDifficulty())
                    manager.functions.transactions.addData(data)

                of MessageType.SignedVerification:
                    var verif: SignedVerification = msg.message.parseSignedVerification()
                    manager.functions.consensus.addSignedVerification(verif)

                of MessageType.SignedSendDifficulty:
                    var sendDiff: SignedSendDifficulty = msg.message.parseSignedSendDifficulty()
                    manager.functions.consensus.addSignedSendDifficulty(sendDiff)

                of MessageType.SignedDataDifficulty:
                    var dataDiff: SignedDataDifficulty = msg.message.parseSignedDataDifficulty()
                    manager.functions.consensus.addSignedDataDifficulty(dataDiff)

                of MessageType.SignedMeritRemoval:
                    var mr: SignedMeritRemoval = msg.message.parseSignedMeritRemoval()

                    try:
                        await manager.functions.consensus.addSignedMeritRemoval(mr)
                    except ValueError:
                        peer.close()
                        return
                    except DataExists:
                        continue
                    except Exception as e:
                        doAssert(false, "Adding a SignedMeritRemoval threw an Exception despite catching all thrown Exceptions: " & e.msg)

                of MessageType.BlockHeader:
                    var header: BlockHeader = msg.message.parseBlockHeader()

                    try:
                        await manager.functions.merit.addBlockByHeader(header, false)
                    except ValueError, DataMissing:
                        peer.close()
                        return
                    except DataExists, NotConnected:
                        continue
                    except Exception as e:
                        doAssert(false, "Adding a Block threw an Exception despite catching all thrown Exceptions: " & e.msg)

                else:
                    peer.close()
                    return
        except ValueError, DataMissing:
            peer.close()
            return
        except Spam, DataExists, NotConnected:
            continue
