//
//  BottomBar.swift
//  PancakeStore
//
//  Created by lunginspector on 2/24/26.
//

import SwiftUI
import PartyUI

struct NavigationButtons: View {
    @EnvironmentObject var appData: AppData
    
    var body: some View {
        VStack {
            // i hate this.
            if !appData.isAuthenticated {
                Button(action: {
                    Haptic.shared.play(.soft)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if appData.appleId.isEmpty || appData.password.isEmpty {
                            Alertinator.shared.alert(title: "No Apple ID details were input!", body: "Please type both your Apple ID email address & password, then try again.")
                        } else {
                            if appData.code.isEmpty {
                                appData.ipaTool = IPATool(appleId: appData.appleId, password: appData.password)
                                appData.ipaTool?.authenticate(requestCode: true)
                                //appData.hasSent2FACode = true
                                return
                            }
                            let finalPassword = appData.password + appData.code
                            appData.ipaTool = IPATool(appleId: appData.appleId, password: finalPassword)
                            let ret = appData.ipaTool?.authenticate()
                            appData.isAuthenticated = ret ?? false
                            
                            if appData.isAuthenticated {
                                appData.applicationStatus = "Ready to Downgrade!"
                                appData.applicationIcon = "checkmark.circle.fill"
                                appData.applicationIconColor = .secondary
                            }
                        }
                    }
                }) {
                    if appData.hasSent2FACode || !appData.code.isEmpty {
                        ButtonLabel(text: "Log In", icon: "arrow.right")
                    } else {
                        ButtonLabel(text: "Send 2FA Code", icon: "key")
                    }
                }
                .buttonStyle(FancyButtonStyle())
                .disabled(appData.appleId.isEmpty || appData.password.isEmpty)
                .disabled((appData.hasSent2FACode || !appData.code.isEmpty) ? appData.code.isEmpty : false)
            } else {
                if appData.isDowngrading {
                    Button(action: {
                        Haptic.shared.play(.soft)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            LSApplicationWorkspace.default().openApplication(withBundleID: "com.jbdotparty.PancakeStore2")
                        }
                    }) {
                        ButtonLabel(text: "Open App", icon: "arrow.up.forward.app")
                    }
                    .buttonStyle(FancyButtonStyle(color: .blue))
                    .disabled(!appData.hasAppBeenServed)
                    
                    Button(action: {
                        Haptic.shared.play(.heavy)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            exitinator()
                        }
                    }) {
                        ButtonLabel(text: "Go to Home Screen", icon: "house")
                    }
                    .buttonStyle(FancyButtonStyle())
                    .disabled(!appData.hasAppBeenServed)
                } else {
                    Button(action: {
                        Haptic.shared.play(.soft)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            if appData.appLink.isEmpty {
                                return
                            }
                            var appLinkParsed = appData.appLink
                            appLinkParsed = appLinkParsed.components(separatedBy: "id").last ?? ""
                            for char in appLinkParsed {
                                if !char.isNumber {
                                    appLinkParsed = String(appLinkParsed.prefix(upTo: appLinkParsed.firstIndex(of: char)!))
                                    break
                                }
                            }
                            print("App ID: \(appLinkParsed)")
                            appData.isDowngrading = true
                            downgradeApp(appId: appLinkParsed, ipaTool: appData.ipaTool!)
                            appData.applicationStatus = "Downgrading Application..."
                            appData.applicationIcon = "showMeProgressPlease"
                        }
                    }) {
                        ButtonLabel(text: "Downgrade App", icon: "arrow.down")
                    }
                    .buttonStyle(FancyButtonStyle())
                    .disabled(appData.appLink.isEmpty)
                    
                    /*
                    Button(action: {
                        Haptic.shared.play(.heavy)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            appData.isAuthenticated = false
                            EncryptedKeychainWrapper.nuke()
                            EncryptedKeychainWrapper.generateAndStoreKey()
                            sleep(3)
                            exitinator()
                        }
                    }) {
                        ButtonLabel(text: "Log Out & Exit", icon: "xmark")
                    }
                    .buttonStyle(FancyButtonStyle(color: .red))
                     */
                }
            }
        }
    }
}
