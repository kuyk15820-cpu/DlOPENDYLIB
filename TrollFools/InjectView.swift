//
//  InjectView.swift
//

import CocoaLumberjackSwift
import SwiftUI

struct InjectView: View {
    struct SuccessPayload {
        let logFileURL: URL?
    }

    @EnvironmentObject var appList: AppListModel

    /// รายการไฟล์ dylib ที่เลือกมาจาก File Picker
    let urlList: [URL]

    @State var injectResult: Result<SuccessPayload, Error>?
    @StateObject fileprivate var viewControllerHost = ViewControllerHost()

    init(urlList: [URL]) {
        self.urlList = urlList
    }

    var body: some View {
        if appList.isSelectorMode {
            bodyContent
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(NSLocalizedString("Done", comment: "")) {
                            viewControllerHost.viewController?.navigationController?
                                .dismiss(animated: true)
                        }
                    }
                }
        } else {
            bodyContent
        }
    }

    var bodyContent: some View {
        VStack {
            if let injectResult {
                switch injectResult {
                case let .success(payload):
                    SuccessView(
                        title: NSLocalizedString("Completed", comment: "โหลด dylib สำเร็จ"),
                        subtitle: nil,
                        logFileURL: payload.logFileURL
                    )
                case let .failure(error):
                    FailureView(
                        title: NSLocalizedString("Failed", comment: "เกิดข้อผิดพลาดในการโหลด"),
                        error: error
                    )
                }
            } else {
                if #available(iOS 16, *) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.all, 20)
                        .controlSize(.large)
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.all, 20)
                        .scaleEffect(2.0)
                }

                Text(NSLocalizedString("Injecting", comment: "กำลังทำการโหลด dylib..."))
                    .font(.headline)
            }
        }
        .padding()
        .animation(.easeOut, value: injectResult == nil)
        .navigationTitle(NSLocalizedString("Local Injection", comment: "โหลด dylib เข้าแอป"))
        .navigationBarTitleDisplayMode(.inline)
        .onViewWillAppear { viewController in
            viewController.navigationController?
                .view.isUserInteractionEnabled = false
            viewControllerHost.viewController = viewController
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = inject()

                DispatchQueue.main.async {
                    injectResult = result
                    viewControllerHost.viewController?.navigationController?
                        .view.isUserInteractionEnabled = true
                }
            }
        }
    }

    // MARK: - Core Logic

    private func inject() -> Result<SuccessPayload, Error> {
        let injector = InProcessInjector.main
        let logFileURL = injector.latestLogFileURL

        do {
            for fileURL in urlList {
                // 1. คัดลอก dylib ไปยังโฟลเดอร์ Persistent ของแอปตัวเอง
                let persistentURL = try injector.copyToPersistentStorage(from: fileURL)

                // 2. สั่ง dlopen เข้าสู่ Process แอปปัจจุบัน
                try injector.injectDylib(from: persistentURL)
            }

            return .success(SuccessPayload(logFileURL: injector.latestLogFileURL))

        } catch {
            DDLogError("In-process injection failed: \(error)", ddlog: injector.logger)

            var userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: error.localizedDescription,
            ]

            if let logFileURL {
                userInfo[NSURLErrorKey] = logFileURL
            }

            let nsErr = NSError(domain: Constants.gErrorDomain, code: 0, userInfo: userInfo)
            return .failure(nsErr)
        }
    }
}
