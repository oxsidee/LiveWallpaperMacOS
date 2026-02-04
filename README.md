> [!NOTE]
> ## I’ll be Transformin Objective C++ UI's to SwiftUI.But ```daemon``` won't change.

# LiveWallpaper App for MacOS 26+


![Roller](./asset/livewall.png)

This is an open-source live wallpaper applicationn for MacOS 26+

<!-- ## Install using brew

Run this on terminal `brew tap thusvill/livewallpaper && brew install --cask livewallpaper` -->

## Guide for DMG Installation

> [!IMPORTANT]
> ## Fix “LiveWallpaper.app” is corrupted and cannot be opened. It is recommended that you move the object to the recycle bin.
> After you install the app in Application folder you have to bypass Gatekeeper for run this(I don't want to pay apple for opensource apps)
> 
> This will solve the occupation issue
> 
> `xattr -d com.apple.quarantine /Applications/LiveWallpaper.app` 

Click the OpenInFinder button and it'll open a folder, you can place wallpapers in it.

> [!NOTE]
> no dots should be contained on the file name exept the dot for extension
> 
> ## Eg-:
> 
>  - file.1920x1080.mp4 ❌ ('.'s > 1)
> 
>  - file-1920x1080.mp4 ✅ ('.'s = 1)

> [!NOTE]
> Currently support for `.mp4` and `.mov`

> https://github.com/user-attachments/assets/3d82e07d-b6b9-4a7d-b6de-5dd05dff3128

## Gallery

> ![Application](./asset/application.png)

> ## This is a static image, Currently this app doesn't support live wallpapers on lock screen.
> ![lockscreen](./asset/lockscreen.png)

> ![settings](./asset/settings.png)

> https://github.com/user-attachments/assets/36fb169e-b7cc-4489-9459-dab07c8dd2c6




> # Preformace
> ![p1](./asset/preformance1.png)
> ![p2](./asset/preformance2.png)
> ![p3](./asset/preformance3.png)
> # Multiple Display Support

> https://github.com/user-attachments/assets/9575873c-79e6-4eba-a7a5-9408b2cc4ed0






## Building from Source

### Requirements
- macOS 15.0+ (Sequoia)
- Xcode 16+
- Git

### Build Steps

1. **Clone the repository**
   ```bash
   git clone https://github.com/thusvill/LiveWallpaperMacOS.git
   cd LiveWallpaperMacOS
   ```

2. **Open in Xcode**
   ```bash
   open LiveWallpaper.xcodeproj
   ```

3. **Build the project**
   - In Xcode: `Product → Build` (or press `Cmd+B`)
   - Or from terminal:
     ```bash
     xcodebuild -project LiveWallpaper.xcodeproj -scheme LiveWallpaper -configuration Debug build
     ```

4. **Run the app**
   - In Xcode: `Product → Run` (or press `Cmd+R`)
   - Or find the built app in `DerivedData/LiveWallpaper/Build/Products/Debug/`

### Creating a Release Build

1. **Archive the project**
   ```bash
   xcodebuild -project LiveWallpaper.xcodeproj \
     -scheme LiveWallpaper \
     -configuration Release \
     -archivePath build/LiveWallpaper.xcarchive \
     archive
   ```

2. **Export the app** (requires signing configuration)
   - In Xcode: `Product → Archive`, then `Distribute App`
   - Or manually create a DMG from the archived app

### Publishing a Release on GitHub

1. **Create a version tag**
   ```bash
   git tag -a v1.x.x -m "Release v1.x.x"
   git push origin v1.x.x
   ```

2. **Create a release using GitHub CLI**
   ```bash
   # Zip the app
   cd build/Release
   zip -r LiveWallpaper.zip LiveWallpaper.app

   # Create release
   gh release create v1.x.x LiveWallpaper.zip \
     --title "LiveWallpaper v1.x.x" \
     --notes "Release notes here"
   ```

3. **Or create a release manually**
   - Go to GitHub → Releases → Draft a new release
   - Select the tag, add release notes
   - Upload the zipped app or DMG

<!-- ## Gallery
> <img width="185" height="134" alt="Screenshot 2025-11-30 at 1 52 01 PM" src="https://github.com/user-attachments/assets/0c91fb29-e729-485b-8f93-7080aed68881" />
> <img width="185" height="134" alt="Screenshot 2025-11-30 at 1 51 53 PM" src="https://github.com/user-attachments/assets/7848d2fd-8cc4-4271-a4c0-2868bdf00422" />
 



> ![Screenshot 2025-05-15 at 6 46 35 AM](https://github.com/user-attachments/assets/167b0c08-454f-4d53-9e65-8798aed6459f)

> <img width="2560" height="1600" alt="Screenshot 2025-11-30 at 1 52 34 PM" src="https://github.com/user-attachments/assets/79a24ed8-cc5a-4246-87d0-9c93e04766f2" />

> <img width="2560" height="1600" alt="Screenshot 2025-11-30 at 1 54 35 PM" src="https://github.com/user-attachments/assets/10466b02-77d5-4814-9fb7-a865e62a41ba" />

 

> https://github.com/user-attachments/assets/748c7078-1f99-4182-876f-08aa59d2bc63 -->
 

For license details, see [LICENSE](LICENSE).
