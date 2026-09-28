# Needs your input

Things I cannot do or decide alone. Most important first.

1. **Apple Developer Program (paid, $99/yr).** Needed to install the camera extension, even just on your own Mac. Free Personal Teams cannot get the System Extension entitlement ([Apple capability table](https://developer.apple.com/help/account/reference/supported-capabilities-macos)). After you enroll:
   - Sign in to Xcode (Settings > Accounts).
   - Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your team ID.
   - Build once from Xcode so it creates the provisioning profile.
2. **Camera permission.** The first run shows a macOS camera prompt. Only you can click it.
3. **Extension approval.** The first install asks you to allow the extension in System Settings > General > Login Items & Extensions > Camera Extensions.
4. **Copyrighted styles.** Christina's World (Wyeth, died 2009) and O'Keeffe's "Music, Pink and Blue No. 2" (from the old app) are still under copyright in many places. I left them out of the repo. The app can still load them from a URL at runtime, like the old app did. OK?
5. **A look at the real UI.** I checked the app with window snapshots and a text dump of the main menu only. They cannot show the toolbar buttons, the menu bar menu, the Settings window, alerts or the live camera. Please open the app once and check those, and try Open at login in Settings (the window should stay closed after you log in).
6. **Check auto quality on battery.** I cannot unplug the Mac or turn on Low Power Mode from here. Run `stylecam-cli run --models Models --styles Styles --style starry_night --input <file.y4m> --out /tmp/out.mp4 --realtime --quality auto --log-adaptive` on battery and with Low Power Mode on. It should print `on battery` or `Low Power Mode` and stay on `ane`. Send me the log.
