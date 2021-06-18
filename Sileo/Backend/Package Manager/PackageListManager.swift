//
//  PublicListManager.swift
//  Sileo
//
//  Created by CoolStar on 7/3/19.
//  Copyright © 2019 Sileo Team. All rights reserved.
//

import Foundation
import CoreSpotlight

final class PackageListManager {
    static let reloadNotification = Notification.Name("SileoPackageCacheReloaded")
    static let prefsNotification = Notification.Name("SileoPackagePrefsChanged")
    static let didUpdateNotification = Notification.Name("SileoDatabaseDidUpdateNotification")
    
    private(set) var installedPackages: [String: Package] {
        didSet {
            NotificationCenter.default.post(name: RepoManager.progressNotification, object: installedPackages.count)
        }
    }
    
    private let initSemphaore = DispatchSemaphore(value: 0)
    private var isLoaded = false
    
    public var allPackagesArray: [Package] {
        var packages = [Package]()
        var installedPackages = installedPackages
        for repo in RepoManager.shared.repoList {
            let repoPackageArray = repo.packageArray
            packages += repo.packageArray
            for package in repoPackageArray where installedPackages[package.packageID] != nil {
                installedPackages.removeValue(forKey: package.packageID)
            }
        }
        return packages + Array(installedPackages.values)
    }

    private var databaseUpdateQueue = DispatchQueue(label: "org.coolstar.SileoStore.database-queue")
    public static let shared = PackageListManager()
    
