import Foundation

struct PeerIdAndNamespace: Hashable {
    let peerId: PeerId
    let namespace: MessageId.Namespace
}

private func canContainHoles(_ peerIdAndNamespace: PeerIdAndNamespace, seedConfiguration: SeedConfiguration) -> Bool {
    guard let messageNamespaces = seedConfiguration.messageHoles[peerIdAndNamespace.peerId.namespace] else {
        return false
    }
    return messageNamespaces[peerIdAndNamespace.namespace] != nil
}

private struct MessageMonthIndex: Equatable {
    let year: Int32
    let month: Int32
    
    var timestamp: Int32 {
        var timeinfo = tm()
        timeinfo.tm_year = self.year
        timeinfo.tm_mon = self.month
        return Int32(timegm(&timeinfo))
    }
    
    init(year: Int32, month: Int32) {
        self.year = year
        self.month = month
    }
    
    init(timestamp: Int32) {
        var t = Int(timestamp)
        var timeinfo = tm()
        gmtime_r(&t, &timeinfo)
        self.year = timeinfo.tm_year
        self.month = timeinfo.tm_mon
    }
    
    var successor: MessageMonthIndex {
        if self.month == 11 {
            return MessageMonthIndex(year: self.year + 1, month: 0)
        } else {
            return MessageMonthIndex(year: self.year, month: self.month + 1)
        }
    }
    
    var predecessor: MessageMonthIndex {
        if self.month == 0 {
            return MessageMonthIndex(year: self.year - 1, month: 11)
        } else {
            return MessageMonthIndex(year: self.year, month: self.month - 1)
        }
    }
}

private func monthUpperBoundIndex(peerId: PeerId, namespace: MessageId.Namespace, index: MessageMonthIndex) -> MessageIndex {
    return MessageIndex(id: MessageId(peerId: peerId, namespace: namespace, id: 0), timestamp: index.successor.timestamp)
}

enum HistoryViewAnchor {
    case upperBound
    case lowerBound
    case index(MessageIndex)
    
    func isLower(than otherIndex: MessageIndex) -> Bool {
        switch self {
            case .upperBound:
                return false
            case .lowerBound:
                return true
            case let .index(index):
                return index < otherIndex
        }
    }
    
    func isEqualOrLower(than otherIndex: MessageIndex) -> Bool {
        switch self {
            case .upperBound:
                return false
            case .lowerBound:
                return true
            case let .index(index):
                return index <= otherIndex
        }
    }
    
    func isGreater(than otherIndex: MessageIndex) -> Bool {
        switch self {
            case .upperBound:
                return true
            case .lowerBound:
                return false
            case let .index(index):
                return index > otherIndex
        }
    }
    
    func isEqualOrGreater(than otherIndex: MessageIndex) -> Bool {
        switch self {
            case .upperBound:
                return true
            case .lowerBound:
                return false
            case let .index(index):
                return index >= otherIndex
        }
    }
}

private func binaryInsertionIndex(_ inputArr: [MutableMessageHistoryEntry], searchItem: HistoryViewAnchor) -> Int {
    var lo = 0
    var hi = inputArr.count - 1
    while lo <= hi {
        let mid = (lo + hi) / 2
        let value = inputArr[mid]
        if searchItem.isGreater(than: value.index) {
            lo = mid + 1
        } else if searchItem.isLower(than: value.index) {
            hi = mid - 1
        } else {
            return mid
        }
    }
    return lo
}

func binaryIndexOrLower(_ inputArr: [MessageHistoryEntry], _ searchItem: HistoryViewAnchor) -> Int {
    var lo = 0
    var hi = inputArr.count - 1
    while lo <= hi {
        let mid = (lo + hi) / 2
        if searchItem.isGreater(than: inputArr[mid].index) {
            lo = mid + 1
        } else if searchItem.isLower(than: inputArr[mid].index) {
            hi = mid - 1
        } else {
            return mid
        }
    }
    return hi
}

func binaryIndexOrLower(_ inputArr: [MessageHistoryMessageEntry], _ searchItem: HistoryViewAnchor) -> Int {
    var lo = 0
    var hi = inputArr.count - 1
    while lo <= hi {
        let mid = (lo + hi) / 2
        if searchItem.isGreater(than: inputArr[mid].message.index) {
            lo = mid + 1
        } else if searchItem.isLower(than: inputArr[mid].message.index) {
            hi = mid - 1
        } else {
            return mid
        }
    }
    return hi
}

private func binaryIndexOrLower(_ inputArr: [MutableMessageHistoryEntry], _ searchItem: HistoryViewAnchor) -> Int {
    var lo = 0
    var hi = inputArr.count - 1
    while lo <= hi {
        let mid = (lo + hi) / 2
        if searchItem.isGreater(than: inputArr[mid].index) {
            lo = mid + 1
        } else if searchItem.isLower(than: inputArr[mid].index) {
            hi = mid - 1
        } else {
            return mid
        }
    }
    return hi
}

private func sampleEntries(orderedEntriesBySpace: [PeerIdAndNamespace: OrderedHistoryViewEntries], anchor: HistoryViewAnchor, halfLimit: Int) -> (lowerOrAtAnchor:[(PeerIdAndNamespace, Int)], higherThanAnchor: [(PeerIdAndNamespace, Int)]) {
    var previousAnchorIndices: [PeerIdAndNamespace: Int] = [:]
    var nextAnchorIndices: [PeerIdAndNamespace: Int] = [:]
    for (space, items) in orderedEntriesBySpace {
        previousAnchorIndices[space] = items.lowerOrAtAnchor.count - 1
        nextAnchorIndices[space] = 0
    }
    
    var backwardsResult: [(PeerIdAndNamespace, Int)] = []
    var result: [(PeerIdAndNamespace, Int)] = []
    
    while true {
        var minSpace: PeerIdAndNamespace?
        for (space, value) in previousAnchorIndices {
            if value != -1 {
                if let minSpaceValue = minSpace {
                    if orderedEntriesBySpace[space]!.lowerOrAtAnchor[value].index > orderedEntriesBySpace[minSpaceValue]!.lowerOrAtAnchor[previousAnchorIndices[minSpaceValue]!].index {
                        minSpace = space
                    }
                } else {
                    minSpace = space
                }
            }
        }
        if let minSpace = minSpace {
            backwardsResult.append((minSpace, previousAnchorIndices[minSpace]!))
            previousAnchorIndices[minSpace]! -= 1
            if backwardsResult.count == halfLimit {
                break
            }
        }
        
        if minSpace == nil {
            break
        }
    }
    
    while true {
        var maxSpace: PeerIdAndNamespace?
        for (space, value) in nextAnchorIndices {
            if value != orderedEntriesBySpace[space]!.higherThanAnchor.count {
                if let maxSpaceValue = maxSpace {
                    if orderedEntriesBySpace[space]!.higherThanAnchor[value].index < orderedEntriesBySpace[maxSpaceValue]!.higherThanAnchor[nextAnchorIndices[maxSpaceValue]!].index {
                        maxSpace = space
                    }
                } else {
                    maxSpace = space
                }
            }
        }
        if let maxSpace = maxSpace {
            result.append((maxSpace, nextAnchorIndices[maxSpace]!))
            nextAnchorIndices[maxSpace]! += 1
            if result.count == halfLimit {
                break
            }
        }
        
        if maxSpace == nil {
            break
        }
    }
    return (backwardsResult.reversed(), result)
}

