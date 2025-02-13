import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData

private func generateClearIcon(color: UIColor) -> UIImage? {
    return generateTintedImage(image: UIImage(bundleImageName: "Components/Search Bar/Clear"), color: color)
}

final class ShareInputFieldNodeTheme: Equatable {
    let backgroundColor: UIColor
    let textColor: UIColor
    let placeholderColor: UIColor
    let clearButtonColor: UIColor
    let keyboard: PresentationThemeKeyboardColor
    
    public init(backgroundColor: UIColor, textColor: UIColor, placeholderColor: UIColor, clearButtonColor: UIColor, keyboard: PresentationThemeKeyboardColor) {
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.placeholderColor = placeholderColor
        self.clearButtonColor = clearButtonColor
        self.keyboard = keyboard
    }
    
    public static func ==(lhs: ShareInputFieldNodeTheme, rhs: ShareInputFieldNodeTheme) -> Bool {
        if lhs.backgroundColor != rhs.backgroundColor {
            return false
        }
        if lhs.textColor != rhs.textColor {
            return false
        }
        if lhs.placeholderColor != rhs.placeholderColor {
            return false
        }
        if lhs.clearButtonColor != rhs.clearButtonColor {
            return false
        }
        if lhs.keyboard != rhs.keyboard {
            return false
        }
        return true
    }
}

extension ShareInputFieldNodeTheme {
    convenience init(presentationTheme theme: PresentationTheme) {
        self.init(backgroundColor: theme.actionSheet.inputBackgroundColor, textColor: theme.actionSheet.inputTextColor, placeholderColor: theme.actionSheet.inputPlaceholderColor, clearButtonColor: theme.actionSheet.inputClearButtonColor, keyboard: theme.chatList.searchBarKeyboardColor)
    }
}

final class ShareInputFieldNode: ASDisplayNode, ASEditableTextNodeDelegate {
    private let theme: ShareInputFieldNodeTheme
    private let backgroundNode: ASImageNode
    private let textInputNode: EditableTextNode
    private let placeholderNode: ASTextNode
    private let clearButton: HighlightableButtonNode
    
    var updateHeight: (() -> Void)?
    
    private let backgroundInsets = UIEdgeInsets(top: 16.0, left: 16.0, bottom: 1.0, right: 16.0)
    private let inputInsets = UIEdgeInsets(top: 10.0, left: 8.0, bottom: 10.0, right: 16.0)
    private let accessoryButtonsWidth: CGFloat = 10.0
    
    var text: String {
        get {
            return self.textInputNode.attributedText?.string ?? ""
        }
        set {
            self.textInputNode.attributedText = NSAttributedString(string: newValue, font: Font.regular(17.0), textColor: self.theme.textColor)
            self.placeholderNode.isHidden = !newValue.isEmpty
            self.clearButton.isHidden = newValue.isEmpty
        }
    }
    
    var placeholder: String = "" {
        didSet {
            self.placeholderNode.attributedText = NSAttributedString(string: self.placeholder, font: Font.regular(17.0), textColor: self.theme.placeholderColor)
        }
    }
    
    init(theme: ShareInputFieldNodeTheme, placeholder: String) {
        self.theme = theme
        
        self.backgroundNode = ASImageNode()
        self.backgroundNode.isLayerBacked = true
        self.backgroundNode.displaysAsynchronously = false
        self.backgroundNode.displayWithoutProcessing = true
        self.backgroundNode.image = generateStretchableFilledCircleImage(diameter: 16.0, color: theme.backgroundColor)
        
        self.textInputNode = EditableTextNode()
        let textColor: UIColor = theme.textColor
        self.textInputNode.typingAttributes = [NSAttributedStringKey.font.rawValue: Font.regular(17.0), NSAttributedStringKey.foregroundColor.rawValue: textColor]
        self.textInputNode.clipsToBounds = true
        self.textInputNode.hitTestSlop = UIEdgeInsets(top: -5.0, left: -5.0, bottom: -5.0, right: -5.0)
        self.textInputNode.textContainerInset = UIEdgeInsets(top: self.inputInsets.top, left: 0.0, bottom: self.inputInsets.bottom, right: 0.0)
        self.textInputNode.keyboardAppearance = theme.keyboard.keyboardAppearance
        
        self.placeholderNode = ASTextNode()
        self.placeholderNode.isUserInteractionEnabled = false
        self.placeholderNode.displaysAsynchronously = false
        self.placeholderNode.attributedText = NSAttributedString(string: placeholder, font: Font.regular(17.0), textColor: theme.placeholderColor)
        
        self.clearButton = HighlightableButtonNode()
        self.clearButton.imageNode.displaysAsynchronously = false
        self.clearButton.imageNode.displayWithoutProcessing = true
        self.clearButton.displaysAsynchronously = false
        self.clearButton.setImage(generateClearIcon(color: theme.clearButtonColor), for: [])
        self.clearButton.isHidden = true
        
        super.init()
        
        self.textInputNode.delegate = self
        
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.textInputNode)
        self.addSubnode(self.placeholderNode)
        self.addSubnode(self.clearButton)
        
