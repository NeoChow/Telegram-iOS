import Foundation
#if os(macOS)
import SwiftSignalKitMac
import PostboxMac
import TelegramApiMac
#else
import SwiftSignalKit
import Postbox
import TelegramApi
#endif


public enum ChannelOwnershipTransferError {
    case generic
    case twoStepAuthMissing
    case twoStepAuthTooFresh(Int32)
    case authSessionTooFresh(Int32)
    case limitExceeded
    case requestPassword
    case invalidPassword
    case adminsTooMuch
    case userPublicChannelsTooMuch
    case userLocatedGroupsTooMuch
    case restricted
    case userBlocked
}

public func checkOwnershipTranfserAvailability(postbox: Postbox, network: Network, accountStateManager: AccountStateManager, memberId: PeerId) -> Signal<Never, ChannelOwnershipTransferError> {
    return postbox.transaction { transaction -> Peer? in
        return transaction.getPeer(memberId)
        }
    |> introduceError(ChannelOwnershipTransferError.self)
    |> mapToSignal { user -> Signal<Never, ChannelOwnershipTransferError> in
        guard let user = user else {
            return .fail(.generic)
        }
        guard let apiUser = apiInputUser(user) else {
            return .fail(.generic)
        }
        
        return network.request(Api.functions.channels.editCreator(channel: .inputChannelEmpty, userId: apiUser, password: .inputCheckPasswordEmpty))
        |> mapError { error -> ChannelOwnershipTransferError in
            if error.errorDescription == "PASSWORD_HASH_INVALID" {
                return .requestPassword
            } else if error.errorDescription == "PASSWORD_MISSING" {
                return .twoStepAuthMissing
            } else if error.errorDescription.hasPrefix("PASSWORD_TOO_FRESH_") {
                let timeout = String(error.errorDescription[error.errorDescription.index(error.errorDescription.startIndex, offsetBy: "PASSWORD_TOO_FRESH_".count)...])
                if let value = Int32(timeout) {
                    return .twoStepAuthTooFresh(value)
                }
            } else if error.errorDescription.hasPrefix("SESSION_TOO_FRESH_") {
                let timeout = String(error.errorDescription[error.errorDescription.index(error.errorDescription.startIndex, offsetBy: "SESSION_TOO_FRESH_".count)...])
                if let value = Int32(timeout) {
                    return .authSessionTooFresh(value)
                }
            } else if error.errorDescription == "CHANNELS_ADMIN_PUBLIC_TOO_MUCH" {
                return .userPublicChannelsTooMuch
            } else if error.errorDescription == "CHANNELS_ADMIN_LOCATED_TOO_MUCH" {
                return .userLocatedGroupsTooMuch
            } else if error.errorDescription == "ADMINS_TOO_MUCH" {
                return .adminsTooMuch
            } else if error.errorDescription == "USER_PRIVACY_RESTRICTED" {
                return .restricted
            } else if error.errorDescription == "USER_BLOCKED" {
                return .userBlocked
            }
            return .generic
        }
        |> mapToSignal { updates -> Signal<Never, ChannelOwnershipTransferError> in
            accountStateManager.addUpdates(updates)
            return.complete()
        }
    }
}