struct SampledHistoryViewHole: Equatable {
    let peerId: PeerId
    let namespace: MessageId.Namespace
    let tag: MessageTags?
    let indices: IndexSet
    let startId: MessageId.Id
    let endId: MessageId.Id?
}

private func isIndex(index: MessageIndex, closerTo anchor: HistoryViewAnchor, than other: MessageIndex) -> Bool {
    if index.timestamp != other.timestamp {
        let anchorTimestamp: Int32
        switch anchor {
            case .lowerBound:
                anchorTimestamp = 0
            case .upperBound:
                anchorTimestamp = Int32.max
            case let .index(index):
                anchorTimestamp = index.timestamp
        }
        if abs(anchorTimestamp - index.timestamp) < abs(anchorTimestamp - other.timestamp) {
            return true
        } else {
            return false
        }
    } else if index.id.peerId == other.id.peerId {
        if index.id.namespace == other.id.namespace {
            let anchorId: Int32
            switch anchor {
                case .lowerBound:
                    anchorId = 0
                case .upperBound:
                    anchorId = Int32.max
                case let .index(index):
                    anchorId = index.id.id
            }
            if abs(anchorId - index.id.id) < abs(anchorId - other.id.id) {
                return true
            } else {
                return false
            }
        } else {
            return index.id.namespace < other.id.namespace
        }
    } else {
        return index.id.peerId.toInt64() < other.id.peerId.toInt64()
    }
}

