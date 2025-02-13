import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData

enum ShareState {
    case preparing
    case progress(Float)
    case done
}

enum ShareExternalState {
    case preparing
    case done
}

func openExternalShare(state: () -> Signal<ShareExternalState, NoError>) {
    
}

final class ShareControllerNode: ViewControllerTracingNode, UIScrollViewDelegate {
    private let sharedContext: SharedAccountContext
    private var presentationData: PresentationData
    private let externalShare: Bool
    private let immediateExternalShare: Bool
    
    private let defaultAction: ShareControllerAction?
    private let requestLayout: (ContainedViewLayoutTransition) -> Void
    
    private var containerLayout: (ContainerViewLayout, CGFloat, CGFloat)?
    
    private let dimNode: ASDisplayNode
    
    private let wrappingScrollNode: ASScrollNode
    private let cancelButtonNode: ASButtonNode
    
    private let contentContainerNode: ASDisplayNode
    private let contentBackgroundNode: ASImageNode
    
    private var contentNode: (ASDisplayNode & ShareContentContainerNode)?
    private var previousContentNode: (ASDisplayNode & ShareContentContainerNode)?
    private var animateContentNodeOffsetFromBackgroundOffset: CGFloat?
    
    private let actionsBackgroundNode: ASImageNode
    private let actionButtonNode: ShareActionButtonNode
    private let inputFieldNode: ShareInputFieldNode
    private let actionSeparatorNode: ASDisplayNode
    
    var dismiss: ((Bool) -> Void)?
    var cancel: (() -> Void)?
    var share: ((String, [PeerId]) -> Signal<ShareState, NoError>)?
    var shareExternal: (() -> Signal<ShareExternalState, NoError>)?
    var switchToAnotherAccount: (() -> Void)?
    
    let ready = Promise<Bool>()
    private var didSetReady = false
    
    private var controllerInteraction: ShareControllerInteraction?
    
    private var peersContentNode: SharePeersContainerNode?
    
    private var scheduledLayoutTransitionRequestId: Int = 0
    private var scheduledLayoutTransitionRequest: (Int, ContainedViewLayoutTransition)?
    
    private let shareDisposable = MetaDisposable()
    
    private var hapticFeedback: HapticFeedback?
    
