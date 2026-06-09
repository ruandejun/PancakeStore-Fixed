//
//  IPATool.swift
//  MuffinStoreJailed
//
//  Created by Mineek on 19/10/2024.
//

// Heavily inspired by ipatool-py.
// https://github.com/NyaMisty/ipatool-py

import Foundation
import CommonCrypto
import Zip
import SwiftUI
import PartyUI

extension Data {
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}

class SHA1 {
    static func hash(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }
}

extension String {
    subscript (i: Int) -> String {
        return String(self[index(startIndex, offsetBy: i)])
    }

    subscript (r: Range<Int>) -> String {
        let start = index(startIndex, offsetBy: r.lowerBound)
        let end = index(startIndex, offsetBy: r.upperBound)
        return String(self[start..<end])
    }
}

class StoreClient {
    var session: URLSession
    var appleId: String
    var password: String
    var guid: String?
    var accountName: String?
    var authHeaders: [String: String]?
    var authCookies: [HTTPCookie]?
    var pod: String?

    init(appleId: String, password: String) {
        session = URLSession.shared
        self.appleId = appleId
        self.password = password
        self.guid = nil
        self.accountName = nil
        self.authHeaders = nil
        self.authCookies = nil
        self.pod = nil
    }

    func generateGuid(appleId: String) -> String {
        print("Generating GUID")
        let DEFAULT_GUID = "000C2941396B"
        let GUID_DEFAULT_PREFIX = 2
        let GUID_SEED = "CAFEBABE"
        let GUID_POS = 10

        let h = SHA1.hash((GUID_SEED + appleId + GUID_SEED).data(using: .utf8)!).hexString
        let defaultPart = DEFAULT_GUID.prefix(GUID_DEFAULT_PREFIX)
        let hashPart = h[GUID_POS..<GUID_POS + (DEFAULT_GUID.count - GUID_DEFAULT_PREFIX)]
        let guid = (defaultPart + hashPart).uppercased()

        print("Came up with GUID: \(guid)")
        return guid
    }

    func saveAuthInfo() -> Void {
        let authCookiesEnc1 = NSKeyedArchiver.archivedData(withRootObject: authCookies!)
        let authCookiesEnc = authCookiesEnc1.base64EncodedString()
        let out: [String: Any] = [
            "appleId": appleId,
            "password": password,
            "guid": guid,
            "accountName": accountName,
            "authHeaders": authHeaders,
            "authCookies": authCookiesEnc,
            "pod": pod
        ]
        let data = try! JSONSerialization.data(withJSONObject: out, options: [])
        let base64 = data.base64EncodedString()
        EncryptedKeychainWrapper.saveAuthInfo(base64: base64)
    }

    func tryLoadAuthInfo() -> Bool {
        if let base64 = EncryptedKeychainWrapper.loadAuthInfo() {
            let data = Data(base64Encoded: base64)!
            let out = try! JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
            appleId = out["appleId"] as! String
            password = out["password"] as! String
            guid = out["guid"] as? String
            accountName = out["accountName"] as? String
            authHeaders = out["authHeaders"] as? [String: String]
            let authCookiesEnc = out["authCookies"] as! String
            let authCookiesEnc1 = Data(base64Encoded: authCookiesEnc)!
            authCookies = NSKeyedUnarchiver.unarchiveObject(with: authCookiesEnc1) as? [HTTPCookie]
            pod = out["pod"] as? String
            print("Loaded auth info")
            return true
        }
        print("No auth info found, need to authenticate")
        return false
    }
    
    // pancakestore is saved! thanks ipatool!
    // admittedly i kinda owe this hoorah to that vibecoded ass pull-request, i had to stoop to its level too :(
    // oh well. - skadz, 2.24.26
    func getBagEndpoint() async -> String {
        let fallback = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate" // this is the old broken one, i'm just gonna have it as a fallback in case this amazingness somehow fails one day
        
        if guid == nil {
            guid = generateGuid(appleId: appleId)
        }
        guard let guid = guid else { return fallback }

        var request = URLRequest(url: URL(string: "https://init.itunes.apple.com/bag.xml?guid=\(guid)")!)
        request.httpMethod = "GET"
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue("Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard !data.isEmpty else { return fallback }

            // i'm sorry i'm sorry please don't hit me i know i know
            if let xmlString = String(data: data, encoding: .utf8),
               let plistStart = xmlString.range(of: "<plist"),
               let plistEnd = xmlString.range(of: "</plist>") {
                let plistSection = String(xmlString[plistStart.lowerBound..<plistEnd.upperBound])
                if let cleanData = plistSection.data(using: .utf8),
                   let plist = try PropertyListSerialization.propertyList(from: cleanData, options: [], format: nil) as? [String: Any],
                   let urlBag = plist["urlBag"] as? [String: Any],
                   var endpoint = urlBag["authenticateAccount"] as? String {
                    if !endpoint.hasSuffix("/") {
                        endpoint += "/"
                    }
                    if endpoint.contains("/v1/native/") && !endpoint.contains("/fast/") {
                        endpoint += "fast/"
                    }
                    print("bag: \(endpoint)")
                    return endpoint
                }
            }
        } catch {
            print("failed to get bag endpoint!! \(error)")
        }

        return fallback
    }