private func sampleHoleRanges(orderedEntriesBySpace: [PeerIdAndNamespace: OrderedHistoryViewEntries], holes: HistoryViewHoles, anchor: HistoryViewAnchor, tag: MessageTags?, halfLimit: Int, seedConfiguration: SeedConfiguration) -> (clipRanges: [ClosedRange<MessageIndex>], sampledHole: SampledHistoryViewHole?) {
    var clipRanges: [ClosedRange<MessageIndex>] = []
    var sampledHole: (distanceFromAnchor: Int?, hole: SampledHistoryViewHole)?
    
    for (space, indices) in holes.holesBySpace {
        if indices.isEmpty {
            continue
        }
        assert(canContainHoles(space, seedConfiguration: seedConfiguration))
        switch anchor {
            case .lowerBound, .upperBound:
                break
            case let .index(index):
                if index.id.peerId == space.peerId && index.id.namespace == space.namespace {
                    if indices.contains(Int(index.id.id)) {
                        return ([MessageIndex.absoluteLowerBound() ... MessageIndex.absoluteUpperBound()], SampledHistoryViewHole(peerId: space.peerId, namespace: space.namespace, tag: tag, indices: indices, startId: index.id.id, endId: nil))
                    }
                }
        }
        guard let items = orderedEntriesBySpace[space], (!items.lowerOrAtAnchor.isEmpty || !items.higherThanAnchor.isEmpty) else {
            let holeBounds: (startId: MessageId.Id, endId: MessageId.Id)
            switch anchor {
                case .lowerBound:
                    holeBounds = (1, Int32.max - 1)
                case .upperBound, .index:
                    holeBounds = (Int32.max - 1, 1)
            }
            if case let .index(index) = anchor, index.id.peerId == space.peerId {
                return ([MessageIndex.absoluteLowerBound() ... MessageIndex.absoluteUpperBound()], SampledHistoryViewHole(peerId: space.peerId, namespace: space.namespace, tag: tag, indices: indices, startId: holeBounds.startId, endId: holeBounds.endId))
            } else {
                sampledHole = (nil, SampledHistoryViewHole(peerId: space.peerId, namespace: space.namespace, tag: tag, indices: indices, startId: holeBounds.startId, endId: holeBounds.endId))
                continue
            }
        }
        
        for item in items.lowerOrAtAnchor {
            if item.index.id.id == 76891 {
                assert(true)
            }
        }
        for item in items.higherThanAnchor {
            if item.index.id.id == 76891 {
                assert(true)
            }
        }
        
        var lowerOrAtAnchorHole: (distanceFromAnchor: Int, hole: SampledHistoryViewHole)?
        
        for i in (-1 ..< items.lowerOrAtAnchor.count).reversed() {
            let startingMessageId: MessageId.Id
            if items.higherThanAnchor.isEmpty {
                startingMessageId = Int32.max - 1
            } else {
                startingMessageId = items.higherThanAnchor[0].index.id.id
            }
            let currentMessageId: MessageId.Id
            if i == -1 {
                if items.lowerOrAtAnchor.count >= halfLimit {
                    break
                }
                currentMessageId = 1
            } else {
                currentMessageId = items.lowerOrAtAnchor[i].index.id.id
            }
            let range: ClosedRange<Int>
            if currentMessageId <= startingMessageId {
                range = Int(currentMessageId) ... Int(startingMessageId)
            } else {
                assertionFailure()
                range = Int(startingMessageId) ... Int(currentMessageId)
            }
            if indices.intersects(integersIn: range) {
                let holeStartIndex: Int
                if let value = indices.integerLessThanOrEqualTo(Int(startingMessageId)) {
                    holeStartIndex = value
                } else {
                    holeStartIndex = indices[indices.endIndex]
                }
                lowerOrAtAnchorHole = (items.lowerOrAtAnchor.count - i, SampledHistoryViewHole(peerId: space.peerId, namespace: space.namespace, tag: tag, indices: indices, startId: Int32(holeStartIndex), endId: 1))
                
                if i == -1 {
                    if items.lowerOrAtAnchor.count == 0 {
                        if items.higherThanAnchor.count == 0 {
                            clipRanges.append(MessageIndex.absoluteLowerBound() ... MessageIndex.absoluteUpperBound())
                        } else {
                            let clipIndex = items.higherThanAnchor[0].index.predecessor()
                            clipRanges.append(MessageIndex.absoluteLowerBound() ... clipIndex)
                        }
                    } else {
                        let clipIndex = items.lowerOrAtAnchor[0].index.predecessor()
                        clipRanges.append(MessageIndex.absoluteLowerBound() ... clipIndex)
                    }
                } else {
                    if i == items.lowerOrAtAnchor.count - 1 {
                        if items.higherThanAnchor.count == 0 {
                            clipRanges.append(MessageIndex.absoluteLowerBound() ... MessageIndex.absoluteUpperBound())
                        } else {
                            let clipIndex = items.higherThanAnchor[0].index.predecessor()
                            clipRanges.append(MessageIndex.absoluteLowerBound() ... clipIndex)
                        }
                    } else {
                        let clipIndex: MessageIndex
                        if indices.contains(Int(items.lowerOrAtAnchor[i + 1].index.id.id)) {
                            clipIndex = items.lowerOrAtAnchor[i + 1].index
                        } else {
                            clipIndex = items.lowerOrAtAnchor[i + 1].index.predecessor()
                        }
                        clipRanges.append(MessageIndex.absoluteLowerBound() ... clipIndex)
                    }
                }
                break
            }
        }
        
        var higherThanAnchorHole: (distanceFromAnchor: Int, hole: SampledHistoryViewHole)?
        
        for i in (0 ..< items.higherThanAnchor.count + 1) {
            let startingMessageId: MessageId.Id
            if items.lowerOrAtAnchor.isEmpty {
                startingMessageId = 1
            } else {
                startingMessageId = items.lowerOrAtAnchor[items.lowerOrAtAnchor.count - 1].index.id.id
            }
            let currentMessageId: MessageId.Id
            if i == items.higherThanAnchor.count {
                if items.higherThanAnchor.count >= halfLimit {
                    break
                }
                currentMessageId = Int32.max - 1
            } else {
                currentMessageId = items.higherThanAnchor[i].index.id.id
            }
            let range: ClosedRange<Int>
            if startingMessageId <= currentMessageId {
                range = Int(startingMessageId) ... Int(currentMessageId)
            } else {
                assertionFailure()
                range = Int(currentMessageId) ... Int(startingMessageId)
            }
            if indices.intersects(integersIn: range) {
                let holeStartIndex: Int
                if let value = indices.integerGreaterThanOrEqualTo(Int(startingMessageId)) {
                    holeStartIndex = value
                } else {
                    holeStartIndex = indices[indices.startIndex]
                }
                higherThanAnchorHole = (i, SampledHistoryViewHole(peerId: space.peerId, namespace: space.namespace, tag: tag, indices: indices, startId: Int32(holeStartIndex), endId: Int32.max - 1))
                
                if i == items.higherThanAnchor.count {
                    if items.higherThanAnchor.count == 0 {
                        if items.lowerOrAtAnchor.count == 0 {
                            clipRanges.append(MessageIndex.absoluteLowerBound() ... MessageIndex.absoluteUpperBound())
                        } else {
                            let clipIndex = items.lowerOrAtAnchor[items.lowerOrAtAnchor.count - 1].index.successor()
                            clipRanges.append(clipIndex ... MessageIndex.absoluteUpperBound())
                        }
                    } else {
                        let clipIndex = items.higherThanAnchor[items.higherThanAnchor.count - 1].index.successor()
                        clipRanges.append(clipIndex ... MessageIndex.absoluteUpperBound())
                    }
                } else {
                    if i == 0 {
                        if items.lowerOrAtAnchor.count == 0 {
                            clipRanges.append(MessageIndex.absoluteLowerBound() ... MessageIndex.absoluteUpperBound())
                        } else {
                            let clipIndex = items.lowerOrAtAnchor[items.lowerOrAtAnchor.count - 1].index.successor()
                            clipRanges.append(clipIndex ... MessageIndex.absoluteUpperBound())
                        }
                    } else {
                        let clipIndex: MessageIndex
                        if indices.contains(Int(items.higherThanAnchor[i - 1].index.id.id)) {
                            clipIndex = items.higherThanAnchor[i - 1].index
                        } else {
                            clipIndex = items.higherThanAnchor[i - 1].index.successor()
                        }
                        clipRanges.append(clipIndex ... MessageIndex.absoluteUpperBound())
                    }
                }
                break
            }
        }
        
        var chosenHole: (distanceFromAnchor: Int, hole: SampledHistoryViewHole)?
        if let lowerOrAtAnchorHole = lowerOrAtAnchorHole, let higherThanAnchorHole = higherThanAnchorHole {
            if items.lowerOrAtAnchor.isEmpty != items.higherThanAnchor.isEmpty {
                if !items.lowerOrAtAnchor.isEmpty {
                    chosenHole = lowerOrAtAnchorHole
                } else {
                    chosenHole = higherThanAnchorHole
                }
            } else {
                if lowerOrAtAnchorHole.distanceFromAnchor < higherThanAnchorHole.distanceFromAnchor {
                    chosenHole = lowerOrAtAnchorHole
                } else {
                    chosenHole = higherThanAnchorHole
                }
            }
        } else if let lowerOrAtAnchorHole = lowerOrAtAnchorHole {
            chosenHole = lowerOrAtAnchorHole
        } else if let higherThanAnchorHole = higherThanAnchorHole {
            chosenHole = higherThanAnchorHole
        }
        
        if let chosenHole = chosenHole {
            if let current = sampledHole {
                if let distance = current.distanceFromAnchor {
                    if chosenHole.distanceFromAnchor < distance {
                        sampledHole = (chosenHole.distanceFromAnchor, chosenHole.hole)
                    }
                }
            } else {
                sampledHole = (chosenHole.distanceFromAnchor, chosenHole.hole)
            }
        }
        
        /*let anchorIndex = binaryIndexOrLower(items.entries, anchor)
        let anchorStartingMessageId: MessageId.Id
        if anchorIndex == -1 {
            anchorStartingMessageId = 1
        } else {
            anchorStartingMessageId = items.entries[anchorIndex].index.id.id
        }
        
        let startingLowerDirectionIndex = anchorIndex
        let startingHigherDirectionIndex = anchorIndex + 1
        
        var lowerDirectionIndex = startingLowerDirectionIndex
        var higherDirectionIndex = startingHigherDirectionIndex
        while lowerDirectionIndex >= 0 || higherDirectionIndex < items.entries.count {
            if lowerDirectionIndex >= 0 {
                let itemIndex = items.entries[lowerDirectionIndex].index
                var itemBoundaryMessageId: MessageId.Id = itemIndex.id.id
                if lowerDirectionIndex == 0 && itemBoundaryMessageId == bounds.lower.id.id {
                    itemBoundaryMessageId = 1
                }
                let previousBoundaryIndex: MessageIndex
                if lowerDirectionIndex == startingLowerDirectionIndex {
                    previousBoundaryIndex = itemIndex
                } else {
                    previousBoundaryIndex = items.entries[lowerDirectionIndex + 1].index
                }
                let toLowerRange: ClosedRange<Int> = min(Int(anchorStartingMessageId), Int(itemBoundaryMessageId)) ... max(Int(anchorStartingMessageId), Int(itemBoundaryMessageId))
                if indices.intersects(integersIn: toLowerRange) {
                    var itemClipIndex: MessageIndex
                    if indices.contains(Int(previousBoundaryIndex.id.id)) {
                        itemClipIndex = previousBoundaryIndex
                    } else {
                        itemClipIndex = previousBoundaryIndex.predecessor()
                    }
                    clipRanges.append(MessageIndex.absoluteLowerBound() ... itemClipIndex)
                    var replaceHole = false
                    if let (currentItemIndex, _) = sampledHole {
                        if let currentItemIndex = currentItemIndex, abs(lowerDirectionIndex - anchorIndex) < abs(currentItemIndex - anchorIndex) {
                            replaceHole = true
                        }
                    } else {
                        replaceHole = true
                    }
                    
                    if replaceHole {
                        if let idInHole = indices.integerLessThanOrEqualTo(toLowerRange.upperBound) {
                            sampledHole = (lowerDirectionIndex, SampledHistoryViewHole(peerId: space.peerId, namespace: space.namespace, tag: tag, indices: indices, startId: MessageId.Id(idInHole), endId: 1))
                        } else {
                            assertionFailure()
                        }
                    }
                    lowerDirectionIndex = -1
                }
            }
            lowerDirectionIndex -= 1
            
            if higherDirectionIndex < items.entries.count {
                let itemIndex = items.entries[higherDirectionIndex].index
                var itemBoundaryMessageId: MessageId.Id = itemIndex.id.id
                if higherDirectionIndex == items.entries.count - 1 && itemBoundaryMessageId == bounds.upper.id.id {
                    itemBoundaryMessageId = Int32.max - 1
                }
                let previousBoundaryIndex: MessageIndex
                if higherDirectionIndex == startingHigherDirectionIndex {
                    previousBoundaryIndex = itemIndex
                } else {
                    previousBoundaryIndex = items.entries[higherDirectionIndex - 1].index
                }
                let toHigherRange: ClosedRange<Int> = min(Int(anchorStartingMessageId), Int(itemBoundaryMessageId)) ... max(Int(anchorStartingMessageId), Int(itemBoundaryMessageId))
                if indices.intersects(integersIn: toHigherRange) {
                    var itemClipIndex: MessageIndex
                    if indices.contains(Int(previousBoundaryIndex.id.id)) {
                        itemClipIndex = previousBoundaryIndex
                    } else {
                        itemClipIndex = previousBoundaryIndex.successor()
                    }
                    clipRanges.append(itemClipIndex ... MessageIndex.absoluteUpperBound())
                    var replaceHole = false
                    if let (currentItemIndex, _) = sampledHole {
                        if let currentItemIndex = currentItemIndex, abs(higherDirectionIndex - anchorIndex) < abs(currentItemIndex - anchorIndex) {
                            replaceHole = true
                        }
                    } else {
                        replaceHole = true
                    }
                    
                    if replaceHole {
                        if let idInHole = indices.integerGreaterThanOrEqualTo(toHigherRange.lowerBound) {
                            sampledHole = (higherDirectionIndex, SampledHistoryViewHole(peerId: space.peerId, namespace: space.namespace, tag: tag, indices: indices, startId: MessageId.Id(idInHole), endId: Int32.max - 1))
                        }
                    }
                    higherDirectionIndex = items.entries.count
                }
            }
            higherDirectionIndex += 1
        }*/
    }
    return (clipRanges, sampledHole?.hole)
}

