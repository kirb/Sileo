//
//  DepictionTableButtonView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 Sileo Team. All rights reserved.
//

import Foundation

class DepictionTableButtonView: DepictionBaseView, UIGestureRecognizerDelegate {
    private var button: UIButton
    private var chevronView: UIImageView
    private var repoIcon: UIImageView?

    private var action: String
    private var backupAction: String

    private let openExternal: Bool

    required init?(dictionary: [String: Any], viewController: UIViewController, tintColor: UIColor, isActionable: Bool) {
        guard let title = dictionary["title"] as? String else {
            return nil
        }

        guard let action = dictionary["action"] as? String else {
            return nil
        }

        button = UIButton(type: .custom)
        chevronView = UIImageView(image: UIImage(named: "Chevron")?.withRenderingMode(.alwaysTemplate))

        self.action = action
        backupAction = (dictionary["backupAction"] as? String) ?? ""

        openExternal = (dictionary["openExternal"] as? Bool) ?? false

        super.init(dictionary: dictionary, viewController: viewController, tintColor: tintColor, isActionable: isActionable)

        button.setTitle(title, for: .normal)
        button.titleLabel!.font = UIFont.systemFont(ofSize: 17)
        button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: #selector(self.buttonTapped), for: .touchUpInside)
        self.addSubview(button)

        self.addSubview(chevronView)

        if let repo = dictionary["_repo"] as? String {
            repoIcon = UIImageView(frame: .zero)
            repoIcon?.layer.masksToBounds = true
            repoIcon?.layer.cornerRadius = 7.5
            loadRepoImage(repo)
            self.addSubview(repoIcon!)
        }

        updateHighlight()
    }
    
    private func loadRepoImage(_ repo: String) {
        guard let url = URL(string: repo) else { return }
        if url.host == "apt.thebigboss.org" {
            self.repoIcon?.image = UIImage(named: "BigBoss")
            return
        }
        let scale = Int(UIScreen.main.scale)
        for i in (1...scale).reversed() {
            let filename = i == 1 ? CommandPath.RepoIcon : "\(CommandPath.RepoIcon)@\(i)x"
            if let iconURL = URL(string: repo)?
                .appendingPathComponent(filename)
                .appendingPathExtension("png") {
                let cache = AmyNetworkResolver.shared.imageCache(iconURL, scale: CGFloat(i))
                if let image = cache.1 {
                    repoIcon?.image = image
                    return
                }
            }
        }
        repoIcon?.image = UIImage(named: "Repo Icon")
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func depictionHeight(width: CGFloat) -> CGFloat {
        44
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        button.setTitleColor(self.tintColor, for: .normal)
        chevronView.tintColor = self.tintColor

        button.frame = self.bounds.insetBy(dx: 0, dy: -2)

        if let repoIcon = repoIcon {
            repoIcon.frame = CGRect(x: 16, y: 4.5, width: 35, height: 35)
            button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 16 + 40, bottom: 0, right: 44)
        } else {
            button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 44)
        }
        chevronView.frame = CGRect(x: self.bounds.size.width - 16 - 9, y: 15, width: 7, height: 13)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateHighlight()
    }

    @objc func buttonTapped(_ sender: UIButton?) {
        if !self.processAction(action) {
            self.processAction(backupAction)
        }
    }

    @discardableResult func processAction(_ action: String) -> Bool {
        if action.isEmpty {
            return false
        }
        return DepictionButton.processAction(action, parentViewController: self.parentViewController, openExternal: openExternal)
    }

    private func updateHighlight() {
        let highlightImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.sileoHighlightColor.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        button.setBackgroundImage(highlightImage, for: .highlighted)
    }
}
