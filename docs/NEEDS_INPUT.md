# Needs your input

Things I cannot do or decide alone. Most important first.

Done: developer team set up (`Config/Local.xcconfig`, gitignored), `make install` signs and installs, the camera extension is approved, and Photo Booth shows the stylized video through the StyleCam camera.

1. **Try a real call.** Pick StyleCam in FaceTime, Zoom or Meet. Tell me how smooth it looks, and whether the other side sees it the right way round (your own preview is mirrored by the call app, which is normal).
2. **A look at the real UI.** Window snapshots cannot show the toolbar, the menu bar menu, the Settings window or alerts. Please check those, and try Open at login in Settings (the window should stay closed after you log in).
3. **Copyrighted styles.** Christina's World (Wyeth, died 2009) and O'Keeffe's "Music, Pink and Blue No. 2" (from the old app) are still under copyright in many places, so they are not in the repo. You can still add them from a link in the app. OK?
4. **Auto quality on battery.** I cannot unplug the Mac or turn on Low Power Mode from here. Run `stylecam-cli run --models Models --styles Styles --style starry_night --input <file.y4m> --out /tmp/out.mp4 --realtime --quality auto --log-adaptive` on battery and with Low Power Mode on. It should print `on battery` or `Low Power Mode` and stay on `ane`. Send me the log.
5. **OBS output (optional, untested).** Only useful on a Mac without the StyleCam camera. Steps are in the app's Virtual Camera section when Output is set to OBS.