struct HistoryViewHoles {
    var holesBySpace: [PeerIdAndNamespace: IndexSet]
    
    mutating func insertHole(space: PeerIdAndNamespace, range: ClosedRange<MessageId.Id>) -> Bool {
        if self.holesBySpace[space] == nil {
            self.holesBySpace[space] = IndexSet()
        }
        let intRange = Int(range.lowerBound) ... Int(range.upperBound)
        if self.holesBySpace[space]!.contains(integersIn: intRange) {
            self.holesBySpace[space]!.insert(integersIn: intRange)
            return true
        } else {
            return false
        }
    }
    
    mutating func removeHole(space: PeerIdAndNamespace, range: ClosedRange<MessageId.Id>) -> Bool {
        if self.holesBySpace[space] != nil {
            let intRange = Int(range.lowerBound) ... Int(range.upperBound)
            if self.holesBySpace[space]!.intersects(integersIn: intRange) {
                self.holesBySpace[space]!.remove(integersIn: intRange)
                return true
            } else {
                return false
            }
        } else {
            return false
        }
    }
}

struct OrderedHistoryViewEntries {
    var lowerOrAtAnchor: [MutableMessageHistoryEntry]
    var higherThanAnchor: [MutableMessageHistoryEntry]
    
    mutating func fixMonotony() {
        if self.lowerOrAtAnchor.count > 1 {
            for i in 1 ..< self.lowerOrAtAnchor.count {
                if self.lowerOrAtAnchor[i].index < self.lowerOrAtAnchor[i - 1].index {
                    assertionFailure()
                    break
                }
            }
        }
        if self.higherThanAnchor.count > 1 {
            for i in 1 ..< self.higherThanAnchor.count {
                if self.higherThanAnchor[i].index < self.higherThanAnchor[i - 1].index {
                    assertionFailure()
                    break
                }
            }
        }
        
        var fix = false
        if self.lowerOrAtAnchor.count > 1 {
            for i in 1 ..< self.lowerOrAtAnchor.count {
                if self.lowerOrAtAnchor[i].index.id.id < self.lowerOrAtAnchor[i - 1].index.id.id {
                    fix = true
                    break
                }
            }
        }
        if !fix && self.higherThanAnchor.count > 1 {
            for i in 1 ..< self.higherThanAnchor.count {
                if self.higherThanAnchor[i].index.id.id < self.higherThanAnchor[i - 1].index.id.id {
                    fix = true
                    break
                }
            }
        }
        if fix {
            assertionFailure()
            self.lowerOrAtAnchor.sort(by: { $0.index.id.id < $1.index.id.id })
            self.higherThanAnchor.sort(by: { $0.index.id.id < $1.index.id.id })
        }
    }
    
    func find(index: MessageIndex) -> MutableMessageHistoryEntry? {
        if let entryIndex = binarySearch(self.lowerOrAtAnchor, extract: { $0.index }, searchItem: index) {
            return self.lowerOrAtAnchor[entryIndex]
        } else if let entryIndex = binarySearch(self.higherThanAnchor, extract: { $0.index }, searchItem: index) {
            return self.higherThanAnchor[entryIndex]
        } else {
            return nil
        }
    }
    
    var first: MutableMessageHistoryEntry? {
        return self.lowerOrAtAnchor.first ?? self.higherThanAnchor.first
    }
    
    mutating func mutableScan(_ f: (MutableMessageHistoryEntry) -> MutableMessageHistoryEntry?) -> Bool {
        var anyUpdated = false
        for i in 0 ..< self.lowerOrAtAnchor.count {
            if let updated = f(self.lowerOrAtAnchor[i]) {
                self.lowerOrAtAnchor[i] = updated
                anyUpdated = true
            }
        }
        for i in 0 ..< self.higherThanAnchor.count {
            if let updated = f(self.higherThanAnchor[i]) {
                self.higherThanAnchor[i] = updated
                anyUpdated = true
            }
        }
        return anyUpdated
    }
    
    mutating func update(index: MessageIndex, _ f: (MutableMessageHistoryEntry) -> MutableMessageHistoryEntry?) -> Bool {
        if let entryIndex = binarySearch(self.lowerOrAtAnchor, extract: { $0.index }, searchItem: index) {
            if let updated = f(self.lowerOrAtAnchor[entryIndex]) {
                self.lowerOrAtAnchor[entryIndex] = updated
                return true
            }
        } else if let entryIndex = binarySearch(self.higherThanAnchor, extract: { $0.index }, searchItem: index) {
            if let updated = f(self.higherThanAnchor[entryIndex]) {
                self.higherThanAnchor[entryIndex] = updated
                return true
            }
        }
        return false
    }
    
    mutating func remove(index: MessageIndex) -> Bool {
        if let entryIndex = binarySearch(self.lowerOrAtAnchor, extract: { $0.index }, searchItem: index) {
            self.lowerOrAtAnchor.remove(at: entryIndex)
            return true
        } else if let entryIndex = binarySearch(self.higherThanAnchor, extract: { $0.index }, searchItem: index) {
            self.higherThanAnchor.remove(at: entryIndex)
            return true
        } else {
            return false
        }
    }
}

