//
//  DepictionMarkdownView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 Sileo Team. All rights reserved.
//

import Foundation
import WebKit

extension NSAttributedString.DocumentReadingOptionKey {
    // Defined in AppKit on macOS, but no equivalent export exists on iOS, despite being mentioned
    // in <WebKit/NSAttributedString.h>.
    static let timeout = Self(rawValue: "Timeout")
}

class DepictionMarkdownViewSlow: DepictionBaseView, CSTextViewActionHandler {
    var attributedString: NSAttributedString?
    var htmlString: String = ""

    let useSpacing: Bool
    let useMargins: Bool

    let heightRequested: Bool

    let textView: CSTextView

    required init?(dictionary: [String: Any], viewController: UIViewController, tintColor: UIColor, isActionable: Bool) {
        guard let markdown = dictionary["markdown"] as? String else {
            return nil
        }
        
        useSpacing = (dictionary["useSpacing"] as? Bool) ?? true
        useMargins = (dictionary["useMargins"] as? Bool) ?? true

        heightRequested = false

        textView = CSTextView(frame: .zero)
        super.init(dictionary: dictionary, viewController: viewController, tintColor: tintColor, isActionable: isActionable)

        textView.backgroundColor = .clear
        addSubview(textView)

        htmlString = markdown

        reloadMarkdown()

        textView.translatesAutoresizingMaskIntoConstraints = false

        let margins: CGFloat = useMargins ? 16 : 0
        let spacing: CGFloat = useSpacing ? 13 : 0
        let bottomSpacing: CGFloat = useSpacing ? 13 : 0
        NSLayoutConstraint.activate([
            textView.leftAnchor.constraint(equalTo: self.leftAnchor, constant: margins),
            textView.rightAnchor.constraint(equalTo: self.rightAnchor, constant: -margins),
            textView.topAnchor.constraint(equalTo: self.topAnchor, constant: spacing),
            textView.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -bottomSpacing)
        ])
        
        weak var weakSelf = self
        NotificationCenter.default.addObserver(weakSelf as Any,
                                               selector: #selector(reloadMarkdown),
                                               name: SileoThemeManager.sileoChangedThemeNotification,
                                               object: nil)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        if #available(iOS 13, *) {
            if !UIColor.isTransitionLockedForiOS13Bug {
                self.reloadMarkdown()
            }
        }
    }
    
    @objc func reloadMarkdown() {
        let htmlString = """
        <html>
        <style>
        body {
            font: -apple-system-body;
            color: \(UIColor.sileoLabel.cssString);
            -webkit-text-size-adjust: none;
        }
        a {
            text-decoration: none;
            color: \(tintColor.cssString);
        }
        </style>
        <body>\(self.htmlString)</body>
        </html>
        """

        let attributedStringCompletion: (NSAttributedString) -> Void = { attributedString in
            self.textView.attributedText = attributedString
            self.attributedString = attributedString
            self.textView.setNeedsDisplay()
        }

        if #available(iOS 13, *) {
            NSAttributedString.loadFromHTML(string: htmlString, options: [
                .characterEncoding: String.Encoding.utf8,
                .timeout: 1
            ]) { attributedString, _, error in
                guard let attributedString = attributedString else {
                    if let error = error {
                        NSLog("Failed to load HTML: %@", error as NSError)
                    }
                    return
                }
                attributedStringCompletion(attributedString)
                self.setNeedsLayout()
            }
        } else {
            // swiftlint:disable:next line_length
            if let attributedString = try? NSMutableAttributedString(data: htmlString.data(using: .unicode) ?? "".data(using: .utf8)!, options: [NSAttributedString.DocumentReadingOptionKey.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil) {
                // swiftlint:disable:next line_length
                attributedString.removeAttribute(NSAttributedString.Key("NSOriginalFont"), range: NSRange(location: 0, length: attributedString.length))
                attributedStringCompletion(attributedString)
            }
        }
    }

    override func depictionHeight(width: CGFloat) -> CGFloat {
        let margins: CGFloat = useMargins ? 32 : 0
        let spacing: CGFloat = useSpacing ? 33 : 0

        guard let attributedString = attributedString else {
            return 0
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        let targetSize = CGSize(width: width - margins, height: CGFloat.greatestFiniteMagnitude)
        let fitSize = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRangeMake(0, attributedString.length), nil, targetSize, nil)
        return fitSize.height + spacing
    }

    func process(action: String) -> Bool {
        DepictionButton.processAction(action, parentViewController: self.parentViewController, openExternal: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.updateConstraintsIfNeeded()
    }
}