    init() {
        self.installedPackages = PackageListManager.readPackages(installed: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let repoMan = RepoManager.shared
            var repoList = repoMan.repoList
            let threadCount = ((ProcessInfo.processInfo.processorCount * 2) > repoList.count) ? repoList.count : (ProcessInfo.processInfo.processorCount * 2)
            let loadGroup = DispatchGroup()
            let loadLock = NSLock()
            let updateLock = NSLock()
            var loadedRepoList = [Repo]()
            
            for threadID in 0..<(threadCount) {
                loadGroup.enter()
                let repoQueue = DispatchQueue(label: "repo-init-queue-\(threadID)")
                repoQueue.async {
                    while true {
                        loadLock.lock()
                        guard !repoList.isEmpty else {
                            loadLock.unlock()
                            break
                        }
                        let repo = repoList.removeFirst()
                        loadLock.unlock()
                        repo.packageDict = PackageListManager.readPackages(repoContext: repo)
                        
                        updateLock.lock()
                        loadedRepoList.append(repo)
                        updateLock.unlock()
                    }
                    loadGroup.leave()
                }
            }
            repoMan.update(loadedRepoList)
            loadGroup.notify(queue: .main) {
                self.isLoaded = true
                self.initSemphaore.signal()
                NotificationCenter.default.post(name: PackageListManager.reloadNotification, object: nil)
                #if targetEnvironment(simulator)
                if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                    return
                }
                #endif
                if UserDefaults.standard.optionalBool("AutoRefreshSources", fallback: true) {
                    // Start a background repo refresh here instead because it doesn't like it in the Source View Controller
                    if let tabBarController = UIApplication.shared.windows.first?.rootViewController as? UITabBarController,
                       let sourcesSVC = tabBarController.viewControllers?[2] as? UISplitViewController,
                       let sourcesNavNV = sourcesSVC.viewControllers[0] as? SileoNavigationController,
                       let sourcesVC = sourcesNavNV.viewControllers[0] as? SourcesViewController {
                        sourcesVC.refreshSources(forceUpdate: false, forceReload: false, isBackground: true, useRefreshControl: false, useErrorScreen: false, completion: nil)
                    }
                }
            }
        }
    }
    
    public func initWait() {
        if isLoaded { return }
        initSemphaore.wait()
    }
    
    public func installChange() {
        installedPackages = PackageListManager.readPackages(installed: true)
        for repo in RepoManager.shared.repoList {
            repo.reloadInstalled()
        }
        DependencyResolverAccelerator.shared.preflightInstalled()
    }

    public func availableUpdates() -> [(Package, Package?)] {
        var updatesAvailable: [(Package, Package?)] = []
        for package in installedPackages.values {
            guard let latestPackage = self.newestPackage(identifier: package.packageID, repoContext: nil) else {
                continue
            }
            if latestPackage.version != package.version {
                if DpkgWrapper.isVersion(latestPackage.version, greaterThan: package.version) {
                    updatesAvailable.append((latestPackage, package))
                }
            }
        }
        return updatesAvailable
    }

    public class func humanReadableCategory(_ rawCategory: String?) -> String {
        let category = rawCategory ?? ""
        if category.isEmpty {
            return String(localizationKey: "No_Category", type: .categories)
        }
        return String(localizationKey: category, type: .categories)
    }
    
    class func package(packageEnum: ([String: String], PackageTags)) -> Package? {
        let dictionary = packageEnum.0
        guard let packageID = dictionary["package"] else {
            return nil
        }
        guard let packageVersion = dictionary["version"] else {
            return nil
        }
        
        let package = Package(package: packageID, version: packageVersion)
        package.name = dictionary["name"]
        if package.name == nil {
            package.name = package.package
        }
        package.icon = dictionary["icon"]
        package.architecture = dictionary["architecture"]
        package.maintainer = dictionary["maintainer"]
        if package.maintainer != nil {
            if dictionary["author"] != nil {
                package.author = dictionary["author"]
            } else {
                package.author = dictionary["maintainer"]
            }
        }
        package.section = humanReadableCategory(dictionary["section"])
        
        package.packageDescription = dictionary["description"]
        package.legacyDepiction = dictionary["depiction"]
        package.depiction = dictionary["sileodepiction"]
        package.support = dictionary["support"]
        
        package.tags = packageEnum.1
        if package.tags.contains(.commercial) {
            package.commercial = true
        }
        
        package.filename = dictionary["filename"]
        package.essential = dictionary["essential"]
        package.size = dictionary["size"]
        
        package.rawControl = dictionary
        return package
    }

    public class func readPackages(repoContext: Repo? = nil, packagesFile: URL? = nil, installed: Bool = false) -> [String: Package] {
        var tmpPackagesFile: URL?
        var toWrite: URL?
        var dict = [String: Package]()
        if installed {
            tmpPackagesFile = CommandPath.dpkgDir.appendingPathComponent("status").resolvingSymlinksInPath()
            toWrite = tmpPackagesFile
        } else if let override = packagesFile {
            tmpPackagesFile = override
            if let repo = repoContext {
                toWrite = RepoManager.shared.cacheFile(named: "Packages", for: repo)
            } else {
                toWrite = override
            }
        } else if let repo = repoContext {
            tmpPackagesFile = RepoManager.shared.cacheFile(named: "Packages", for: repo)
            toWrite = RepoManager.shared.cacheFile(named: "Packages", for: repo)
        }
        guard let packagesFile = tmpPackagesFile,
              let rawPackagesData = try? Data(contentsOf: packagesFile.aptUrl) else { return dict }

        var index = 0
        var separator = "\n\n".data(using: .utf8)!
        
        guard let firstSeparator = rawPackagesData.range(of: "\n".data(using: .utf8)!, options: [], in: 0..<rawPackagesData.count) else {
            return dict
        }
        if firstSeparator.lowerBound != 0 {
            let subdata = rawPackagesData.subdata(in: firstSeparator.lowerBound-1..<firstSeparator.lowerBound)
            let character = subdata.first
            if character == 13 { // 13 means carriage return (\r, Windows line ending)
                separator = "\r\n\r\n".data(using: .utf8)!
            }
        }
        
        let isStatusFile = packagesFile.absoluteString.hasSuffix("status")
        while index < rawPackagesData.count {
            let range = rawPackagesData.range(of: separator, options: [], in: index..<rawPackagesData.count)
            var newIndex = 0
            if range == nil {
                newIndex = rawPackagesData.count
            } else {
                newIndex = range!.lowerBound + separator.count
            }
            
            let subRange = index..<newIndex
            let packageData = rawPackagesData.subdata(in: subRange)
            
            index = newIndex
            
            guard let rawPackageEnum = try? ControlFileParser.dictionary(controlData: packageData, isReleaseFile: false) else {
                continue
            }
            let rawPackage = rawPackageEnum.0
            guard let packageID = rawPackage["package"] else {
                continue
            }
            if packageID.isEmpty {
                continue
            }
            if packageID.hasPrefix("gsc.") {
                continue
            }
            if packageID.hasPrefix("cy+") {
                continue
            }
            if packageID == "firmware" {
                continue
            }
            
            guard let package = self.package(packageEnum: rawPackageEnum) else {
                continue
            }
            package.sourceFile = repoContext?.rawEntry
            package.sourceFileURL = toWrite
            package.rawData = packageData
            
            if isStatusFile {
                var wantInfo: pkgwant = .install
                var eFlag: pkgeflag = .ok
                var pkgStatus: pkgstatus = .installed
            
                let statusValid = DpkgWrapper.getValues(statusField: package.rawControl["status"],
                                                        wantInfo: &wantInfo,
                                                        eFlag: &eFlag,
                                                        pkgStatus: &pkgStatus)
                if !statusValid {
                    continue
                }
            
                package.wantInfo = wantInfo
                package.eFlag = eFlag
                package.status = pkgStatus
            
                if package.eFlag == .ok {
                    if package.status == .notinstalled || package.status == .configfiles {
                        continue
                    }
                }
                dict[package.packageID] = package
            } else {
                if let otherPkg = dict[packageID] {
                    if DpkgWrapper.isVersion(package.version, greaterThan: otherPkg.version) {
                        package.addOld([otherPkg])
                        dict[packageID] = package
                    }
                    otherPkg.addOldInternal(Array(package.allVersionsInternal.values))
                    package.allVersionsInternal = otherPkg.allVersionsInternal
                } else {
                    dict[packageID] = package
                }
            }
        }
        return dict
    }
    
    public func packageList(identifier: String = "", search: String? = nil, sortPackages sort: Bool = false, repoContext: Repo? = nil, lookupTable: [String: [Package]]? = nil) -> [Package] {
        var packageList = [Package]()
        if identifier == "--installed" {
            packageList = Array(installedPackages.values)
        } else if identifier == "--wishlist" {
            packageList = packages(identifiers: WishListManager.shared.wishlist, sorted: sort)
        } else {
            if var search = search?.lowercased(),
               let lookupTable = lookupTable {
                var isFound = false
                while !search.isEmpty && !isFound {
                    if let packages = lookupTable[search] {
                        packageList = packages
                        isFound = true
                    } else {
                        search.removeLast()
                    }
                }
                if !isFound {
                    packageList = repoContext?.packageArray ?? allPackagesArray
                }
            } else {
                packageList = repoContext?.packageArray ?? allPackagesArray
            }
        }
        if identifier.hasPrefix("category:") {
            let index = identifier.index(identifier.startIndex, offsetBy: 9)
            let category = PackageListManager.humanReadableCategory(String(identifier[index...]))
            packageList = packageList.filter({ $0.section == category })
        } else if identifier.hasPrefix("author:") {
            let index = identifier.index(identifier.startIndex, offsetBy: 7)
            let authorEmail = String(identifier[index...]).lowercased()
            packageList = packageList.filter {
                guard let lowercaseAuthor = $0.author?.lowercased() else {
                    return true
                }
                return ControlFileParser.authorEmail(string: lowercaseAuthor) == authorEmail.lowercased()
            }
        }
        if let searchQuery = search,
           !searchQuery.isEmpty {
            let search = searchQuery.lowercased()
            packageList.removeAll { package in
                var shouldRemove = true
                if package.package.lowercased().contains(search) { shouldRemove = false }
                if let name = package.name?.lowercased() {
                    if !name.isEmpty {
                        if name.contains(search) { shouldRemove = false }
                    }
                }
                if let description = package.packageDescription?.lowercased() {
                    if !description.isEmpty {
                        if description.contains(search) { shouldRemove = false }
                    }
                }
                if let author = package.author?.lowercased() {
                    if !author.isEmpty {
                        if author.contains(search) { shouldRemove = false }
                    }
                }
                if let maintainer = package.maintainer?.lowercased() {
                    if !maintainer.isEmpty {
                        if maintainer.contains(search) { shouldRemove = false }
                    }
                }
                return shouldRemove
            }
        }
        if sort {
            packageList = sortPackages(packages: packageList, search: search)
        }
        return packageList
    }
    
    public func sortPackages(packages: [Package], search: String?) -> [Package] {
        var tmp = packages
        tmp.sort { obj1, obj2 -> Bool in
            if let pkg1 = obj1.name?.lowercased() {
                if let pkg2 = obj2.name?.lowercased() {
                    if let searchQuery = search?.lowercased(),
                       !searchQuery.isEmpty {
                        if pkg1.hasPrefix(searchQuery) && !pkg2.hasPrefix(searchQuery) {
                            return true
                        } else if !pkg1.hasPrefix(searchQuery) && pkg2.hasPrefix(searchQuery) {
                            return false
                        }
                        
                        let diff1 = pkg1.count - searchQuery.count
                        let diff2 = pkg2.count - searchQuery.count
                        
                        if diff1 < diff2 {
                            return true
                        } else if diff1 > diff2 {
                            return false
                        }
                        return pkg1.compare(pkg2) != .orderedDescending
                    } else {
                        return pkg1.compare(pkg2) != .orderedDescending
                    }
                } else {
                    return true
                }
            }
            return false
        }
        return tmp
    }
    
    public func newestPackage(identifier: String, repoContext: Repo?) -> Package? {
        if identifier.contains("/") {
            let url = URL(fileURLWithPath: identifier)
            guard let rawPackageControl = try? DpkgWrapper.rawFields(packageURL: url) else {
                return nil
            }
            guard let rawPackage = try? ControlFileParser.dictionary(controlFile: rawPackageControl, isReleaseFile: true) else {
                return nil
            }
            guard let package = PackageListManager.package(packageEnum: rawPackage) else {
                return nil
            }
            package.package = identifier
            package.packageFileURL = url
            return package
        } else if let repoContext = repoContext {
            return repoContext.packageDict[identifier.lowercased()]
        } else {
            let allPackages = allPackagesArray
            let lowerIdentifier = identifier.lowercased()
            let available = allPackages.filter { $0.packageID == lowerIdentifier }
            var tmp: Package?
            for package in available {
                if let old = tmp {
                    if DpkgWrapper.isVersion(package.version, greaterThan: old.version) {
                        tmp = package
                    }
                } else {
                    tmp = package
                }
            }
            return tmp
        }
    }
    
    public func installedPackage(identifier: String) -> Package? {
        installedPackages[identifier.lowercased()]
    }
    
    public func package(url: URL) -> Package? {
        let canonicalPath = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
        let filePath = canonicalPath ?? url.path
        return newestPackage(identifier: filePath, repoContext: nil)
    }
    
    public func packages(identifiers: [String], sorted: Bool, repoContext: Repo? = nil) -> [Package] {
        if identifiers.isEmpty { return [] }
        let packages = (repoContext?.packageArray ?? allPackagesArray)
        var rawPackages = [Package]()
        for identifier in identifiers {
            rawPackages += packages.filter { $0.packageID == identifier }
        }
        if sorted {
            return rawPackages.sorted(by: { pkg1, pkg2 -> Bool in
                guard let package1 = pkg1.name else {
                    return false
                }
                guard let package2 = pkg2.name else {
                    return false
                }
                return package1.compare(package2) != .orderedDescending
            })
        } else {
            var packagesMap: [String: Package] = [:]
            for package in rawPackages {
                packagesMap[package.package] = package
            }
            
            var packages: [Package] = []
            for identifier in identifiers {
                guard let package = packagesMap[identifier] else {
                    continue
                }
                packages.append(package)
            }
            return packages
        }
    }
    
    public func package(identifier: String, version: String) -> Package? {
        let allPackages = allPackagesArray
        return allPackages.first(where: { $0.packageID == identifier && $0.version == version })
    }
    
    public func package(identifiersAndVersions: [(String, String)], repoContext: Repo?) -> [Package]? {
        let allPackages = allPackagesArray
        
        let filtered = allPackages.filter({
            let pkg = $0
            return identifiersAndVersions.contains(where: { $0.0 == pkg.packageID && $0.1 == pkg.version })
        })
        
        return filtered.isEmpty ? nil : filtered
    }
    
    public func upgradeAll() {
        self.upgradeAll(completion: nil)
    }
    
    public func upgradeAll(completion: (() -> Void)?) {
        let packagePairs = self.availableUpdates()
        let updatesNotIgnored = packagePairs.filter({ $0.1?.wantInfo != .hold })
        let downloadMan = DownloadManager.shared
        
        for packagePair in updatesNotIgnored {
            let newestPkg = packagePair.0
            
            if let installedPkg = packagePair.1, installedPkg == newestPkg {
                continue
            }
            
            downloadMan.add(package: newestPkg, queue: .upgrades)
        }
        
        downloadMan.reloadData(recheckPackages: true, completion: completion)
    }
}