struct HistoryViewLoadedSample {
    let anchor: HistoryViewAnchor
    let entries: [MessageHistoryMessageEntry]
    let holesToLower: Bool
    let holesToHigher: Bool
    let hole: SampledHistoryViewHole?
}

final class HistoryViewLoadedState {
    let anchor: HistoryViewAnchor
    let tag: MessageTags?
    let statistics: MessageHistoryViewOrderStatistics
    let halfLimit: Int
    let seedConfiguration: SeedConfiguration
    var orderedEntriesBySpace: [PeerIdAndNamespace: OrderedHistoryViewEntries]
    var holes: HistoryViewHoles
    var spacesWithRemovals = Set<PeerIdAndNamespace>()
    
    init(anchor: HistoryViewAnchor, tag: MessageTags?, statistics: MessageHistoryViewOrderStatistics, halfLimit: Int, locations: MessageHistoryViewPeerIds, postbox: Postbox, holes: HistoryViewHoles) {
        precondition(halfLimit >= 3)
        self.anchor = anchor
        self.tag = tag
        self.statistics = statistics
        self.halfLimit = halfLimit
        self.seedConfiguration = postbox.seedConfiguration
        self.orderedEntriesBySpace = [:]
        self.holes = holes
        
        var peerIds: [PeerId] = []
        switch locations {
            case let .single(peerId):
                peerIds.append(peerId)
            case let .associated(peerId, associatedId):
                peerIds.append(peerId)
                if let associatedId = associatedId {
                    peerIds.append(associatedId.peerId)
                }
        }
        
        var spaces: [PeerIdAndNamespace] = []
        for peerId in peerIds {
            for namespace in postbox.messageHistoryIndexTable.existingNamespaces(peerId: peerId) {
                spaces.append(PeerIdAndNamespace(peerId: peerId, namespace: namespace))
            }
        }
        
        for space in spaces {
            self.fillSpace(space: space, postbox: postbox)
        }
    }
    
    private func fillSpace(space: PeerIdAndNamespace, postbox: Postbox) {
        let anchorIndex: MessageIndex
        let lowerBound = MessageIndex.lowerBound(peerId: space.peerId, namespace: space.namespace)
        let upperBound = MessageIndex.upperBound(peerId: space.peerId, namespace: space.namespace)
        switch self.anchor {
            case let .index(index):
                anchorIndex = index.withPeerId(space.peerId).withNamespace(space.namespace)
            case .lowerBound:
                anchorIndex = lowerBound
            case .upperBound:
                anchorIndex = upperBound
        }
        
        var lowerOrAtAnchorMessages: [MutableMessageHistoryEntry] = []
        var higherThanAnchorMessages: [MutableMessageHistoryEntry] = []
        
        if let currentEntries = self.orderedEntriesBySpace[space] {
            lowerOrAtAnchorMessages = currentEntries.lowerOrAtAnchor.reversed()
            higherThanAnchorMessages = currentEntries.higherThanAnchor
        }
        
        func mapEntry(_ message: IntermediateMessage) -> MutableMessageHistoryEntry {
            return .IntermediateMessageEntry(message, nil, nil)
        }
        
        if lowerOrAtAnchorMessages.count < self.halfLimit {
            let nextLowerIndex: (index: MessageIndex, includeFrom: Bool)
            if let lastMessage = lowerOrAtAnchorMessages.min(by: { $0.index < $1.index }) {
                nextLowerIndex = (lastMessage.index, false)
            } else {
                nextLowerIndex = (anchorIndex, true)
            }
            lowerOrAtAnchorMessages.append(contentsOf: postbox.messageHistoryTable.fetch(peerId: space.peerId, namespace: space.namespace, tag: self.tag, from: nextLowerIndex.index, includeFrom: nextLowerIndex.includeFrom, to: lowerBound, limit: self.halfLimit - lowerOrAtAnchorMessages.count).map(mapEntry))
        }
        if higherThanAnchorMessages.count < self.halfLimit {
            let nextHigherIndex: MessageIndex
            if let lastMessage = higherThanAnchorMessages.max(by: { $0.index < $1.index }) {
                nextHigherIndex = lastMessage.index
            } else {
                nextHigherIndex = anchorIndex
            }
            higherThanAnchorMessages.append(contentsOf: postbox.messageHistoryTable.fetch(peerId: space.peerId, namespace: space.namespace, tag: self.tag, from: nextHigherIndex, includeFrom: false, to: upperBound, limit: self.halfLimit - higherThanAnchorMessages.count).map(mapEntry))
        }
        
        lowerOrAtAnchorMessages.reverse()
        
        assert(lowerOrAtAnchorMessages.count <= self.halfLimit)
        assert(higherThanAnchorMessages.count <= self.halfLimit)
        
        var entries = OrderedHistoryViewEntries(lowerOrAtAnchor: lowerOrAtAnchorMessages, higherThanAnchor: higherThanAnchorMessages)
        
        if let tag = self.tag, self.statistics.contains(.combinedLocation), let first = entries.first {
            let messageIndex = first.index
            let previousCount = postbox.messageHistoryTagsTable.getMessageCountInRange(tag: tag, peerId: space.peerId, namespace: space.namespace, lowerBound: MessageIndex.lowerBound(peerId: space.peerId, namespace: space.namespace), upperBound: messageIndex)
            let nextCount = postbox.messageHistoryTagsTable.getMessageCountInRange(tag: tag, peerId: space.peerId, namespace: space.namespace, lowerBound: messageIndex, upperBound: MessageIndex.upperBound(peerId: space.peerId, namespace: space.namespace))
            let initialLocation = MessageHistoryEntryLocation(index: previousCount - 1, count: previousCount + nextCount - 1)
            var nextLocation = initialLocation
            
            let _ = entries.mutableScan { entry in
                let currentLocation = nextLocation
                nextLocation = nextLocation.successor
                switch entry {
                    case let .IntermediateMessageEntry(message, _, monthLocation):
                        return .IntermediateMessageEntry(message, currentLocation, monthLocation)
                    case let .MessageEntry(entry):
                        return .MessageEntry(MessageHistoryMessageEntry(message: entry.message, location: currentLocation, monthLocation: entry.monthLocation, attributes: entry.attributes))
                }
            }
        }
        
        if let tag = self.tag, self.statistics.contains(.locationWithinMonth), let first = entries.first {
            let messageIndex = first.index
            let monthIndex = MessageMonthIndex(timestamp: messageIndex.timestamp)
            let count = postbox.messageHistoryTagsTable.getMessageCountInRange(tag: tag, peerId: space.peerId, namespace: space.namespace, lowerBound: messageIndex, upperBound: monthUpperBoundIndex(peerId: space.peerId, namespace: space.namespace, index: monthIndex))
            
            var nextLocation: (MessageMonthIndex, Int) = (monthIndex, count - 1)
            
            let _ = entries.mutableScan { entry in
                let messageMonthIndex = MessageMonthIndex(timestamp: entry.index.timestamp)
                if messageMonthIndex != nextLocation.0 {
                    nextLocation = (messageMonthIndex, 0)
                }
                
                let currentIndexInMonth = nextLocation.1
                nextLocation.1 = max(0, nextLocation.1 - 1)
                switch entry {
                    case let .IntermediateMessageEntry(message, location, _):
                        return .IntermediateMessageEntry(message, location, MessageHistoryEntryMonthLocation(indexInMonth: Int32(currentIndexInMonth)))
                    case let .MessageEntry(entry):
                        return .MessageEntry(MessageHistoryMessageEntry(message: entry.message, location: entry.location, monthLocation: MessageHistoryEntryMonthLocation(indexInMonth: Int32(currentIndexInMonth)), attributes: entry.attributes))
                }
            }
        }
        
        if canContainHoles(space, seedConfiguration: self.seedConfiguration) {
            entries.fixMonotony()
        }
        self.orderedEntriesBySpace[space] = entries
    }
    