    func authenticate(requestCode: Bool = false) -> Bool {
        @ObservedObject var appData = AppData.shared
        
        if self.guid == nil {
            self.guid = generateGuid(appleId: appleId)
        }

        var req = [
            "appleId": appleId,
            "password": password,
            "guid": guid!,
            "rmp": "0",
            "why": "signIn"
        ]
        Task {
            let authURL = await getBagEndpoint()
            
            let url = URL(string: authURL)!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.allHTTPHeaderFields = [
                "Accept": "*/*",
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
            ]
            
            var ret = false
            var currentURL = url
            var triedFast = false
            var gotEmptyResponse = false
            
            for attempt in 1...4 {
                req["attempt"] = String(attempt)
                request.url = currentURL
                request.httpBody = try! JSONSerialization.data(withJSONObject: req, options: [])
                gotEmptyResponse = false
                let datatask = session.dataTask(with: request) { (data, response, error) in
                    if let error = error {
                        print("error 1 \(error.localizedDescription)")
                        return
                    }
                    if let response = response {
                        if let response = response as? HTTPURLResponse {
                            print("New URL: \(response.url!)")
                            request.url = response.url
                            
//                            print(response.allHeaderFields)
                            
                            if let pod = response.value(forHTTPHeaderField: "pod") {
                                print("pod gotten: \(pod)")
                                self.pod = pod
                            } else {
                                print("pod not gotten!!?")
                            }
                        }
                    }
                    if let data = data {
                        if data.isEmpty {
                            print("Received empty data, will try fast/ endpoint")
                            gotEmptyResponse = true
                            if !triedFast {
                                var urlString = currentURL.absoluteString
                                if urlString.hasSuffix("/") {
                                    urlString = String(urlString.dropLast())
                                }
                                if let newURL = URL(string: urlString + "/fast/") {
                                    currentURL = newURL
                                    triedFast = true
                                }
                            }
                            return
                        }
                        do {
                            let resp = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
                            if let dsPersonId = resp["dsPersonId"] as? String, let passwordToken = resp["passwordToken"] as? String, !dsPersonId.isEmpty, !passwordToken.isEmpty {
                                print("Authentication successful!")
                                appData.hasSent2FACode = true
                                let download_queue_info = resp["download-queue-info"] as! [String: Any]
                                let dsid = download_queue_info["dsid"] as! Int
                                let httpResp = response as! HTTPURLResponse
                                let storeFront = httpResp.value(forHTTPHeaderField: "x-set-apple-store-front")
                                print("Store front: \(storeFront!)")
                                self.authHeaders = [
                                    "X-Dsid": String(dsid),
                                    "iCloud-Dsid": String(dsid),
                                    "X-Apple-Store-Front": storeFront!,
                                    "X-Token": resp["passwordToken"] as! String
                                ]
                                self.authCookies = self.session.configuration.httpCookieStorage?.cookies
                                let accountInfo = resp["accountInfo"] as! [String: Any]
                                let address = accountInfo["address"] as! [String: String]
                                self.accountName = address["firstName"]! + " " + address["lastName"]!
                                self.saveAuthInfo()
                                ret = true
                            } else {
                                print("authentication failed: \(resp["customerMessage"] as! String)")
                                DispatchQueue.main.async {
                                    Alertinator.shared.alert(title: "Failed to log in!", body: "Make sure that your Apple ID and password are correct, and then try again.\n\nError: \(resp["customerMessage"] as! String)")
                                }
                            }
                        } catch {
                            print("Error: \(error)")
                            gotEmptyResponse = true
                            if !triedFast {
                                var urlString = currentURL.absoluteString
                                if urlString.hasSuffix("/") {
                                    urlString = String(urlString.dropLast())
                                }
                                if let newURL = URL(string: urlString + "/fast/") {
                                    currentURL = newURL
                                    triedFast = true
                                }
                            }
                        }
                    }
                }
                datatask.resume()
                while datatask.state != .completed {
                    sleep(1)
                }
                if ret {
                    break
                }
                if requestCode {
                    if !gotEmptyResponse {
                        ret = false
                        break
                    }
                }
            }
            return ret
        }
        return false
    }

