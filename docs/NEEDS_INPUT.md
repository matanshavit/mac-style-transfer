# Needs your input

Things I cannot do or decide alone. Most important first.

1. **Apple Developer Program (paid, $99/yr).** Needed to install StyleCam's camera, even just on your own Mac. Free Personal Teams cannot get the System Extension entitlement ([Apple capability table](https://developer.apple.com/help/account/reference/supported-capabilities-macos)). After you enroll:
   - Sign in to Xcode (Settings > Accounts).
   - Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your team ID.
   - Build once from Xcode so it creates the provisioning profile, then `make install`.
   - Open StyleCam from `/Applications`, allow the camera, and click Install in the Virtual Camera section.
   - Allow the extension in System Settings > General > Login Items & Extensions > Camera Extensions.
   - Pick StyleCam as the camera in Zoom, Meet or FaceTime. Tell me what you see, including self-view mirroring.
2. **No-$99 path: OBS Virtual Camera (experimental, untested).** OBS is free and its camera extension is signed by OBS, so StyleCam can send its video there. OBS is not installed here, so I could not test it.
   - Install OBS Studio from [obsproject.com](https://obsproject.com/download) into `/Applications`.
   - Open OBS and click Start Virtual Camera. Allow OBS in System Settings > General > Login Items & Extensions > Camera Extensions. If OBS still says the camera is not installed, restart OBS and click it again.
   - Quit OBS.
   - Quick check, with StyleCam quit: `make cli`, then `Packages/StyleKit/.build/release/stylecam-cli push-test --name "OBS Virtual Camera" --seconds 30`, and open Photo Booth or Zoom with OBS Virtual Camera. You should see a moving bar and a frame counter.
   - Run StyleCam (`make build`, then `open build/DerivedData/Build/Products/Debug/StyleCam.app`), allow the camera, and set Virtual Camera > Output to OBS. The status should say Connected to OBS. Choose OBS Virtual Camera in Zoom.
   - Open OBS. StyleCam should say OBS is open, and OBS's own virtual camera should work. Quit OBS, and StyleCam's video should come back.
   - Send me what you see at each step (video, OBS placeholder or black) and the push-test output.
3. **Copyrighted styles.** Christina's World (Wyeth, died 2009) and O'Keeffe's "Music, Pink and Blue No. 2" (from the old app) are still under copyright in many places, so I left them out of the repo. You can still add them from a link in the app. OK?
4. **A look at the real UI.** I checked the app with window snapshots and a text dump of the main menu. They cannot show the toolbar, the menu bar menu, the Settings window, alerts or the live camera. Please open the app once and check those, and try Open at login in Settings (the window should stay closed after you log in).
5. **Auto quality on battery.** I cannot unplug the Mac or turn on Low Power Mode from here. Run `stylecam-cli run --models Models --styles Styles --style starry_night --input <file.y4m> --out /tmp/out.mp4 --realtime --quality auto --log-adaptive` on battery and with Low Power Mode on. It should print `on battery` or `Low Power Mode` and stay on `ane`. Send me the log.
