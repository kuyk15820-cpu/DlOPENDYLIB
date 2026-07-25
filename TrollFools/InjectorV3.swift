//
//  InProcessInjector.swift
//

import CocoaLumberjackSwift
import Foundation
import Darwin // สำหรับใช้งาน dlopen, dlclose, dlerror, dlsym

final class InProcessInjector {
    enum LoggerType {
        case os
        case file
    }

    enum InjectError: LocalizedError {
        case fileNotFound(URL)
        case loadFailed(String)
        case invalidHandle

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let url):
                return "ไม่พบไฟล์ dylib ที่เส้นทาง: \(url.path)"
            case .loadFailed(let reason):
                return "การ dlopen ล้มเหลว: \(reason)"
            case .invalidHandle:
                return "Handle ของ Library ไม่ถูกต้อง"
            }
        }
    }

    // MARK: - Properties

    static let temporaryRoot: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.local.injector", isDirectory: true)
        .appendingPathComponent("InProcessInjector", isDirectory: true)

    static let main = InProcessInjector()

    let appID: String
    let temporaryDirectoryURL: URL
    let logsDirectoryURL: URL
    let isPrivileged: Bool = geteuid() == 0

    let logger: DDLog
    let loggerType: LoggerType

    /// พิกัดเก็บ dylib แบบ Persistent ที่ผู้ใช้คัดลอกมาเก็บไว้
    static let persistentPlugInsRootURL: URL = {
        let url = URL(fileURLWithPath: "/var/mobile/Library/TrollFools/PersistentPlugins")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    lazy var persistentPlugInsDirectoryURL: URL = {
        let url = Self.persistentPlugInsRootURL.appendingPathComponent(appID, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: - Initialization

    init(loggerType: LoggerType = .file) {
        self.appID = Bundle.main.bundleIdentifier ?? "com.local.app"
        self.loggerType = loggerType

        temporaryDirectoryURL = Self.temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)

        logsDirectoryURL = temporaryDirectoryURL.appendingPathComponent("Logs/\(appID)")

        logger = DDLog()
        setupLoggers()
    }

    // MARK: - Core Operations (dlopen Injection)

    /// โหลด dylib จาก URL ที่กำหนดเข้าสู่ Memory Space ของ Process ปัจจุบัน
    /// - Parameters:
    ///   - dylibURL: เส้นทางไฟล์ .dylib ที่เลือกมาจาก Document Picker หรือตำแหน่งอื่นๆ
    ///   - mode: โหมดของ dlopen (ค่าเริ่มต้นคือ RTLD_NOW | RTLD_GLOBAL)
    /// - Returns: Pointer handle ของ dylib ที่เปิดขึ้นสำเร็จ
    @discardableResult
    func injectDylib(from dylibURL: URL, mode: Int32 = RTLD_NOW | RTLD_GLOBAL) throws -> UnsafeMutableRawPointer {
        // 1. ตรวจสอบว่ามีไฟล์อยู่จริง
        guard FileManager.default.fileExists(atPath: dylibURL.path) else {
            DDLogError("File not found: \(dylibURL.path)", ddlog: logger)
            throw InjectError.fileNotFound(dylibURL)
        }

        // 2. เรียกใช้ dlopen เพื่อทำการ Link Dynamic Library แบบ Runtime
        guard let handle = dlopen(dylibURL.path, mode) else {
            let errorMessage = String(cString: dlerror())
            DDLogError("Failed to dlopen \(dylibURL.lastPathComponent): \(errorMessage)", ddlog: logger)
            throw InjectError.loadFailed(errorMessage)
        }

        DDLogInfo("Successfully injected dylib: \(dylibURL.lastPathComponent) [Address: \(handle)]", ddlog: logger)
        return handle
    }

    /// สั่งปิด/Unload dylib จาก Handle (ใช้เมื่อต้องการปล่อย Memory)
    func unloadDylib(handle: UnsafeMutableRawPointer) -> Bool {
        let result = dlclose(handle) == 0
        if result {
            DDLogInfo("Successfully unloaded dylib handle: \(handle)", ddlog: logger)
        } else {
            let errorMessage = String(cString: dlerror())
            DDLogError("Failed to unload dylib: \(errorMessage)", ddlog: logger)
        }
        return result
    }

    // MARK: - Helper Methods

    /// คัดลอก dylib จากภายนอกเข้ามาเก็บไว้ใน Persistent Directory ของแอปก่อนทำการโหลด
    func copyToPersistentStorage(from sourceURL: URL) throws -> URL {
        let destinationURL = persistentPlugInsDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent)
        
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        DDLogInfo("Copied dylib to persistent storage: \(destinationURL.path)", ddlog: logger)
        return destinationURL
    }

    // MARK: - Logger Management

    private func setupLoggers() {
        if loggerType == .file {
            try? FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)

            let fileLogger = DDFileLogger(logFileManager: DDLogFileManagerDefault(logsDirectory: logsDirectoryURL.path))
            fileLogger.rollingFrequency = 60 * 60 * 24
            fileLogger.logFileManager.maximumNumberOfLogFiles = 7
            fileLogger.doNotReuseLogFiles = true

            logger.add(fileLogger)
        }

        logger.add(DDOSLogger.sharedInstance)
        DDLogWarn("InProcessInjector Logger setup complete for app: \(appID)", asynchronous: false, ddlog: logger)
    }
}