    func volumeStoreDownloadProduct(appId: String, appVerId: String = "") -> [String: Any] {
        var req = [
            "creditDisplay": "",
            "guid": self.guid!,
            "salableAdamId": appId,
        ]
        if appVerId != "" {
            req["externalVersionId"] = appVerId
        }
        let url = URL(string: "https://p\(pod!)-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=\(self.guid!)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = [
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
        ]
        request.httpBody = try! JSONSerialization.data(withJSONObject: req, options: [])
        print("Setting headers")
        for (key, value) in self.authHeaders! {
            print("Setting header \(key): \(value)")
            request.addValue(value, forHTTPHeaderField: key)
        }
        print("Setting cookies")
        self.session.configuration.httpCookieStorage?.setCookies(self.authCookies!, for: url, mainDocumentURL: nil)

        var resp = [String: Any]()
        let datatask = session.dataTask(with: request) { (data, response, error) in
            if let error = error {
                print("error 2 \(error.localizedDescription)")
                return
            }
            if let data = data {
                do {
                    print("Got response")
                    let resp1 = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
                    if resp1["cancel-purchase-batch"] != nil {
                        print("Failed to download product: \(resp1["customerMessage"] as! String)")
                    }
                    resp = resp1
                } catch {
                    print("Error: \(error)")
                }
            }
        }
        datatask.resume()
        while datatask.state != .completed {
            sleep(1)
        }
        print("Got download response")
        return resp
    }

    func download(appId: String, appVer: String = "", isRedownload: Bool = false) -> [String: Any] {
        return self.volumeStoreDownloadProduct(appId: appId, appVerId: appVer)
    }

    func downloadToPath(url: String, path: String) -> Void {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        let datatask = session.dataTask(with: req) { (data, response, error) in
            if let error = error {
                print("error 3 \(error.localizedDescription)")
                return
            }
            if let data = data {
                do {
                    try data.write(to: URL(fileURLWithPath: path))
                } catch {
                    print("Error: \(error)")
                }
            }
        }
        datatask.resume()
        while datatask.state != .completed {
            sleep(1)
        }
        print("Downloaded to \(path)")
    }
}

class IPATool {
    var session: URLSession
    var appleId: String
    var password: String
    var storeClient: StoreClient
    
    init(appleId: String, password: String) {
        print("init!")
        session = URLSession.shared
        self.appleId = appleId
        self.password = password
        storeClient = StoreClient(appleId: appleId, password: password)
    }
    
    func authenticate(requestCode: Bool = false) -> Bool {
        print("Authenticating to iTunes Store...")
        if !storeClient.tryLoadAuthInfo() {
            return storeClient.authenticate(requestCode: requestCode)
        } else {
            return true
        }
    }

    func getVersionIDList(appId: String) -> [String] {
        print("Retrieving download info for appId \(appId)...")
        let downResp = storeClient.download(appId: appId, isRedownload: true)
        let songList = downResp["songList"] as? [[String: Any]] ?? []
        if songList.count == 0 {
            print("Failed to get id list!")
            return []
        }
        let downInfo = songList[0]
        let metadata = downInfo["metadata"] as? [String: Any] ?? [:]
        let appVerIds = metadata["softwareVersionExternalIdentifiers"] as? [Int] ?? []
        print("Got available version ids: \(appVerIds)")
        return appVerIds.map { String($0) }
    }