    func insertHole(space: PeerIdAndNamespace, range: ClosedRange<MessageId.Id>) -> Bool {
        assert(canContainHoles(space, seedConfiguration: self.seedConfiguration))
        return self.holes.insertHole(space: space, range: range)
    }
    
    func removeHole(space: PeerIdAndNamespace, range: ClosedRange<MessageId.Id>) -> Bool {
        assert(canContainHoles(space, seedConfiguration: self.seedConfiguration))
        return self.holes.removeHole(space: space, range: range)
    }
    
    func updateTimestamp(postbox: Postbox, index: MessageIndex, timestamp: Int32) -> Bool {
        let space = PeerIdAndNamespace(peerId: index.id.peerId, namespace: index.id.namespace)
        if self.orderedEntriesBySpace[space] == nil {
            return false
        }
        guard let entry = self.orderedEntriesBySpace[space]!.find(index: index) else {
            return false
        }
        var updated = false
        if self.remove(index: index) {
            updated = true
        }
        if self.add(entry: entry.updatedTimestamp(timestamp)) {
            updated = true
        }
        return updated
    }
    
    func updateGroupInfo(mapping: [MessageId: MessageGroupInfo]) -> Bool {
        var mappingsBySpace: [PeerIdAndNamespace: [MessageId.Id: MessageGroupInfo]] = [:]
        for (id, info) in mapping {
            let space = PeerIdAndNamespace(peerId: id.peerId, namespace: id.namespace)
            if mappingsBySpace[space] == nil {
                mappingsBySpace[space] = [:]
            }
            mappingsBySpace[space]![id.id] = info
        }
        var updated = false
        for (space, spaceMapping) in mappingsBySpace {
            if self.orderedEntriesBySpace[space] == nil {
                continue
            }
            let spaceUpdated = self.orderedEntriesBySpace[space]!.mutableScan({ entry in
                if let groupInfo = spaceMapping[entry.index.id.id] {
                    updated = true
                    switch entry {
                        case let .IntermediateMessageEntry(message, location, monthLocation):
                            return .IntermediateMessageEntry(message.withUpdatedGroupInfo(groupInfo), location, monthLocation)
                        case let .MessageEntry(messageEntry):
                            return .MessageEntry(MessageHistoryMessageEntry(message: messageEntry.message.withUpdatedGroupInfo(groupInfo), location: messageEntry.location, monthLocation: messageEntry.monthLocation, attributes: messageEntry.attributes))
                    }
                }
                return nil
            })
            if spaceUpdated {
                updated = true
            }
        }
        return updated
    }
    
    func updateEmbeddedMedia(index: MessageIndex, buffer: ReadBuffer) -> Bool {
        let space = PeerIdAndNamespace(peerId: index.id.peerId, namespace: index.id.namespace)
        if self.orderedEntriesBySpace[space] == nil {
            return false
        }
        
        return self.orderedEntriesBySpace[space]!.update(index: index, { entry in
            switch entry {
                case let .IntermediateMessageEntry(message, location, monthLocation):
                    return .IntermediateMessageEntry(message.withUpdatedEmbeddedMedia(buffer), location, monthLocation)
                case let .MessageEntry(messageEntry):
                    return .MessageEntry(MessageHistoryMessageEntry(message: messageEntry.message, location: messageEntry.location, monthLocation: messageEntry.monthLocation, attributes: messageEntry.attributes))
            }
        })
    }
    
    func updateMedia(updatedMedia: [MediaId: Media?]) -> Bool {
        var updated = false
        for space in self.orderedEntriesBySpace.keys {
            let spaceUpdated = self.orderedEntriesBySpace[space]!.mutableScan({ entry in
                switch entry {
                    case let .MessageEntry(value):
                        let message = value.message
                        
                        var rebuild = false
                        for media in message.media {
                            if let mediaId = media.id, let _ = updatedMedia[mediaId] {
                                rebuild = true
                                break
                            }
                        }
                        
                        if rebuild {
                            var messageMedia: [Media] = []
                            for media in message.media {
                                if let mediaId = media.id, let updated = updatedMedia[mediaId] {
                                    if let updated = updated {
                                        messageMedia.append(updated)
                                    }
                                } else {
                                    messageMedia.append(media)
                                }
                            }
                            let updatedMessage = Message(stableId: message.stableId, stableVersion: message.stableVersion, id: message.id, globallyUniqueId: message.globallyUniqueId, groupingKey: message.groupingKey, groupInfo: message.groupInfo, timestamp: message.timestamp, flags: message.flags, tags: message.tags, globalTags: message.globalTags, localTags: message.localTags, forwardInfo: message.forwardInfo, author: message.author, text: message.text, attributes: message.attributes, media: messageMedia, peers: message.peers, associatedMessages: message.associatedMessages, associatedMessageIds: message.associatedMessageIds)
                            return .MessageEntry(MessageHistoryMessageEntry(message: updatedMessage, location: value.location, monthLocation: value.monthLocation, attributes: value.attributes))
                        }
                    case .IntermediateMessageEntry:
                        break
                }
                return nil
            })
            if spaceUpdated {
                updated = true
            }
        }
        return updated
    }
    
