import Foundation
import UIKit
import Display
import AsyncDisplayKit
import Postbox
import SwiftSignalKit
import TelegramCore
import MessageUI
import TelegramPresentationData

public class InviteContactsController: ViewController, MFMessageComposeViewControllerDelegate, UINavigationControllerDelegate {
    private let context: AccountContext
    
    private var contactsNode: InviteContactsControllerNode {
        return self.displayNode as! InviteContactsControllerNode
    }
    
    private var _ready = Promise<Bool>()
    override public var ready: Promise<Bool> {
        return self._ready
    }
    
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    
    private var composer: MFMessageComposeViewController?
    
    private var searchContentNode: NavigationBarSearchContentNode?
    
    public init(context: AccountContext) {
        self.context = context
        
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBar.style.style
        
        self.title = self.presentationData.strings.Contacts_InviteFriends
        
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: presentationData.strings.Contacts_SelectAll, style: .plain, target: self, action: #selector(self.selectAllPressed))
        
        self.scrollToTop = { [weak self] in
            if let strongSelf = self {
                if let searchContentNode = strongSelf.searchContentNode {
                    searchContentNode.updateExpansionProgress(1.0, animated: true)
                }
                strongSelf.contactsNode.scrollToTop()
            }
        }
        
        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            if let strongSelf = self {
                let previousTheme = strongSelf.presentationData.theme
                let previousStrings = strongSelf.presentationData.strings
                
                strongSelf.presentationData = presentationData
                
                if previousTheme !== presentationData.theme || previousStrings !== presentationData.strings {
                    strongSelf.updateThemeAndStrings()
                }
            }
        })
        
        self.searchContentNode = NavigationBarSearchContentNode(theme: self.presentationData.theme, placeholder: self.presentationData.strings.Common_Search, activate: { [weak self] in
            self?.activateSearch()
        })
        self.navigationBar?.setContentNode(self.searchContentNode, animated: false)
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.presentationDataDisposable?.dispose()
    }
    
    private func updateThemeAndStrings() {
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBar.style.style
        self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: self.presentationData))
        self.searchContentNode?.updateThemeAndPlaceholder(theme: self.presentationData.theme, placeholder: self.presentationData.strings.Common_Search)
        self.title = self.presentationData.strings.Contacts_InviteFriends
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
    }
    
    override public func loadDisplayNode() {
        self.displayNode = InviteContactsControllerNode(context: self.context)
        self._ready.set(self.contactsNode.ready)
        
        self.contactsNode.navigationBar = self.navigationBar
        
        self.contactsNode.requestDeactivateSearch = { [weak self] in
            self?.deactivateSearch()
        }
        
        self.contactsNode.requestActivateSearch = { [weak self] in
            self?.activateSearch()
        }
        
        self.contactsNode.requestShareTelegram = { [weak self] in
            if let strongSelf = self {
                let url = strongSelf.presentationData.strings.InviteText_URL
                let body = strongSelf.presentationData.strings.InviteText_SingleContact(url).0
                
                let shareController = ShareController(context: strongSelf.context, subject: .text(body), externalShare: true, immediateExternalShare: true)
                strongSelf.present(shareController, in: .window(.root))
                
                strongSelf.contactsNode.listNode.clearHighlightAnimated(true)
            }
        }
        
        self.contactsNode.requestShare = { [weak self] numbers in
            let recipients: [String] = Array(numbers.map {
                return $0.0.phoneNumbers.map { $0.value }
            }.joined())
            
            let f: () -> Void = {
                if let strongSelf = self, MFMessageComposeViewController.canSendText() {
                    let composer = MFMessageComposeViewController()
                    composer.messageComposeDelegate = strongSelf
                    composer.recipients = Array(Set(recipients))
                    let url = strongSelf.presentationData.strings.InviteText_URL
                    var body = strongSelf.presentationData.strings.InviteText_SingleContact(url).0
                    if numbers.count == 1, numbers[0].1 > 0 {
                        body = strongSelf.presentationData.strings.InviteText_ContactsCountText(numbers[0].1)
                        body = body.replacingOccurrences(of: "{url}", with: url)
                    }
                    composer.body = body
                    strongSelf.composer = composer
                    if let window = strongSelf.view.window {
                        window.rootViewController?.present(composer, animated: true)
                    }
                }
            }
            
            if recipients.count < 100 {
                f()
            } else if let strongSelf = self {
                strongSelf.present(textAlertController(context: strongSelf.context, title: nil, text: strongSelf.presentationData.strings.Invite_LargeRecipientsCountWarning, actions: [TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {}), TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: f)]), in: .window(.root))
            }
        }
        
        self.contactsNode.listNode.visibleContentOffsetChanged = { [weak self] offset in
            if let strongSelf = self, let searchContentNode = strongSelf.searchContentNode {
                searchContentNode.updateListVisibleContentOffset(offset)
            }
        }
        
        self.contactsNode.listNode.didEndScrolling = { [weak self] in
            if let strongSelf = self, let searchContentNode = strongSelf.searchContentNode {
                let _ = fixNavigationSearchableListNodeScrolling(strongSelf.contactsNode.listNode, searchNode: searchContentNode)
            }
        }
        
        self.displayNodeDidLoad()
    }
    
    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.contactsNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationInsetHeight, actualNavigationBarHeight: self.navigationHeight, transition: transition)
    }
    
    private func activateSearch() {
        if self.displayNavigationBar {
            if let scrollToTop = self.scrollToTop {
                scrollToTop()
            }
            if let searchContentNode = self.searchContentNode {
                self.contactsNode.activateSearch(placeholderNode: searchContentNode.placeholderNode)
            }
            self.setDisplayNavigationBar(false, transition: .animated(duration: 0.5, curve: .spring))
        }
    }
    
    private func deactivateSearch() {
        if !self.displayNavigationBar {
            self.setDisplayNavigationBar(true, transition: .animated(duration: 0.5, curve: .spring))
            if let searchContentNode = self.searchContentNode {
                self.contactsNode.deactivateSearch(placeholderNode: searchContentNode.placeholderNode)
            }
        }
    }
    
    @objc func selectAllPressed() {
        self.contactsNode.selectAll()
    }
    
    @objc public func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        self.composer = nil
        
        controller.dismiss(animated: true, completion: nil)
        
        guard case .sent = result else {
            return
        }
        
        self.contactsNode.selectionState = self.contactsNode.selectionState.withClearedSelection()
    }
}