    func downloadIPAForVersion(appId: String, appVerId: String) -> String {
        print("Downloading IPA for app \(appId) version \(appVerId)")
        let downResp = storeClient.download(appId: appId, appVer: appVerId)
        let songList = downResp["songList"] as! [[String: Any]]
        if songList.count == 0 {
            print("Failed to get app download info!")
            return ""
        }
        let downInfo = songList[0]
        let url = downInfo["URL"] as! String
        print("Got download URL: \(url)")
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        let path = tempDir.appendingPathComponent("app.ipa").path
        if fm.fileExists(atPath: path) {
            print("Removing existing file at \(path)")
            try! fm.removeItem(atPath: path)
        }
        storeClient.downloadToPath(url: url, path: path)
        Zip.addCustomFileExtension("ipa")
        sleep(3)
        let path3 = URL(string: path)!
        let fileExtension = path3.pathExtension
        let fileName = path3.lastPathComponent
        let directoryName = fileName.replacingOccurrences(of: ".\(fileExtension)", with: "")
        let documentsUrl = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationUrl = documentsUrl.appendingPathComponent(directoryName, isDirectory: true)
        if fm.fileExists(atPath: destinationUrl.path) {
            print("Removing existing folder at \(destinationUrl.path)")
            try! fm.removeItem(at: destinationUrl)
        }
        
        let unzipDirectory = try! Zip.quickUnzipFile(URL(string: path)!)
        var metadata = downInfo["metadata"] as! [String: Any]
        let metadataPath = unzipDirectory.appendingPathComponent("iTunesMetadata.plist").path
        metadata["apple-id"] = appleId
        metadata["userName"] = appleId
        (metadata as NSDictionary).write(toFile: metadataPath, atomically: true)
        print("Wrote iTunesMetadata.plist")
        var appContentDir = ""
        let payloadDir = unzipDirectory.appendingPathComponent("Payload")
        for entry in try! fm.contentsOfDirectory(atPath: payloadDir.path) {
            if entry.hasSuffix(".app") {
                print("Found app content dir: \(entry)")
                appContentDir = "Payload/" + entry
                break
            }
        }
        print("Found app content dir: \(appContentDir)")
        let scManifestData = try! Data(contentsOf: unzipDirectory.appendingPathComponent(appContentDir).appendingPathComponent("SC_Info").appendingPathComponent("Manifest.plist"))
        let scManifest = try! PropertyListSerialization.propertyList(from: scManifestData, options: [], format: nil) as! [String: Any]
        let sinfsDict = downInfo["sinfs"] as! [[String: Any]]
        if let sinfPaths = scManifest["SinfPaths"] as? [String] {
            for (i, sinfPath) in sinfPaths.enumerated() {
                let sinfData = sinfsDict[i]["sinf"] as! Data
                try! sinfData.write(to: unzipDirectory.appendingPathComponent(appContentDir).appendingPathComponent(sinfPath))
                print("Wrote sinf to \(sinfPath)")
            }
        } else {
            print("Manifest.plist does not exist! Assuming it is an old app without one...")
            let infoListData = try! Data(contentsOf: unzipDirectory.appendingPathComponent(appContentDir).appendingPathComponent("Info.plist"))
            let infoList = try! PropertyListSerialization.propertyList(from: infoListData, options: [], format: nil) as! [String: Any]
            let sinfPath = appContentDir + "/SC_Info/" + (infoList["CFBundleExecutable"] as! String) + ".sinf"
            let sinfData = sinfsDict[0]["sinf"] as! Data
            try! sinfData.write(to: unzipDirectory.appendingPathComponent(sinfPath))
            print("Wrote sinf to \(sinfPath)")
        }
        print("Downloaded IPA to \(unzipDirectory.path)")
        return unzipDirectory.path
    }
}

class EncryptedKeychainWrapper {
    static func generateAndStoreKey() -> Void {
        print("Secure Enclave key generation bypassed for compatibility")
    }

    static func deleteKey() -> Void {
        print("Secure Enclave key deletion bypassed")
    }

    static func saveAuthInfo(base64: String) -> Void {
        let fm = FileManager.default
        let path = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("authinfo").path
        if let data = base64.data(using: .utf8) {
            fm.createFile(atPath: path, contents: data, attributes: nil)
            print("Saved auth info successfully")
        }
    }

    static func loadAuthInfo() -> String? {
        let fm = FileManager.default
        let path = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("authinfo").path
        if !fm.fileExists(atPath: path) {
            return nil
        }
        if let data = fm.contents(atPath: path) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    static func deleteAuthInfo() -> Void {
        let fm = FileManager.default
        let path = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("authinfo").path
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
        }
    }

    static func hasAuthInfo() -> Bool {
        return loadAuthInfo() != nil
    }

    static func getAuthInfo() -> [String: Any]? {
        if let base64 = loadAuthInfo() {
            let data = Data(base64Encoded: base64)!
            let out = try! JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
            return out
        }
        return nil
    }

    static func nuke() -> Void {
        deleteAuthInfo()
        deleteKey()
    }
}
