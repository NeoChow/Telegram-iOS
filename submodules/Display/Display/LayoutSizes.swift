import Foundation
import UIKit

public func horizontalContainerFillingSizeForLayout(layout: ContainerViewLayout, sideInset: CGFloat) -> CGFloat {
    if case .regular = layout.metrics.widthClass {
        return min(layout.size.width, 414.0) - sideInset * 2.0
    } else {
        return layout.size.width - sideInset * 2.0
    }
}