public func updateChannelOwnership(account: Account, accountStateManager: AccountStateManager, channelId: PeerId, memberId: PeerId, password: String) -> Signal<[(ChannelParticipant?, RenderedChannelParticipant)], ChannelOwnershipTransferError> {
    guard !password.isEmpty else {
        return .fail(.invalidPassword)
    }
    
    return combineLatest(fetchChannelParticipant(account: account, peerId: channelId, participantId: account.peerId), fetchChannelParticipant(account: account, peerId: channelId, participantId: memberId))
    |> mapError { error -> ChannelOwnershipTransferError in
        return .generic
    }
    |> mapToSignal { currentCreator, currentParticipant -> Signal<[(ChannelParticipant?, RenderedChannelParticipant)], ChannelOwnershipTransferError> in
        return account.postbox.transaction { transaction -> Signal<[(ChannelParticipant?, RenderedChannelParticipant)], ChannelOwnershipTransferError> in
            if let channel = transaction.getPeer(channelId) as? TelegramChannel, let inputChannel = apiInputChannel(channel), let accountUser = transaction.getPeer(account.peerId), let user = transaction.getPeer(memberId), let inputUser = apiInputUser(user) {
                
                var flags: TelegramChatAdminRightsFlags
                if case .broadcast = channel.info {
                    flags = TelegramChatAdminRightsFlags.broadcastSpecific
                } else {
                    flags = TelegramChatAdminRightsFlags.groupSpecific
                }
                
                let updatedParticipant = ChannelParticipant.creator(id: user.id)
                let updatedPreviousCreator = ChannelParticipant.member(id: accountUser.id, invitedAt: Int32(Date().timeIntervalSince1970), adminInfo: ChannelParticipantAdminInfo(rights: TelegramChatAdminRights(flags: flags), promotedBy: accountUser.id, canBeEditedByAccountPeer: false), banInfo: nil)
                
                let checkPassword = twoStepAuthData(account.network)
                |> mapError { error -> ChannelOwnershipTransferError in
                    if error.errorDescription.hasPrefix("FLOOD_WAIT") {
                        return .limitExceeded
                    } else {
                        return .generic
                    }
                }
                |> mapToSignal { authData -> Signal<Api.InputCheckPasswordSRP, ChannelOwnershipTransferError> in
                    if let currentPasswordDerivation = authData.currentPasswordDerivation, let srpSessionData = authData.srpSessionData {
                        guard let kdfResult = passwordKDF(password: password, derivation: currentPasswordDerivation, srpSessionData: srpSessionData) else {
                            return .fail(.generic)
                        }
                        return .single(.inputCheckPasswordSRP(srpId: kdfResult.id, A: Buffer(data: kdfResult.A), M1: Buffer(data: kdfResult.M1)))
                    } else {
                        return .fail(.twoStepAuthMissing)
                    }
                }
                
                return checkPassword
                |> mapToSignal { password -> Signal<[(ChannelParticipant?, RenderedChannelParticipant)], ChannelOwnershipTransferError> in
                    return account.network.request(Api.functions.channels.editCreator(channel: inputChannel, userId: inputUser, password: password), automaticFloodWait: false)
                    |> mapError { error -> ChannelOwnershipTransferError in
                        if error.errorDescription.hasPrefix("FLOOD_WAIT") {
                            return .limitExceeded
                        } else if error.errorDescription == "PASSWORD_HASH_INVALID" {
                            return .invalidPassword
                        } else if error.errorDescription == "PASSWORD_MISSING" {
                            return .twoStepAuthMissing
                        } else if error.errorDescription.hasPrefix("PASSWORD_TOO_FRESH_") {
                            let timeout = String(error.errorDescription[error.errorDescription.index(error.errorDescription.startIndex, offsetBy: "PASSWORD_TOO_FRESH_".count)...])
                            if let value = Int32(timeout) {
                                return .twoStepAuthTooFresh(value)
                            }
                        } else if error.errorDescription.hasPrefix("SESSION_TOO_FRESH_") {
                            let timeout = String(error.errorDescription[error.errorDescription.index(error.errorDescription.startIndex, offsetBy: "SESSION_TOO_FRESH_".count)...])
                            if let value = Int32(timeout) {
                                return .authSessionTooFresh(value)
                            }
                        } else if error.errorDescription == "CHANNELS_ADMIN_PUBLIC_TOO_MUCH" {
                            return .userPublicChannelsTooMuch
                        } else if error.errorDescription == "CHANNELS_ADMIN_LOCATED_TOO_MUCH" {
                            return .userLocatedGroupsTooMuch
                        } else if error.errorDescription == "ADMINS_TOO_MUCH" {
                            return .adminsTooMuch
                        } else if error.errorDescription == "USER_PRIVACY_RESTRICTED" {
                            return .restricted
                        } else if error.errorDescription == "USER_BLOCKED" {
                            return .userBlocked
                        }
                        return .generic
                    }
                    |> mapToSignal { updates -> Signal<[(ChannelParticipant?, RenderedChannelParticipant)], ChannelOwnershipTransferError> in
                        accountStateManager.addUpdates(updates)
                        
                        return account.postbox.transaction { transaction -> [(ChannelParticipant?, RenderedChannelParticipant)] in
                            transaction.updatePeerCachedData(peerIds: Set([channelId]), update: { _, cachedData -> CachedPeerData? in
                                if let cachedData = cachedData as? CachedChannelData, let adminCount = cachedData.participantsSummary.adminCount {
                                    var updatedAdminCount = adminCount
                                    var wasAdmin = false
                                    if let currentParticipant = currentParticipant {
                                        switch currentParticipant {
                                            case .creator:
                                                wasAdmin = true
                                            case let .member(_, _, adminInfo, _):
                                                if let adminInfo = adminInfo, !adminInfo.rights.isEmpty {
                                                    wasAdmin = true
                                                }
                                        }
                                    }
                                    if !wasAdmin {
                                        updatedAdminCount = adminCount + 1
                                    }

                                    return cachedData.withUpdatedParticipantsSummary(cachedData.participantsSummary.withUpdatedAdminCount(updatedAdminCount))
                                } else {
                                    return cachedData
                                }
                            })
                            var peers: [PeerId: Peer] = [:]
                            var presences: [PeerId: PeerPresence] = [:]
                            peers[accountUser.id] = accountUser
                            if let presence = transaction.getPeerPresence(peerId: accountUser.id) {
                                presences[accountUser.id] = presence
                            }
                            peers[user.id] = user
                            if let presence = transaction.getPeerPresence(peerId: user.id) {
                                presences[user.id] = presence
                            }
                            return [(currentCreator, RenderedChannelParticipant(participant: updatedPreviousCreator, peer: accountUser, peers: peers, presences: presences)), (currentParticipant, RenderedChannelParticipant(participant: updatedParticipant, peer: user, peers: peers, presences: presences))]
                        }
                        |> mapError { _ -> ChannelOwnershipTransferError in return .generic }
                    }
                }
            } else {
                return .fail(.generic)
            }
        }
        |> mapError { _ -> ChannelOwnershipTransferError in return .generic }
        |> switchToLatest
    }
}