    func add(entry: MutableMessageHistoryEntry) -> Bool {
        let space = PeerIdAndNamespace(peerId: entry.index.id.peerId, namespace: entry.index.id.namespace)
        
        if self.orderedEntriesBySpace[space] == nil {
            self.orderedEntriesBySpace[space] = OrderedHistoryViewEntries(lowerOrAtAnchor: [], higherThanAnchor: [])
        }

        var updated = false
        /*for i in 0 ..< self.orderedEntriesBySpace[space]!.entries.count {
            switch self.orderedEntriesBySpace[space]!.entries[i] {
                case .IntermediateMessageEntry:
                    break
                case let .MessageEntry(currentEntry):
                    if !currentEntry.message.associatedMessageIds.isEmpty && currentEntry.message.associatedMessageIds.contains(entry.index.id) {
                        var associatedMessages = currentEntry.message.associatedMessages
                        switch entry {
                            case let .IntermediateMessageEntry(message, _, _):
                                associatedMessages[entry.index.id] = postbox.messageHistoryTable.renderMessage(message, peerTable: postbox.peerTable)
                            case let .MessageEntry(message):
                                associatedMessages[entry.index.id] = message.message
                        }
                        self.orderedEntriesBySpace[space]!.entries[i] = .MessageEntry(MessageHistoryMessageEntry(message: currentEntry.message.withUpdatedAssociatedMessages(associatedMessages), location: currentEntry.location, monthLocation: currentEntry.monthLocation, attributes: currentEntry.attributes))
                        updated = true
                    }
            }
        }*/
        
        if self.anchor.isEqualOrGreater(than: entry.index) {
            let insertionIndex = binaryInsertionIndex(self.orderedEntriesBySpace[space]!.lowerOrAtAnchor, extract: { $0.index }, searchItem: entry.index)
            
            if insertionIndex < self.orderedEntriesBySpace[space]!.lowerOrAtAnchor.count {
                if self.orderedEntriesBySpace[space]!.lowerOrAtAnchor[insertionIndex].index == entry.index {
                    assertionFailure("Inserting an existing index is not allowed")
                    self.orderedEntriesBySpace[space]!.lowerOrAtAnchor[insertionIndex] = entry
                    return true
                }
            }
            
            if insertionIndex == 0 && self.orderedEntriesBySpace[space]!.lowerOrAtAnchor.count >= self.halfLimit {
                return updated
            }
            self.orderedEntriesBySpace[space]!.lowerOrAtAnchor.insert(entry, at: insertionIndex)
            if self.orderedEntriesBySpace[space]!.lowerOrAtAnchor.count > self.halfLimit {
                self.orderedEntriesBySpace[space]!.lowerOrAtAnchor.removeFirst()
            }
            return true
        } else {
            let insertionIndex = binaryInsertionIndex(self.orderedEntriesBySpace[space]!.higherThanAnchor, extract: { $0.index }, searchItem: entry.index)
            
            if insertionIndex < self.orderedEntriesBySpace[space]!.higherThanAnchor.count {
                if self.orderedEntriesBySpace[space]!.higherThanAnchor[insertionIndex].index == entry.index {
                    assertionFailure("Inserting an existing index is not allowed")
                    self.orderedEntriesBySpace[space]!.higherThanAnchor[insertionIndex] = entry
                    return true
                }
            }
            
            if insertionIndex == self.orderedEntriesBySpace[space]!.higherThanAnchor.count && self.orderedEntriesBySpace[space]!.higherThanAnchor.count >= self.halfLimit {
                return updated
            }
            self.orderedEntriesBySpace[space]!.higherThanAnchor.insert(entry, at: insertionIndex)
            if self.orderedEntriesBySpace[space]!.higherThanAnchor.count > self.halfLimit {
                self.orderedEntriesBySpace[space]!.higherThanAnchor.removeLast()
            }
            return true
        }
    }
    
    func remove(index: MessageIndex) -> Bool {
        let space = PeerIdAndNamespace(peerId: index.id.peerId, namespace: index.id.namespace)
        if self.orderedEntriesBySpace[space] == nil {
            return false
        }
        
        var updated = false
        
        /*for i in 0 ..< self.orderedEntriesBySpace[space]!.entries.count {
            switch self.orderedEntriesBySpace[space]!.entries[i] {
                case .IntermediateMessageEntry:
                    break
                case let .MessageEntry(entry):
                    if let associatedMessages = entry.message.associatedMessages.filteredOut(keysIn: [index.id]) {
                        self.orderedEntriesBySpace[space]!.entries[i] = .MessageEntry(MessageHistoryMessageEntry(message: entry.message.withUpdatedAssociatedMessages(associatedMessages), location: entry.location, monthLocation: entry.monthLocation, attributes: entry.attributes))
                        updated = true
                    }
            }
        }*/
        
        if self.orderedEntriesBySpace[space]!.remove(index: index) {
            self.spacesWithRemovals.insert(space)
            updated = true
        }
        
        return updated
    }
    
    func completeAndSample(postbox: Postbox) -> HistoryViewLoadedSample {
        if !self.spacesWithRemovals.isEmpty {
            for space in self.spacesWithRemovals {
                self.fillSpace(space: space, postbox: postbox)
            }
            self.spacesWithRemovals.removeAll()
        }
        let combinedSpacesAndIndicesByDirection = sampleEntries(orderedEntriesBySpace: self.orderedEntriesBySpace, anchor: self.anchor, halfLimit: self.halfLimit)
        let (clipRanges, sampledHole) = sampleHoleRanges(orderedEntriesBySpace: self.orderedEntriesBySpace, holes: self.holes, anchor: self.anchor, tag: self.tag, halfLimit: self.halfLimit, seedConfiguration: self.seedConfiguration)
        
        var holesToLower = false
        var holesToHigher = false
        var result: [MessageHistoryMessageEntry] = []
        if combinedSpacesAndIndicesByDirection.lowerOrAtAnchor.isEmpty && combinedSpacesAndIndicesByDirection.higherThanAnchor.isEmpty {
            if !clipRanges.isEmpty {
                holesToLower = true
                holesToHigher = true
            }
        } else {
            let directions = [combinedSpacesAndIndicesByDirection.lowerOrAtAnchor, combinedSpacesAndIndicesByDirection.higherThanAnchor]
            for directionIndex in 0 ..< directions.count {
                outer: for i in 0 ..< directions[directionIndex].count {
                    let (space, index) = directions[directionIndex][i]
                    
                    let entry: MutableMessageHistoryEntry
                    if directionIndex == 0 {
                        entry = self.orderedEntriesBySpace[space]!.lowerOrAtAnchor[index]
                    } else {
                        entry = self.orderedEntriesBySpace[space]!.higherThanAnchor[index]
                    }
                    
                    if !clipRanges.isEmpty {
                        let entryIndex = entry.index
                        for range in clipRanges {
                            if range.contains(entryIndex) {
                                if directionIndex == 0 && i == 0 {
                                    holesToLower = true
                                }
                                if directionIndex == 1 && i == directions[directionIndex].count - 1 {
                                    holesToHigher = true
                                }
                                continue outer
                            }
                        }
                    }
                    
                    switch entry {
                        case let .MessageEntry(value):
                            result.append(value)
                        case let .IntermediateMessageEntry(message, location, monthLocation):
                            let renderedMessage = postbox.messageHistoryTable.renderMessage(message, peerTable: postbox.peerTable)
                            var authorIsContact = false
                            if let author = renderedMessage.author {
                                authorIsContact = postbox.contactsTable.isContact(peerId: author.id)
                            }
                            let entry = MessageHistoryMessageEntry(message: renderedMessage, location: location, monthLocation: monthLocation, attributes: MutableMessageHistoryEntryAttributes(authorIsContact: authorIsContact))
                            if directionIndex == 0 {
                                self.orderedEntriesBySpace[space]!.lowerOrAtAnchor[index] = .MessageEntry(entry)
                            } else {
                                self.orderedEntriesBySpace[space]!.higherThanAnchor[index] = .MessageEntry(entry)
                            }
                            result.append(entry)
                    }
                }
            }
        }
        //assert(Set(result.map({ $0.message.stableId })).count == result.count)
        return HistoryViewLoadedSample(anchor: self.anchor, entries: result, holesToLower: holesToLower, holesToHigher: holesToHigher, hole: sampledHole)
    }
}