    init(sharedContext: SharedAccountContext, defaultAction: ShareControllerAction?, requestLayout: @escaping (ContainedViewLayoutTransition) -> Void, externalShare: Bool, immediateExternalShare: Bool) {
        self.sharedContext = sharedContext
        self.presentationData = sharedContext.currentPresentationData.with { $0 }
        self.externalShare = externalShare
        self.immediateExternalShare = immediateExternalShare
        
        self.defaultAction = defaultAction
        self.requestLayout = requestLayout
        
        let roundedBackground = generateStretchableFilledCircleImage(radius: 16.0, color: self.presentationData.theme.actionSheet.opaqueItemBackgroundColor)
        let highlightedRoundedBackground = generateStretchableFilledCircleImage(radius: 16.0, color: self.presentationData.theme.actionSheet.opaqueItemHighlightedBackgroundColor)
        
        let theme = self.presentationData.theme
        let halfRoundedBackground = generateImage(CGSize(width: 32.0, height: 32.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(theme.actionSheet.opaqueItemBackgroundColor.cgColor)
            context.fillEllipse(in: CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height)))
            context.fill(CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height / 2.0)))
        })?.stretchableImage(withLeftCapWidth: 16, topCapHeight: 1)
        
        let highlightedHalfRoundedBackground = generateImage(CGSize(width: 32.0, height: 32.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(theme.actionSheet.opaqueItemHighlightedBackgroundColor.cgColor)
            context.fillEllipse(in: CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height)))
            context.fill(CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height / 2.0)))
        })?.stretchableImage(withLeftCapWidth: 16, topCapHeight: 1)
        
        self.wrappingScrollNode = ASScrollNode()
        self.wrappingScrollNode.view.alwaysBounceVertical = true
        self.wrappingScrollNode.view.delaysContentTouches = false
        self.wrappingScrollNode.view.canCancelContentTouches = true
        
        self.dimNode = ASDisplayNode()
        self.dimNode.backgroundColor = UIColor(white: 0.0, alpha: 0.5)
        
        self.cancelButtonNode = ASButtonNode()
        self.cancelButtonNode.displaysAsynchronously = false
        self.cancelButtonNode.setBackgroundImage(roundedBackground, for: .normal)
        self.cancelButtonNode.setBackgroundImage(highlightedRoundedBackground, for: .highlighted)
        
        self.contentContainerNode = ASDisplayNode()
        self.contentContainerNode.isOpaque = false
        self.contentContainerNode.clipsToBounds = true
        
        self.contentBackgroundNode = ASImageNode()
        self.contentBackgroundNode.displaysAsynchronously = false
        self.contentBackgroundNode.displayWithoutProcessing = true
        self.contentBackgroundNode.image = roundedBackground
        
        self.actionsBackgroundNode = ASImageNode()
        self.actionsBackgroundNode.isLayerBacked = true
        self.actionsBackgroundNode.displayWithoutProcessing = true
        self.actionsBackgroundNode.displaysAsynchronously = false
        self.actionsBackgroundNode.image = halfRoundedBackground
        
        self.actionButtonNode = ShareActionButtonNode(badgeBackgroundColor: self.presentationData.theme.actionSheet.controlAccentColor, badgeTextColor: self.presentationData.theme.actionSheet.opaqueItemBackgroundColor)
        self.actionButtonNode.displaysAsynchronously = false
        self.actionButtonNode.titleNode.displaysAsynchronously = false
        self.actionButtonNode.setBackgroundImage(highlightedHalfRoundedBackground, for: .highlighted)
        
        self.inputFieldNode = ShareInputFieldNode(theme: ShareInputFieldNodeTheme(presentationTheme: self.presentationData.theme), placeholder: self.presentationData.strings.ShareMenu_Comment)
        self.inputFieldNode.alpha = 0.0
        
        self.actionSeparatorNode = ASDisplayNode()
        self.actionSeparatorNode.isLayerBacked = true
        self.actionSeparatorNode.displaysAsynchronously = false
        self.actionSeparatorNode.backgroundColor = self.presentationData.theme.actionSheet.opaqueItemSeparatorColor
        
        if self.defaultAction == nil {
            self.actionButtonNode.alpha = 0.0
            self.actionsBackgroundNode.alpha = 0.0
            self.actionSeparatorNode.alpha = 0.0
        }
        
        super.init()
        
        self.controllerInteraction = ShareControllerInteraction(togglePeer: { [weak self] peer, search in
            if let strongSelf = self {
                var added = false
                if strongSelf.controllerInteraction!.selectedPeerIds.contains(peer.peerId) {
                    strongSelf.controllerInteraction!.selectedPeerIds.remove(peer.peerId)
                    strongSelf.controllerInteraction!.selectedPeers = strongSelf.controllerInteraction!.selectedPeers.filter({ $0.peerId != peer.peerId })
                } else {
                    strongSelf.controllerInteraction!.selectedPeerIds.insert(peer.peerId)
                    strongSelf.controllerInteraction!.selectedPeers.append(peer)
                    
                    strongSelf.contentNode?.setEnsurePeerVisibleOnLayout(peer.peerId)
                    added = true
                }
                
                if search && added {
                    strongSelf.controllerInteraction!.foundPeers = strongSelf.controllerInteraction!.foundPeers.filter { otherPeer in
                        return peer.peerId != otherPeer.peerId
                    }
                    strongSelf.controllerInteraction!.foundPeers.append(peer)
                    strongSelf.peersContentNode?.updateFoundPeers()
                }
                
                strongSelf.setActionNodesHidden(strongSelf.controllerInteraction!.selectedPeers.isEmpty, inputField: true, actions: strongSelf.defaultAction == nil)
                
                strongSelf.updateButton()
                
                strongSelf.peersContentNode?.updateSelectedPeers()
                strongSelf.contentNode?.updateSelectedPeers()
                
                if let (layout, navigationBarHeight, _) = strongSelf.containerLayout {
                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.4, curve: .spring))
                }
                
                if added, strongSelf.contentNode is ShareSearchContainerNode {
                    if let peersContentNode = strongSelf.peersContentNode {
                        strongSelf.transitionToContentNode(peersContentNode)
                    }
                }
            }
        })
        
        self.backgroundColor = nil
        self.isOpaque = false
        
        self.dimNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.dimTapGesture(_:))))
        self.addSubnode(self.dimNode)
        
        self.wrappingScrollNode.view.delegate = self
        self.addSubnode(self.wrappingScrollNode)
        
        self.cancelButtonNode.setTitle(self.presentationData.strings.Common_Cancel, with: Font.medium(20.0), with: self.presentationData.theme.actionSheet.standardActionTextColor, for: .normal)
        
        self.wrappingScrollNode.addSubnode(self.cancelButtonNode)
        self.cancelButtonNode.addTarget(self, action: #selector(self.cancelButtonPressed), forControlEvents: .touchUpInside)
        
        self.actionButtonNode.addTarget(self, action: #selector(self.actionButtonPressed), forControlEvents: .touchUpInside)
        
        self.wrappingScrollNode.addSubnode(self.contentBackgroundNode)
        
        self.wrappingScrollNode.addSubnode(self.contentContainerNode)
        self.contentContainerNode.addSubnode(self.actionSeparatorNode)
        self.contentContainerNode.addSubnode(self.actionsBackgroundNode)
        self.contentContainerNode.addSubnode(self.actionButtonNode)
        self.contentContainerNode.addSubnode(self.inputFieldNode)
        
        self.inputFieldNode.updateHeight = { [weak self] in
            if let strongSelf = self {
                if let (layout, navigationBarHeight, _) = strongSelf.containerLayout {
                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.15, curve: .spring))
                }
            }
        }
        
        self.updateButton()
    }
    
    deinit {
        self.shareDisposable.dispose()
    }
    
    override func didLoad() {
        super.didLoad()
        
        if #available(iOSApplicationExtension 11.0, iOS 11.0, *) {
            self.wrappingScrollNode.view.contentInsetAdjustmentBehavior = .never
        }
    }
    
    func updatePresentationData(_ presentationData: PresentationData) {
        guard self.presentationData !== presentationData else {
            return
        }
        self.presentationData = presentationData
        
        let roundedBackground = generateStretchableFilledCircleImage(radius: 16.0, color: self.presentationData.theme.actionSheet.opaqueItemBackgroundColor)
        let highlightedRoundedBackground = generateStretchableFilledCircleImage(radius: 16.0, color: self.presentationData.theme.actionSheet.opaqueItemHighlightedBackgroundColor)
        
        let theme = self.presentationData.theme
        let halfRoundedBackground = generateImage(CGSize(width: 32.0, height: 32.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(theme.actionSheet.opaqueItemBackgroundColor.cgColor)
            context.fillEllipse(in: CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height)))
            context.fill(CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height / 2.0)))
        })?.stretchableImage(withLeftCapWidth: 16, topCapHeight: 1)
        
        let highlightedHalfRoundedBackground = generateImage(CGSize(width: 32.0, height: 32.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(theme.actionSheet.opaqueItemHighlightedBackgroundColor.cgColor)
            context.fillEllipse(in: CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height)))
            context.fill(CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height / 2.0)))
        })?.stretchableImage(withLeftCapWidth: 16, topCapHeight: 1)
        
        self.cancelButtonNode.setBackgroundImage(roundedBackground, for: .normal)
        self.cancelButtonNode.setBackgroundImage(highlightedRoundedBackground, for: .highlighted)
        
        self.contentBackgroundNode.image = roundedBackground
        self.actionsBackgroundNode.image = halfRoundedBackground
        self.actionButtonNode.setBackgroundImage(highlightedHalfRoundedBackground, for: .highlighted)
        self.actionSeparatorNode.backgroundColor = presentationData.theme.actionSheet.opaqueItemSeparatorColor
        self.cancelButtonNode.setTitle(presentationData.strings.Common_Cancel, with: Font.medium(20.0), with: presentationData.theme.actionSheet.standardActionTextColor, for: .normal)
        
        self.actionButtonNode.badgeBackgroundColor = presentationData.theme.actionSheet.controlAccentColor
        self.actionButtonNode.badgeTextColor = presentationData.theme.actionSheet.opaqueItemBackgroundColor
    }
    
    func setActionNodesHidden(_ hidden: Bool, inputField: Bool = false, actions: Bool = false) {
        func updateActionNodesAlpha(_ nodes: [ASDisplayNode], alpha: CGFloat) {
            for node in nodes {
                if !node.alpha.isEqual(to: alpha) {
                    let previousAlpha = node.alpha
                    node.alpha = alpha
                    node.layer.animateAlpha(from: previousAlpha, to: alpha, duration: alpha.isZero ? 0.18 : 0.32)
                    
                    if let inputNode = node as? ShareInputFieldNode, alpha.isZero {
                        inputNode.deactivateInput()
                    }
                }
            }
        }
        
        var actionNodes: [ASDisplayNode] = []
        if inputField {
            actionNodes.append(self.inputFieldNode)
        }
        if actions {
            actionNodes.append(contentsOf: [self.actionsBackgroundNode, self.actionButtonNode, self.actionSeparatorNode])
        }
        updateActionNodesAlpha(actionNodes, alpha: hidden ? 0.0 : 1.0)
    }
    
    func transitionToContentNode(_ contentNode: (ASDisplayNode & ShareContentContainerNode)?, fastOut: Bool = false, animated: Bool = true) {
        if self.contentNode !== contentNode {
            let transition: ContainedViewLayoutTransition
            
            let previous = self.contentNode
            if let previous = previous {
                previous.setContentOffsetUpdated(nil)
                if animated {
                    transition = .animated(duration: 0.4, curve: .spring)
                    self.previousContentNode = previous
                    previous.alpha = 0.0
                    previous.layer.animateAlpha(from: 1.0, to: 0.0, duration: fastOut ? 0.1 : 0.2, removeOnCompletion: true, completion: { [weak self, weak previous] _ in
                        if let strongSelf = self, let previous = previous {
                            if strongSelf.previousContentNode === previous {
                                strongSelf.previousContentNode = nil
                            }
                            previous.removeFromSupernode()
                        }
                    })
                } else {
                    transition = .immediate
                    previous.removeFromSupernode()
                    self.previousContentNode = nil
                }
            } else {
                transition = .immediate
            }
            self.contentNode = contentNode
            
            if let (layout, navigationBarHeight, bottomGridInset) = self.containerLayout {
                if let contentNode = contentNode, let previous = previous {
                    contentNode.frame = previous.frame
                    contentNode.updateLayout(size: previous.bounds.size, bottomInset: bottomGridInset, transition: .immediate)
                    
                    contentNode.setContentOffsetUpdated({ [weak self] contentOffset, transition in
                        self?.contentNodeOffsetUpdated(contentOffset, transition: transition)
                    })
                    self.contentContainerNode.insertSubnode(contentNode, at: 0)
                    
                    contentNode.alpha = 1.0
                    if animated {
                        let animation = contentNode.layer.makeAnimation(from: 0.0 as NSNumber, to: 1.0 as NSNumber, keyPath: "opacity", timingFunction: kCAMediaTimingFunctionEaseInEaseOut, duration: 0.35)
                        animation.fillMode = kCAFillModeBoth
                        if !fastOut {
                            animation.beginTime = CACurrentMediaTime() + 0.1
                        }
                        contentNode.layer.add(animation, forKey: "opacity")
                    }
                    
                    self.animateContentNodeOffsetFromBackgroundOffset = self.contentBackgroundNode.frame.minY
                    self.scheduleInteractiveTransition(transition)
                    
                    contentNode.activate()
                    previous.deactivate()
                    
                    if contentNode is ShareSearchContainerNode {
                        self.setActionNodesHidden(true, inputField: true, actions: true)
                    } else if !(contentNode is ShareLoadingContainerNode) {
                        self.setActionNodesHidden(false, inputField: !self.controllerInteraction!.selectedPeers.isEmpty, actions: true)
                    }
                } else {
                    if let contentNode = self.contentNode {
                        contentNode.setContentOffsetUpdated({ [weak self] contentOffset, transition in
                            self?.contentNodeOffsetUpdated(contentOffset, transition: transition)
                        })
                        self.contentContainerNode.insertSubnode(contentNode, at: 0)
                    }
                    
                    self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: transition)
                }
            } else if let contentNode = contentNode {
                contentNode.setContentOffsetUpdated({ [weak self] contentOffset, transition in
                    self?.contentNodeOffsetUpdated(contentOffset, transition: transition)
                })
                self.contentContainerNode.insertSubnode(contentNode, at: 0)
            }
        }
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        var insets = layout.insets(options: [.statusBar, .input])
        let cleanInsets = layout.insets(options: [.statusBar])
        insets.top = max(10.0, insets.top)
        
        var bottomInset: CGFloat = 10.0 + cleanInsets.bottom
        if insets.bottom > 0 {
            bottomInset -= 12.0
        }
        
        let buttonHeight: CGFloat = 57.0
        let sectionSpacing: CGFloat = 8.0
        let titleAreaHeight: CGFloat = 64.0
        
        let maximumContentHeight = layout.size.height - insets.top - max(bottomInset + buttonHeight, insets.bottom) - sectionSpacing
        
        let width = horizontalContainerFillingSizeForLayout(layout: layout, sideInset: 10.0 + layout.safeInsets.left)
        
        let sideInset = floor((layout.size.width - width) / 2.0)
        
        let contentContainerFrame = CGRect(origin: CGPoint(x: sideInset, y: insets.top), size: CGSize(width: width, height: maximumContentHeight))
        let contentFrame = contentContainerFrame.insetBy(dx: 0.0, dy: 0.0)
        
        var bottomGridInset: CGFloat = 0
 
        var actionButtonHeight: CGFloat = 0
        if self.defaultAction != nil || !self.controllerInteraction!.selectedPeers.isEmpty {
            actionButtonHeight = buttonHeight
            bottomGridInset += actionButtonHeight
        }
 
        let inputHeight = self.inputFieldNode.updateLayout(width: contentContainerFrame.size.width, transition: transition)
        if !self.controllerInteraction!.selectedPeers.isEmpty {
            bottomGridInset += inputHeight
        }
        
        self.containerLayout = (layout, navigationBarHeight, bottomGridInset)
        self.scheduledLayoutTransitionRequest = nil
        
        transition.updateFrame(node: self.wrappingScrollNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        
        transition.updateFrame(node: self.dimNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        
        transition.updateFrame(node: self.cancelButtonNode, frame: CGRect(origin: CGPoint(x: sideInset, y: layout.size.height - bottomInset - buttonHeight), size: CGSize(width: width, height: buttonHeight)))
        
        transition.updateFrame(node: self.contentContainerNode, frame: contentContainerFrame)
        
        transition.updateFrame(node: self.actionsBackgroundNode, frame: CGRect(origin: CGPoint(x: 0.0, y: contentContainerFrame.size.height - bottomGridInset), size: CGSize(width: contentContainerFrame.size.width, height: bottomGridInset)))
        
        transition.updateFrame(node: self.actionButtonNode, frame: CGRect(origin: CGPoint(x: 0.0, y: contentContainerFrame.size.height - actionButtonHeight), size: CGSize(width: contentContainerFrame.size.width, height: buttonHeight)))
        
        transition.updateFrame(node: self.inputFieldNode, frame: CGRect(origin: CGPoint(x: 0.0, y: contentContainerFrame.size.height - bottomGridInset), size: CGSize(width: contentContainerFrame.size.width, height: inputHeight)))
        
        transition.updateFrame(node: self.actionSeparatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: contentContainerFrame.size.height - bottomGridInset - UIScreenPixel), size: CGSize(width: contentContainerFrame.size.width, height: UIScreenPixel)))
        
        let gridSize = CGSize(width: contentFrame.size.width, height: max(32.0, contentFrame.size.height - titleAreaHeight))
        
        if let contentNode = self.contentNode {
            transition.updateFrame(node: contentNode, frame: CGRect(origin: CGPoint(x: floor((contentContainerFrame.size.width - contentFrame.size.width) / 2.0), y: titleAreaHeight), size: gridSize))
            contentNode.updateLayout(size: gridSize, bottomInset: bottomGridInset, transition: transition)
        }
    }
    
    private func contentNodeOffsetUpdated(_ contentOffset: CGFloat, transition: ContainedViewLayoutTransition) {
        if let (layout, _, _) = self.containerLayout {
            var insets = layout.insets(options: [.statusBar, .input])
            insets.top = max(10.0, insets.top)
            let cleanInsets = layout.insets(options: [.statusBar])
            
            var bottomInset: CGFloat = 10.0 + cleanInsets.bottom
            if insets.bottom > 0 {
                bottomInset -= 12.0
            }
            let buttonHeight: CGFloat = 57.0
            let sectionSpacing: CGFloat = 8.0
            
            let width = horizontalContainerFillingSizeForLayout(layout: layout, sideInset: 10.0 + layout.safeInsets.left)
            
            let sideInset = floor((layout.size.width - width) / 2.0)
            
            let maximumContentHeight = layout.size.height - insets.top - max(bottomInset + buttonHeight, insets.bottom) - sectionSpacing
            let contentFrame = CGRect(origin: CGPoint(x: sideInset, y: insets.top), size: CGSize(width: width, height: maximumContentHeight))
            
            var backgroundFrame = CGRect(origin: CGPoint(x: contentFrame.minX, y: contentFrame.minY - contentOffset), size: contentFrame.size)
            if backgroundFrame.minY < contentFrame.minY {
                backgroundFrame.origin.y = contentFrame.minY
            }
            if backgroundFrame.maxY > contentFrame.maxY {
                backgroundFrame.size.height += contentFrame.maxY - backgroundFrame.maxY
            }
            if backgroundFrame.size.height < buttonHeight + 32.0 {
                backgroundFrame.origin.y -= buttonHeight + 32.0 - backgroundFrame.size.height
                backgroundFrame.size.height = buttonHeight + 32.0
            }
            transition.updateFrame(node: self.contentBackgroundNode, frame: backgroundFrame)
            
            if let animateContentNodeOffsetFromBackgroundOffset = self.animateContentNodeOffsetFromBackgroundOffset {
                self.animateContentNodeOffsetFromBackgroundOffset = nil
                let offset = backgroundFrame.minY - animateContentNodeOffsetFromBackgroundOffset
                if let contentNode = self.contentNode {
                    transition.animatePositionAdditive(node: contentNode, offset: CGPoint(x: 0.0, y: -offset))
                }
                if let previousContentNode = self.previousContentNode {
                    transition.updatePosition(node: previousContentNode, position: previousContentNode.position.offsetBy(dx: 0.0, dy: offset))
                }
            }
        }
    }
    
    @objc func dimTapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.cancelButtonPressed()
        }
    }
    
    @objc func cancelButtonPressed() {
        self.cancel?()
    }
    
    @objc func actionButtonPressed() {
        if self.controllerInteraction!.selectedPeers.isEmpty {
            if let defaultAction = self.defaultAction {
                defaultAction.action()
            }
        } else {
            self.inputFieldNode.deactivateInput()
            let transition = ContainedViewLayoutTransition.animated(duration: 0.12, curve: .easeInOut)
            transition.updateAlpha(node: self.actionButtonNode, alpha: 0.0)
            transition.updateAlpha(node: self.inputFieldNode, alpha: 0.0)
            transition.updateAlpha(node: self.actionSeparatorNode, alpha: 0.0)
            transition.updateAlpha(node: self.actionsBackgroundNode, alpha: 0.0)
            
            if let signal = self.share?(self.inputFieldNode.text, self.controllerInteraction!.selectedPeers.map { $0.peerId }) {
                self.transitionToContentNode(ShareLoadingContainerNode(theme: self.presentationData.theme, forceNativeAppearance: true), fastOut: true)
                let timestamp = CACurrentMediaTime()
                var wasDone = false
                let doneImpl: (Bool) -> Void = { [weak self] shouldDelay in
                    let minDelay: Double = shouldDelay ? 0.9 : 0.6
                    let delay = max(minDelay, (timestamp + minDelay) - CACurrentMediaTime())
                    Queue.mainQueue().after(delay, {
                        self?.animateOut(shared: true, completion: {
                            self?.dismiss?(true)
                        })
                    })
                }
                self.shareDisposable.set((signal
                |> deliverOnMainQueue).start(next: { [weak self] status in
                    guard let strongSelf = self, let contentNode = strongSelf.contentNode as? ShareLoadingContainerNode else {
                        return
                    }
                    switch status {
                        case .preparing:
                            contentNode.state = .preparing
                        case let .progress(value):
                            contentNode.state = .progress(value)
                        case .done:
                            contentNode.state = .done
                            if !wasDone {
                                if strongSelf.hapticFeedback == nil {
                                    strongSelf.hapticFeedback = HapticFeedback()
                                }
                                strongSelf.hapticFeedback?.success()
                                
                                wasDone = true
                                doneImpl(true)
                            }
                    }
                }, completed: {
                    if !wasDone {
                        doneImpl(false)
                    }
                }))
            }
        }
    }
    
    func animateIn() {
        if self.contentNode != nil {
            self.isHidden = false
            
            self.dimNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
            
            let offset = self.bounds.size.height - self.contentBackgroundNode.frame.minY
            
            let dimPosition = self.dimNode.layer.position
            self.dimNode.layer.animatePosition(from: CGPoint(x: dimPosition.x, y: dimPosition.y - offset), to: dimPosition, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
            self.layer.animateBoundsOriginYAdditive(from: -offset, to: 0.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, completion: { _ in
            })
        }
    }
    
    func animateOut(shared: Bool, completion: @escaping () -> Void) {
        if self.contentNode != nil {
            var dimCompleted = false
            var offsetCompleted = false
            
            let internalCompletion: () -> Void = { [weak self] in
                if dimCompleted && offsetCompleted {
                    if let strongSelf = self {
                        strongSelf.isHidden = true
                        strongSelf.dimNode.layer.removeAllAnimations()
                        strongSelf.layer.removeAllAnimations()
                    }
                    completion()
                }
            }
            
            self.dimNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { _ in
                dimCompleted = true
                internalCompletion()
            })
            
            let offset = self.bounds.size.height - self.contentBackgroundNode.frame.minY
            let dimPosition = self.dimNode.layer.position
            self.dimNode.layer.animatePosition(from: dimPosition, to: CGPoint(x: dimPosition.x, y: dimPosition.y - offset), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
            self.layer.animateBoundsOriginYAdditive(from: 0.0, to: -offset, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, completion: { _ in
                offsetCompleted = true
                internalCompletion()
            })
        } else {
            completion()
        }
    }
    
    func updatePeers(account: Account, switchableAccounts: [AccountWithInfo], peers: [(RenderedPeer, PeerPresence?)], accountPeer: Peer, defaultAction: ShareControllerAction?) {
        let animated = self.peersContentNode == nil
        let peersContentNode = SharePeersContainerNode(sharedContext: self.sharedContext, account: account, switchableAccounts: switchableAccounts, theme: self.presentationData.theme, strings: self.presentationData.strings, peers: peers, accountPeer: accountPeer, controllerInteraction: self.controllerInteraction!, externalShare: self.externalShare, switchToAnotherAccount: { [weak self] in
            self?.switchToAnotherAccount?()
        })
        self.peersContentNode = peersContentNode
        peersContentNode.openSearch = { [weak self] in
            let _ = (recentlySearchedPeers(postbox: account.postbox)
            |> take(1)
            |> deliverOnMainQueue).start(next: { peers in
                if let strongSelf = self {
                    let searchContentNode = ShareSearchContainerNode(sharedContext: strongSelf.sharedContext, account: account, theme: strongSelf.presentationData.theme, strings: strongSelf.presentationData.strings, controllerInteraction: strongSelf.controllerInteraction!, recentPeers: peers.filter({ $0.peer.peerId.namespace != Namespaces.Peer.SecretChat }).map({ $0.peer }))
                    searchContentNode.cancel = {
                        if let strongSelf = self, let peersContentNode = strongSelf.peersContentNode {
                            strongSelf.transitionToContentNode(peersContentNode)
                        }
                    }
                    strongSelf.transitionToContentNode(searchContentNode)
                }
            })
        }
        let openShare: (Bool) -> Void = { [weak self] reportReady in
            guard let strongSelf = self, let shareExternal = strongSelf.shareExternal else {
                return
            }
            var loadingTimestamp: Double?
            strongSelf.shareDisposable.set((shareExternal() |> deliverOnMainQueue).start(next: { state in
                guard let strongSelf = self else {
                    return
                }
                switch state {
                    case .preparing:
                        if loadingTimestamp == nil {
                            strongSelf.inputFieldNode.deactivateInput()
                            let transition = ContainedViewLayoutTransition.animated(duration: 0.12, curve: .easeInOut)
                            transition.updateAlpha(node: strongSelf.actionButtonNode, alpha: 0.0)
                            transition.updateAlpha(node: strongSelf.inputFieldNode, alpha: 0.0)
                            transition.updateAlpha(node: strongSelf.actionSeparatorNode, alpha: 0.0)
                            transition.updateAlpha(node: strongSelf.actionsBackgroundNode, alpha: 0.0)
                            strongSelf.transitionToContentNode(ShareLoadingContainerNode(theme: strongSelf.presentationData.theme, forceNativeAppearance: true), fastOut: true)
                            loadingTimestamp = CACurrentMediaTime()
                            if reportReady {
                                strongSelf.ready.set(.single(true))
                            }
                        }
                    case .done:
                        if let loadingTimestamp = loadingTimestamp {
                            let minDelay = 0.6
                            let delay = max(0.0, (loadingTimestamp + minDelay) - CACurrentMediaTime())
                            Queue.mainQueue().after(delay, {
                                if let strongSelf = self {
                                    strongSelf.animateOut(shared: true, completion: {
                                        self?.dismiss?(true)
                                    })
                                }
                            })
                        } else {
                            if reportReady {
                                strongSelf.ready.set(.single(true))
                            }
                            strongSelf.animateOut(shared: true, completion: {
                                self?.dismiss?(true)
                            })
                        }
                }
            }))
        }
        peersContentNode.openShare = {
            openShare(false)
        }
        if self.immediateExternalShare {
            openShare(true)
        } else {
            self.transitionToContentNode(peersContentNode, animated: animated)
            self.ready.set(.single(true))
        }
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let result = self.actionButtonNode.hitTest(self.actionButtonNode.convert(point, from: self), with: event) {
            return result
        }
        if self.bounds.contains(point) {
            if !self.contentBackgroundNode.bounds.contains(self.convert(point, to: self.contentBackgroundNode)) && !self.cancelButtonNode.bounds.contains(self.convert(point, to: self.cancelButtonNode)) {
                return self.dimNode.view
            }
        }
        return super.hitTest(point, with: event)
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        let contentOffset = scrollView.contentOffset
        let additionalTopHeight = max(0.0, -contentOffset.y)
        
        if additionalTopHeight >= 30.0 {
            self.cancelButtonPressed()
        }
    }
    
    private func scheduleInteractiveTransition(_ transition: ContainedViewLayoutTransition) {
        if let scheduledLayoutTransitionRequest = self.scheduledLayoutTransitionRequest {
            switch scheduledLayoutTransitionRequest.1 {
                case .immediate:
                    self.scheduleLayoutTransitionRequest(transition)
                default:
                    break
            }
        } else {
            self.scheduleLayoutTransitionRequest(transition)
        }
    }
    
    private func scheduleLayoutTransitionRequest(_ transition: ContainedViewLayoutTransition) {
        let requestId = self.scheduledLayoutTransitionRequestId
        self.scheduledLayoutTransitionRequestId += 1
        self.scheduledLayoutTransitionRequest = (requestId, transition)
        (self.view as? UITracingLayerView)?.schedule(layout: { [weak self] in
            if let strongSelf = self {
                if let (currentRequestId, currentRequestTransition) = strongSelf.scheduledLayoutTransitionRequest, currentRequestId == requestId {
                    strongSelf.scheduledLayoutTransitionRequest = nil
                    strongSelf.requestLayout(currentRequestTransition)
                }
            }
        })
        self.setNeedsLayout()
    }
    
    private func updateButton() {
        if self.controllerInteraction!.selectedPeers.isEmpty {
            if let defaultAction = self.defaultAction {
                self.actionButtonNode.setTitle(defaultAction.title, with: Font.regular(20.0), with: self.presentationData.theme.actionSheet.standardActionTextColor, for: .normal)
                self.actionButtonNode.badge = nil
            } else {
                self.actionButtonNode.setTitle(self.presentationData.strings.ShareMenu_Send, with: Font.medium(20.0), with: self.presentationData.theme.actionSheet.disabledActionTextColor, for: .normal)
            }
        } else {
            self.actionButtonNode.setTitle(self.presentationData.strings.ShareMenu_Send, with: Font.medium(20.0), with: self.presentationData.theme.actionSheet.standardActionTextColor, for: .normal)
            self.actionButtonNode.badge = "\(self.controllerInteraction!.selectedPeers.count)"
        }
    }
    
    func transitionToProgress(signal: Signal<Void, NoError>) {
        self.inputFieldNode.deactivateInput()
        let transition = ContainedViewLayoutTransition.animated(duration: 0.12, curve: .easeInOut)
        transition.updateAlpha(node: self.actionButtonNode, alpha: 0.0)
        transition.updateAlpha(node: self.inputFieldNode, alpha: 0.0)
        transition.updateAlpha(node: self.actionSeparatorNode, alpha: 0.0)
        transition.updateAlpha(node: self.actionsBackgroundNode, alpha: 0.0)
        
        self.transitionToContentNode(ShareLoadingContainerNode(theme: self.presentationData.theme, forceNativeAppearance: true), fastOut: true)
        let timestamp = CACurrentMediaTime()
        self.shareDisposable.set(signal.start(completed: { [weak self] in
            let minDelay = 0.6
            let delay = max(0.0, (timestamp + minDelay) - CACurrentMediaTime())
            Queue.mainQueue().after(delay, {
                if let strongSelf = self {
                    strongSelf.animateOut(shared: true, completion: {
                        self?.dismiss?(true)
                    })
                }
            })
        }))
    }
    
    func transitionToProgressWithValue(signal: Signal<Float?, NoError>) {
        self.inputFieldNode.deactivateInput()
        let transition = ContainedViewLayoutTransition.animated(duration: 0.12, curve: .easeInOut)
        transition.updateAlpha(node: self.actionButtonNode, alpha: 0.0)
        transition.updateAlpha(node: self.inputFieldNode, alpha: 0.0)
        transition.updateAlpha(node: self.actionSeparatorNode, alpha: 0.0)
        transition.updateAlpha(node: self.actionsBackgroundNode, alpha: 0.0)
        
        self.transitionToContentNode(ShareLoadingContainerNode(theme: self.presentationData.theme, forceNativeAppearance: true), fastOut: true)
        
        let timestamp = CACurrentMediaTime()
        var wasDone = false
        let doneImpl: (Bool) -> Void = { [weak self] shouldDelay in
            let minDelay: Double = shouldDelay ? 0.9 : 0.6
            let delay = max(minDelay, (timestamp + minDelay) - CACurrentMediaTime())
            Queue.mainQueue().after(delay, {
                if let strongSelf = self {
                    strongSelf.animateOut(shared: true, completion: {
                        self?.dismiss?(true)
                    })
                }
            })
        }
        self.shareDisposable.set((signal
        |> deliverOnMainQueue).start(next: { [weak self] status in
            guard let strongSelf = self, let contentNode = strongSelf.contentNode as? ShareLoadingContainerNode else {
                return
            }
            if let status = status {
                contentNode.state = .progress(status)
            } else {
                
            }
        }, completed: { [weak self] in
            guard let strongSelf = self, let contentNode = strongSelf.contentNode as? ShareLoadingContainerNode else {
                return
            }
            contentNode.state = .done
            if !wasDone {
                wasDone = true
                doneImpl(true)
            }
        }))
    }
}
