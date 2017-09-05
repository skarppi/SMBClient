//
//  SMBSession.swift
//  SMBClient
//
//  Created by Seth Faxon on 9/1/17.
//  Copyright © 2017 Filmic. All rights reserved.
//

import libdsm

public enum SMBSessionError: Error {
    case unableToResolveAddress
    case unableToConnect
    case authenticationFailed
}

public enum SessionGuestState: Int32 {
    case guest = 1
    case user = 0
    case error = -1
}

public class SMBSession {
    private var smbSession = smb_session_new()
    private var lastRequestDate: Date?
    private var serialQueue = DispatchQueue(label: "SMBSession")
    
    public var hostName: String?
    public var ipAddress: String?
    public var userName: String?
    public var password: String?
    public var sessionGuestState: SessionGuestState?
    public var connected: Bool = false
    
    public init() { }
    
//    public func requestContents(ofShare: SMBShare)
//    public func requestContents(ofDirectory: SMBDirectory)
    
    public func requestContents(atFilePath path: String) -> [SMBFile] {
        let conError = self.attemptConnection()
        // switch result/error
        if conError != nil {
            return []
        }
        
        if path.characters.count == 0 || path == "/" {
            var list: smb_share_list? = smb_share_list.allocate(capacity: 1)
            
            let shareCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            shareCount.pointee = 0
            
            smb_share_get_list(self.smbSession, &list, shareCount)
            
            if shareCount.pointee == 0 {
                return []
            }
            var results: [SMBFile] = []
            
            var i = 0
            while i <= shareCount.pointee {
                guard let shareNameCString = smb_share_list_at(list!, i) else {
                    i = i + 1
                    continue
                }
                
                var shareName = String(cString: shareNameCString)
                // skip system shares suffixed by '$'
                if shareName.characters.last == "$" {
                    i = i + 1
                    continue
                }
                
                if let f = SMBFile(name: shareName, session: self) {
                    results.append(f)
                }
                
                i = i + 1
            }
            return results
        }
        
        let (shareName, filePath) = shareAndPathFrom(path: path)
        
        var shareId: UInt16 = smb_tid.max
        smb_tree_connect(self.smbSession, shareName.cString(using: .utf8), &shareId)
        if shareId == smb_tid.max {
            return []
        }
        let directoryPath = filePath ?? "/"
//        let directoryPath = filePath else { return [] }
        let relativePath = directoryPath + "*" // wildcard to search
        
        let statList = smb_find(self.smbSession, shareId, relativePath.cString(using: .utf8))
        let listCount = smb_stat_list_count(statList)
        if listCount == 0 {
            return []
        }
        
        var results: [SMBFile] = []
        
        var i = 0
        while i < listCount {
            let item = smb_stat_list_at(statList, i)
            guard let stat = item else { i = i + 1; continue }
            guard let file = SMBFile(stat: stat, session: self, parentDirectoryFilePath: directoryPath) else {
                i = i + 1
                continue
            }
            
            if file.name.first != "." {
                results.append(file)
            }
            
            i = i + 1
        }
        
        return results
    }
    
//    private func shareNameFrom(path: String) -> String {
//        let items = path.split(separator: "/")
//        return items[0]!
//    }
//
//    private func filePath(path: String) -> String {
//
//    }
    
    private func shareAndPathFrom(path: String) -> (String, String?) {
        let items = path.split(separator: "/")
        if items.count == 1 {
            return (String(items[0]), nil)
        }
        let filePath = items[1...].joined(separator: "\\")
        return (String(items[0]), filePath)
    }
    
    public func attemptConnection() -> SMBSessionError? {
        var err: SMBSessionError?
        serialQueue.sync {
            err = self.attemptConnectionWithSessionPointer(smbSession: self.smbSession)
        }
        
        if err != nil {
            return err
        }
        
        self.sessionGuestState = SessionGuestState(rawValue: smb_session_is_guest(self.smbSession))
        
        return nil
    }
    
    private func attemptConnectionWithSessionPointer(smbSession: OpaquePointer?) -> SMBSessionError? {
        
        // if we're connecting from a dowload task, and the sessions match, make sure to refresh them periodically
        if (self.smbSession == smbSession) {
            if let lrd = self.lastRequestDate {
                if (Date().timeIntervalSince(lrd) > 60) {
                    smb_session_destroy(self.smbSession)
                    self.smbSession = smb_session_new()
                    
                    self.connected = false
                }
            }
            self.lastRequestDate = Date()
        }
        
        // don't attempt another connection if already connected
        if (smb_session_is_guest(smbSession) >= 0) {
            self.connected = true
            return nil
        }
        
        // ensure at least of piece of connection information is supplied
        if self.ipAddress == nil && self.hostName == nil {
            return SMBSessionError.unableToResolveAddress
        }
        
        // if only hostName or ipAddress are provided, use NetBIOS to resolve the other
        if let ipAddressChk = self.ipAddress {
            if ipAddressChk.characters.count == 0 {
                if self.hostName == nil {
                    let ns = NetBIOSNameService()
                    self.hostName = ns.networkNameFor(ipAddress: ipAddressChk)
                }
            }
        }
        if let hostName = self.hostName {
            if hostName.characters.count == 0 {
                if self.ipAddress == nil {
                    let ns = NetBIOSNameService()
                    self.ipAddress = ns.resolveIPAddress(forName: hostName, ofType: NetBIOSNameServiceType.fileServer)
                }
            }
        }
        
        // if there is still no IP address we're boned
        guard let ipAddress = self.ipAddress else {
            return SMBSessionError.unableToResolveAddress
        }
        if ipAddress.characters.count < 1 {
            return SMBSessionError.unableToResolveAddress
        }
        
        let addr = UnsafeMutablePointer<in_addr>.allocate(capacity: 1)
        inet_aton(ipAddress.cString(using: .ascii), &addr.pointee)
        
        
        // attempt a connection
//        let connectionResult = smb_session_connect(<#T##s: OpaquePointer!##OpaquePointer!#>, <#T##hostname: UnsafePointer<Int8>!##UnsafePointer<Int8>!#>, <#T##ip: UInt32##UInt32#>, <#T##transport: Int32##Int32#>)
        let connectionResult = smb_session_connect(smbSession, hostName?.cString(using: .utf8), addr.pointee.s_addr, Int32(SMB_TRANSPORT_TCP))
        if connectionResult != 0 {
            return SMBSessionError.unableToConnect
        }
        
        let userName: String
        if let givenUserName = self.userName {
            userName = givenUserName
        } else {
            userName = " "
        }
        
        let password: String
        if let givenPassword = self.password {
            password = givenPassword
        } else {
            password = " "
        }
        
        smb_session_set_creds(smbSession, hostName!.cString(using: .utf8), userName.cString(using: .utf8), password.cString(using: .utf8))
        if smb_session_login(smbSession) != 0 {
            return SMBSessionError.authenticationFailed
        }
        
        if smbSession == self.smbSession {
            self.connected = true
        }
        
        return nil
    }
    
    deinit {
        guard let s = self.smbSession else { return }
        smb_session_destroy(s)
    }
}