        self.clearButton.addTarget(self, action: #selector(self.clearPressed), forControlEvents: .touchUpInside)
    }
    
    func updateLayout(width: CGFloat, transition: ContainedViewLayoutTransition) -> CGFloat {
        let backgroundInsets = self.backgroundInsets
        let inputInsets = self.inputInsets
        let accessoryButtonsWidth = self.accessoryButtonsWidth
        
        let textFieldHeight = self.calculateTextFieldMetrics(width: width)
        let panelHeight = textFieldHeight + backgroundInsets.top + backgroundInsets.bottom
        
        let backgroundFrame = CGRect(origin: CGPoint(x: backgroundInsets.left, y: backgroundInsets.top), size: CGSize(width: width - backgroundInsets.left - backgroundInsets.right, height: panelHeight - backgroundInsets.top - backgroundInsets.bottom))
        transition.updateFrame(node: self.backgroundNode, frame: backgroundFrame)
        
        let placeholderSize = self.placeholderNode.measure(backgroundFrame.size)
        transition.updateFrame(node: self.placeholderNode, frame: CGRect(origin: CGPoint(x: backgroundFrame.minX + floor((backgroundFrame.size.width - placeholderSize.width) / 2.0), y: backgroundFrame.minY + floor((backgroundFrame.size.height - placeholderSize.height) / 2.0)), size: placeholderSize))
        
        if let image = self.clearButton.image(for: []) {
            transition.updateFrame(node: self.clearButton, frame: CGRect(origin: CGPoint(x: backgroundFrame.maxX - 8.0 - image.size.width, y: backgroundFrame.minY + floor((backgroundFrame.size.height - image.size.height) / 2.0)), size: image.size))
        }
        
        transition.updateFrame(node: self.textInputNode, frame: CGRect(origin: CGPoint(x: backgroundFrame.minX + inputInsets.left, y: backgroundFrame.minY), size: CGSize(width: backgroundFrame.size.width - inputInsets.left - inputInsets.right - accessoryButtonsWidth, height: backgroundFrame.size.height)))
        
        return panelHeight
    }
    
    func activateInput() {
        self.textInputNode.becomeFirstResponder()
    }
    
    func deactivateInput() {
        self.textInputNode.resignFirstResponder()
    }
    
    @objc func editableTextNodeDidUpdateText(_ editableTextNode: ASEditableTextNode) {
        self.updateTextNodeText(animated: true)
    }
    
    func editableTextNodeDidBeginEditing(_ editableTextNode: ASEditableTextNode) {
        self.placeholderNode.isHidden = true
        self.clearButton.isHidden = false
    }
    
    func editableTextNodeDidFinishEditing(_ editableTextNode: ASEditableTextNode) {
        self.placeholderNode.isHidden = !(editableTextNode.textView.text ?? "").isEmpty
        self.clearButton.isHidden = true
    }
    
    private func calculateTextFieldMetrics(width: CGFloat) -> CGFloat {
        let backgroundInsets = self.backgroundInsets
        let inputInsets = self.inputInsets
        let accessoryButtonsWidth = self.accessoryButtonsWidth
        
        let unboundTextFieldHeight = max(33.0, ceil(self.textInputNode.measure(CGSize(width: width - backgroundInsets.left - backgroundInsets.right - inputInsets.left - inputInsets.right - accessoryButtonsWidth, height: CGFloat.greatestFiniteMagnitude)).height))
        
        return min(61.0, max(41.0, unboundTextFieldHeight))
    }
    
    private func updateTextNodeText(animated: Bool) {
        let backgroundInsets = self.backgroundInsets
        
        let textFieldHeight = self.calculateTextFieldMetrics(width: self.bounds.size.width)
        
        let panelHeight = textFieldHeight + backgroundInsets.top + backgroundInsets.bottom
        if !self.bounds.size.height.isEqual(to: panelHeight) {
            self.updateHeight?()
        }
    }
    
    @objc func clearPressed() {
        self.textInputNode.attributedText = nil
        self.deactivateInput()
    }
}