private func fetchHoles(postbox: Postbox, locations: MessageHistoryViewPeerIds, tag: MessageTags?) -> [PeerIdAndNamespace: IndexSet] {
    var holesBySpace: [PeerIdAndNamespace: IndexSet] = [:]
    var peerIds: [PeerId] = []
    switch locations {
    case let .single(peerId):
        peerIds.append(peerId)
    case let .associated(peerId, associatedId):
        peerIds.append(peerId)
        if let associatedId = associatedId {
            peerIds.append(associatedId.peerId)
        }
    }
    let holeSpace = tag.flatMap(MessageHistoryHoleSpace.tag) ?? .everywhere
    for peerId in peerIds {
        for namespace in postbox.messageHistoryHoleIndexTable.existingNamespaces(peerId: peerId, holeSpace: holeSpace) {
            let indices = postbox.messageHistoryHoleIndexTable.closest(peerId: peerId, namespace: namespace, space: holeSpace, range: 1 ... (Int32.max - 1))
            if !indices.isEmpty {
                let peerIdAndNamespace = PeerIdAndNamespace(peerId: peerId, namespace: namespace)
                assert(canContainHoles(peerIdAndNamespace, seedConfiguration: postbox.seedConfiguration))
                holesBySpace[peerIdAndNamespace] = indices
            }
        }
    }
    return holesBySpace
}

enum HistoryViewLoadingSample {
    case ready(HistoryViewAnchor, HistoryViewHoles)
    case loadHole(PeerId, MessageId.Namespace, MessageTags?, MessageId.Id)
}

final class HistoryViewLoadingState {
    var messageId: MessageId
    let tag: MessageTags?
    let halfLimit: Int
    var holes: HistoryViewHoles
    
    init(postbox: Postbox, locations: MessageHistoryViewPeerIds, tag: MessageTags?, messageId: MessageId, halfLimit: Int) {
        self.messageId = messageId
        self.tag = tag
        self.halfLimit = halfLimit
        self.holes = HistoryViewHoles(holesBySpace: fetchHoles(postbox: postbox, locations: locations, tag: tag))
    }
    
    func insertHole(space: PeerIdAndNamespace, range: ClosedRange<MessageId.Id>) -> Bool {
        return self.holes.insertHole(space: space, range: range)
    }
    
    func removeHole(space: PeerIdAndNamespace, range: ClosedRange<MessageId.Id>) -> Bool {
        return self.holes.removeHole(space: space, range: range)
    }
    
    func checkAndSample(postbox: Postbox) -> HistoryViewLoadingSample {
        while true {
            if let indices = self.holes.holesBySpace[PeerIdAndNamespace(peerId: self.messageId.peerId, namespace: self.messageId.namespace)] {
                if indices.contains(Int(messageId.id)) {
                    return .loadHole(messageId.peerId, messageId.namespace, self.tag, messageId.id)
                }
            }
            
            if let index = postbox.messageHistoryIndexTable.getIndex(self.messageId) {
                return .ready(.index(index), self.holes)
            }
            if let nextHigherIndex = postbox.messageHistoryIndexTable.indexForId(higherThan: self.messageId) {
                self.messageId = nextHigherIndex.id
            } else {
                return .ready(.upperBound, self.holes)
            }
        }
    }
}

enum HistoryViewSample {
    case loaded(HistoryViewLoadedSample)
    case loading(HistoryViewLoadingSample)
}

enum HistoryViewState {
    case loaded(HistoryViewLoadedState)
    case loading(HistoryViewLoadingState)
    
    init(postbox: Postbox, inputAnchor: HistoryViewInputAnchor, tag: MessageTags?, statistics: MessageHistoryViewOrderStatistics, halfLimit: Int, locations: MessageHistoryViewPeerIds) {
        switch inputAnchor {
            case let .index(index):
                self = .loaded(HistoryViewLoadedState(anchor: .index(index), tag: tag, statistics: statistics, halfLimit: halfLimit, locations: locations, postbox: postbox, holes: HistoryViewHoles(holesBySpace: fetchHoles(postbox: postbox, locations: locations, tag: tag))))
            case .lowerBound:
                self = .loaded(HistoryViewLoadedState(anchor: .lowerBound, tag: tag, statistics: statistics, halfLimit: halfLimit, locations: locations, postbox: postbox, holes: HistoryViewHoles(holesBySpace: fetchHoles(postbox: postbox, locations: locations, tag: tag))))
            case .upperBound:
                self = .loaded(HistoryViewLoadedState(anchor: .upperBound, tag: tag, statistics: statistics, halfLimit: halfLimit, locations: locations, postbox: postbox, holes: HistoryViewHoles(holesBySpace: fetchHoles(postbox: postbox, locations: locations, tag: tag))))
            case .unread:
                let anchorPeerId: PeerId
                switch locations {
                    case let .single(peerId):
                        anchorPeerId = peerId
                    case let .associated(peerId, _):
                        anchorPeerId = peerId
                }
                if postbox.chatListIndexTable.get(peerId: anchorPeerId).includedIndex(peerId: anchorPeerId) != nil, let combinedState = postbox.readStateTable.getCombinedState(anchorPeerId) {
                    var messageId: MessageId?
                    var anchor: HistoryViewAnchor?
                    loop: for (namespace, state) in combinedState.states {
                        switch state {
                            case let .idBased(maxIncomingReadId, _, _, count, _):
                                if count == 0 {
                                    anchor = .upperBound
                                    break loop
                                } else {
                                    messageId = MessageId(peerId: anchorPeerId, namespace: namespace, id: maxIncomingReadId)
                                    break loop
                                }
                            case let .indexBased(maxIncomingReadIndex, _, count, _):
                                if count == 0 {
                                    anchor = .upperBound
                                    break loop
                                } else {
                                    anchor = .index(maxIncomingReadIndex)
                                    break loop
                                }
                        }
                    }
                    if let messageId = messageId {
                        let loadingState = HistoryViewLoadingState(postbox: postbox, locations: locations, tag: tag, messageId: messageId, halfLimit: halfLimit)
                        let sampledState = loadingState.checkAndSample(postbox: postbox)
                        switch sampledState {
                            case let .ready(anchor, holes):
                                self = .loaded(HistoryViewLoadedState(anchor: anchor, tag: tag, statistics: statistics, halfLimit: halfLimit, locations: locations, postbox: postbox, holes: holes))
                            case .loadHole:
                                self = .loading(loadingState)
                        }
                    } else {
                        self = .loaded(HistoryViewLoadedState(anchor: anchor ?? .upperBound, tag: tag, statistics: statistics, halfLimit: halfLimit, locations: locations, postbox: postbox, holes: HistoryViewHoles(holesBySpace: fetchHoles(postbox: postbox, locations: locations, tag: tag))))
                    }
                } else {
                    preconditionFailure()
                }
            case let .message(messageId):
                let loadingState = HistoryViewLoadingState(postbox: postbox, locations: locations, tag: tag, messageId: messageId, halfLimit: halfLimit)
                let sampledState = loadingState.checkAndSample(postbox: postbox)
                switch sampledState {
                    case let .ready(anchor, holes):
                        self = .loaded(HistoryViewLoadedState(anchor: anchor, tag: tag, statistics: statistics, halfLimit: halfLimit, locations: locations, postbox: postbox, holes: holes))
                    case .loadHole:
                        self = .loading(loadingState)
                }
        }
    }
    
    func sample(postbox: Postbox) -> HistoryViewSample {
        switch self {
            case let .loading(loadingState):
                return .loading(loadingState.checkAndSample(postbox: postbox))
            case let .loaded(loadedState):
                return .loaded(loadedState.completeAndSample(postbox: postbox))
        }
    }
}
