//
//  ContentView.swift
//  MuffinStoreJailed
//
//  Created by Mineek on 26/12/2024.
//

import SwiftUI
import PartyUI
import DeviceKit

struct ContentView: View {
    @State private var hasShownWelcome: Bool = false
    @State private var showLogs: Bool = true
    @State private var showSettingsView: Bool = false
    
    @EnvironmentObject var appData: AppData
    
    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                NavigationSplitView(sidebar: {
                    List {
                        LogsSection
                        NavigationButtons()
                    }
                    .navigationTitle("PancakeStore")
                }) {
                    List {
                        if !appData.isAuthenticated {
                            LoginSection
                        } else {
                            if appData.isDowngrading {
                                AppInfoSection
                            } else {
                                InputAppSection
                            }
                        }
                    }
                }
            } else {
                NavigationStack {
                    List {
                        LogsSection
                        if !appData.isAuthenticated {
                            LoginSection
                        } else {
                            if appData.isDowngrading {
                                AppInfoSection
                            } else {
                                InputAppSection
                            }
                        }
                    }
                    .navigationTitle("PancakeStore")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button(action: {
                                    let tempDir = FileManager.default.temporaryDirectory
                                    let tempIPAURL = tempDir.appendingPathComponent("app.ipa")
                                    presentShareSheet(with: tempIPAURL)
                                }) {
                                    Label("Export IPA", systemImage: "arrow.up.doc")
                                }
                                .disabled(!appData.hasAppBeenServed)
                                Button(action: {
                                    Haptic.shared.play(.heavy)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        EncryptedKeychainWrapper.nuke()
                                        EncryptedKeychainWrapper.generateAndStoreKey()
                                        sleep(3)
                                        exitinator()
                                    }
                                }) {
                                    ButtonLabel(text: "Log Out", icon: "arrow.right")
                                }
                                .disabled(!appData.isAuthenticated)
                            } label : { Image(systemName: "line.horizontal.3") }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: {
                                showSettingsView.toggle()
                            }) {
                                Image(systemName: "gear")
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        NavigationButtons()
                            .modifier(OverlayBackground())
                    }
                }
            }
        }
        .sheet(isPresented: $showSettingsView) {
            SettingsView()
        }
        .onAppear {
            appData.isAuthenticated = EncryptedKeychainWrapper.hasAuthInfo()
            print("Found \(appData.isAuthenticated ? "auth" : "no auth") info in keychain")
            if appData.isAuthenticated {
                appData.applicationStatus = "Ready to Downgrade!"
                appData.applicationIcon = "checkmark.circle.fill"
                appData.applicationIconColor = .primary
                guard let authInfo = EncryptedKeychainWrapper.getAuthInfo() else {
                    print("Failed to get auth info from keychain, logging out")
                    appData.isAuthenticated = false
                    EncryptedKeychainWrapper.nuke()
                    EncryptedKeychainWrapper.generateAndStoreKey()
                    return
                }
                appData.appleId = authInfo["appleId"]! as! String
                appData.password = authInfo["password"]! as! String
                appData.ipaTool = IPATool(appleId: appData.appleId, password: appData.password)
                let ret = appData.ipaTool?.authenticate()
                print("Re-authenticated \(ret! ? "successfully" : "unsuccessfully")")
            } else {
                print("No auth info found in keychain, setting up by generating a key in SEP")
                EncryptedKeychainWrapper.generateAndStoreKey()
            }
        }
    }
    
    private var LogsSection: some View {
        Section(header: HeaderLabel(text: "Logs", icon: "terminal"), footer: Text("Originally created by [mineek](https://github.com/mineek) with backend and QoL enhancements made by [jailbreak.party](https://github.com/jailbreakdotparty).\n[Join the jailbreak.party discord!](https://jailbreak.party/discord)")) {
            VStack {
                TerminalHeader(text: appData.applicationStatus, icon: appData.applicationIcon, color: appData.applicationIconColor)
                LogView()
                    .modifier(TerminalPlatter())
            }
        }
    }
    
    private var LoginSection: some View {
        Group {
            Section(header: HeaderLabel(text: "Login", icon: "icloud"), footer: Text("")) {
                VStack {
                    TextField("Apple ID", text: $appData.appleId)
                        .modifier(TextFieldBackground())
                        .disabled(appData.hasSent2FACode)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    
                    HStack {
                        if appData.showPassword {
                            TextField("Password", text: $appData.password)
                                .modifier(TextFieldBackground())
                                .disabled(appData.hasSent2FACode)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } else {
                            SecureField("Password", text: $appData.password)
                                .modifier(TextFieldBackground())
                                .disabled(appData.hasSent2FACode)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        
                        Button(action: {
                            appData.showPassword.toggle()
                        }) {
                            Image(systemName: appData.showPassword ? "eye" : "eye.slash")
                                .frame(width: 22, height: 22, alignment: .center)
                        }
                        .buttonStyle(TranslucentButtonStyle(useFullWidth: false))
                    }
                }
            }
            
            Section(header: HeaderLabel(text: "Verification Code (2FA)", icon: "key")) {
                TextField("2FA Code", text: $appData.code)
                    .modifier(TextFieldBackground())
                    .keyboardType(.numberPad)
            }
        }
    }
    
    private var InputAppSection: some View {
        Section(header: HeaderLabel(text: "Downgrade App", icon: "arrow.down.app"), footer: Text("To downgrade an app, it must have been purchased on your account at some point in the past (when the app has a cloud icon next to it). It must also not be installed on your device currently, but you can offload it.")) {
            VStack {
                TextField("Link to App Store App", text: $appData.appLink)
                    .modifier(TextFieldBackground())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
    }
    
    private var AppInfoSection: some View {
        Section(header: HeaderLabel(text: "App Info", icon: "info.circle")) {
            ItemInfoCell(label: "App Link", icon: "link", text: appData.appLink)
            ItemInfoCell(label: "App Bundle ID", icon: "shippingbox", text: appData.appBundleID)
            ItemInfoCell(label: "Target App Version", icon: "arrow.down.app", text: appData.appVersion)
        }
    }
}

struct ItemInfoCell: View {
    var label: String
    var icon: String
    var text: String
    
    var body: some View {
        LabeledContent {
            if text.isEmpty {
                ProgressView()
            } else {
                Text(text)
            }
        } label: {
            HStack {
                Image(systemName: icon)
                    .frame(width: 22, height: 22, alignment: .center)
                Text(label)
            }
        }
        .contextMenu {
            Button(action: {
                UIPasteboard.general.string = text
            }) {
                Label("Copy Value", systemImage: "character.cursor.ibeam")
            }
        }
    }
}

struct SidebarToggleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppData())
}
