# SETUP_GUIDE.md — Getting AnxietyScope Onto Your Devices

This guide covers how to build, sign, and install a personal iOS/watchOS app on your own devices without publishing to the App Store. It also covers the Apple Developer Program, provisioning, and common pitfalls.

---

## Step 1: Apple Developer Account

You have two options:

### Option A: Free Apple ID (limited)

You can build and install apps on your own devices using just your Apple ID, but with significant limitations:
- Apps expire after **7 days** and must be reinstalled
- Maximum of **3 apps** simultaneously installed via this method
- No push notifications, CloudKit, or certain entitlements
- **HealthKit IS available** with a free account
- No TestFlight access

This works for initial development and testing but is impractical for daily use since you'd need to reinstall weekly.

### Option B: Apple Developer Program ($99/year) — RECOMMENDED

This is what you want for a personal-use app you'll run every day:
- Apps you install on your own devices **do not expire** (valid for the duration of your provisioning profile, typically 1 year, auto-renewable)
- Full access to all entitlements including HealthKit, push notifications, CloudKit, background modes
- **TestFlight access** — you can distribute to yourself (and up to 100 internal testers) without App Store review
- Up to **100 registered devices** for ad-hoc distribution

**To enroll:**
1. Go to https://developer.apple.com/programs/
2. Click "Enroll"
3. Sign in with your Apple ID
4. Pay $99/year
5. Enrollment is usually approved within 48 hours (sometimes instantly)

**This is the recommended path.** The $99/year is well worth it for the convenience of not reinstalling every 7 days.

---

## Step 2: Xcode Setup

### Install Xcode
1. Install Xcode from the Mac App Store (requires macOS Sonoma 14+ for latest iOS 17/watchOS 10 SDKs)
2. Open Xcode, go to **Xcode → Settings → Accounts**
3. Click **+** and add your Apple ID
4. If you enrolled in the Developer Program, your Team should appear with a "Team" role

### Create the Project
Claude Code will scaffold this, but for reference:
1. File → New → Project
2. Choose **iOS → App**
3. Product Name: `AnxietyScope`
4. Team: Select your developer team
5. Organization Identifier: `com.yourname` (e.g., `com.chrisdev`)
6. Interface: **SwiftUI**
7. Language: **Swift**
8. Storage: **SwiftData**
9. Check **Include Tests** if desired

### Add the watchOS Target
1. File → New → Target
2. Choose **watchOS → App**
3. Product Name: `AnxietyScopeWatch`
4. Make sure "Watch app for existing iOS app" is selected and your iOS app is the companion
5. Embed in companion: `AnxietyScope`

### Enable HealthKit
1. Select the **AnxietyScope** iOS target in the project navigator
2. Go to **Signing & Capabilities**
3. Click **+ Capability**
4. Add **HealthKit**
5. Check **Clinical Health Records** if you want to read clinical data in the future (optional)
6. Repeat for the **watchOS target** — the Watch app needs its own HealthKit entitlement

### Enable Background Modes (optional, for V2)
1. Add **Background Modes** capability
2. Enable: **Background fetch**, **Background processing**
3. This is needed for periodic HealthKit data aggregation and server sync

---

## Step 3: Install on Your iPhone

### Method A: Direct from Xcode (simplest for development)

1. Connect your iPhone to your Mac via USB (or use wireless debugging — see below)
2. In Xcode, select your iPhone from the device dropdown in the toolbar
3. Click the **Run** button (▶) or press `Cmd+R`
4. On first run, your iPhone may prompt you to **trust the developer certificate**:
   - Go to **Settings → General → VPN & Device Management** (or "Profiles & Device Management" on older iOS)
   - Find your developer certificate and tap **Trust**
5. The app installs and launches

**Wireless debugging** (so you don't need the cable every time):
1. Connect your iPhone via USB at least once
2. In Xcode, go to **Window → Devices and Simulators**
3. Select your iPhone and check **Connect via network**
4. After initial pairing, your iPhone appears in the device dropdown even without USB

### Method B: TestFlight (recommended for daily use)

TestFlight is Apple's official beta testing platform. Even for personal use, it's the most convenient distribution method because:
- Install/update directly on your phone without connecting to your Mac
- Apps last for **90 days** per build (just upload a new build before it expires)
- Automatic update notifications
- No device registration hassles

**Setup:**
1. In Xcode, select **Product → Archive**
2. When the archive completes, click **Distribute App**
3. Choose **TestFlight & App Store** (don't worry — uploading to TestFlight does NOT put it on the App Store)
4. Follow the prompts to upload to App Store Connect
5. Go to https://appstoreconnect.apple.com
6. Navigate to **My Apps → AnxietyScope → TestFlight**
7. The build will appear after processing (usually 10-30 minutes)
8. Under **Internal Testing**, create a group and add yourself
9. You'll receive an email/notification to install via the TestFlight app on your iPhone

**Important:** TestFlight builds go through **automated checks** (not human review) that look for crashes, malware, and basic policy violations. A personal health tracking app will pass these without issue. There's no App Store review process for TestFlight internal testing.

### Method C: Ad Hoc Distribution

For completeness, you can also create an ad-hoc signed IPA file:
1. Register your device UDID in the Apple Developer portal
2. Create an ad-hoc provisioning profile
3. Archive in Xcode and export with ad-hoc signing
4. Install via Apple Configurator, Finder, or AirDrop

This is more cumbersome than TestFlight and mainly useful if you want to share with a small number of specific people.

---

## Step 4: Install on Your Apple Watch

The watchOS app installs **automatically** when you install the iOS app, as long as:

1. Your Apple Watch is paired with the iPhone the app is installed on
2. The watchOS target is properly embedded in the iOS target (configured in Xcode project settings)
3. Automatic app installation is enabled on the Watch:
   - On your iPhone, open the **Watch** app
   - Go to **General → Automatic App Install** — make sure it's on
   - Or manually find AnxietyScope in the Watch app and tap **Install**

**For development/debugging on the Watch:**
1. In Xcode's device dropdown, you'll see your Watch listed under your iPhone
2. Select the Watch scheme and run — Xcode will install and debug directly on the Watch
3. Watch debugging is slower than iPhone (deployment takes longer, logs are delayed)
4. First-time Watch deployment may take several minutes

**Troubleshooting Watch installation:**
- If the Watch app doesn't appear, check that the watchOS target's bundle ID follows the pattern `com.yourname.AnxietyScope.watchkitapp`
- Restart both devices if deployment fails
- Make sure both iPhone and Watch are on the same Wi-Fi network during development

---

## Step 5: Ongoing Maintenance

### Keeping the App Running

**With Developer Program ($99/year):**
- Your provisioning profiles last 1 year
- As long as you renew the Developer Program annually, your app keeps running
- If you let the membership lapse, apps installed via direct Xcode signing stop working after the profile expires
- TestFlight builds expire after 90 days regardless — just upload a new build periodically

**Updating the app:**
- Make changes in Xcode (or via Claude Code)
- Run on your device via Xcode, or archive and upload to TestFlight
- For TestFlight: new builds automatically notify you to update

### Certificates & Provisioning

Xcode manages certificates and provisioning profiles automatically when "Automatically manage signing" is checked in Signing & Capabilities. For a personal-use app, let Xcode handle this — manual provisioning is only needed for enterprise or complex multi-team scenarios.

If you ever see signing errors:
1. Go to **Xcode → Settings → Accounts → your team → Manage Certificates**
2. Delete any expired or revoked certificates
3. Xcode will create new ones automatically
4. Clean the build folder: **Product → Clean Build Folder** (`Cmd+Shift+K`)

---

## Step 6: Working with Claude Code

### Typical Workflow

1. **Open your terminal** in the project directory (the folder containing `AnxietyScope.xcodeproj`)
2. **Run Claude Code** — it will automatically read `CLAUDE.md` and `REQUIREMENTS.md` for context
3. **Ask Claude Code to implement features** from the build plan in `REQUIREMENTS.md`
4. **Build and test in Xcode** — switch to Xcode to run on your device
5. **Iterate** — if something doesn't work, paste the error back into Claude Code

### Tips for Claude Code + Xcode Projects

- Claude Code can create and edit `.swift` files directly
- Claude Code cannot run `xcodebuild` in most environments, so you'll build in Xcode
- If Claude Code creates new files, you may need to **add them to the Xcode project** manually (drag into the Project Navigator) unless they're in a folder reference that Xcode is already tracking
- For SwiftUI previews, build in Xcode — Claude Code can write the preview code but can't render it
- If you hit a HealthKit or watchOS issue, paste the exact error message and relevant code into Claude Code for debugging

### Recommended Claude Code Prompts to Get Started

After placing `REQUIREMENTS.md` and `CLAUDE.md` in your project root:

```
"Read REQUIREMENTS.md and CLAUDE.md, then create the SwiftData model files for all entities."

"Implement the HealthKitManager actor with authorization for all required types and a method to query the last 24 hours of HRV data."

"Create the journal entry view — a form with a severity slider (1-10), text field for notes, and a tag picker."

"Create the medication logging view with quick-log buttons for my active medications."

"Build the dashboard view showing today's HRV vs 30-day average, last night's sleep duration, and most recent anxiety entry."

"Implement the daily HealthSnapshot aggregation service that pulls yesterday's data from HealthKit into a SwiftData record."

"Create a data export service that writes all SwiftData entities to a JSON file and presents a share sheet."
```

---

## Appendix A: Device IDs and Bundle Identifiers

Fill these in for your reference:

- **Bundle ID (iOS):** `com._________.AnxietyScope`
- **Bundle ID (watchOS):** `com._________.AnxietyScope.watchkitapp`
- **Team ID:** (found in Apple Developer portal → Membership)
- **iPhone UDID:** (found in Finder when iPhone is connected, or Xcode → Window → Devices)
- **Apple Watch UDID:** (found in Xcode → Window → Devices, listed under your iPhone)

---

## Appendix B: Cost Summary

| Item | Cost | Frequency | Required? |
|------|------|-----------|-----------|
| Apple Developer Program | $99 | Annual | Strongly recommended |
| Xcode | Free | — | Yes |
| Mac (for Xcode) | You have this | — | Yes |
| iPhone | You have this | — | Yes |
| Apple Watch Series 8 | You have this | — | Yes |
| Omron Evolv BP cuff | ~$80 | One-time | Tier 2 |
| SD card reader (for CPAP) | ~$12 | One-time | Tier 2 |
| Hilo Band | ~$280 | One-time + possible subscription | Tier 3, when available |

---

## Appendix C: Troubleshooting Common Issues

### "Untrusted Developer" on iPhone
Settings → General → VPN & Device Management → tap your certificate → Trust

### "Could not launch AnxietyScope" — device is locked
Unlock your iPhone before running from Xcode.

### HealthKit authorization sheet doesn't appear
- Verify HealthKit capability is added to BOTH the iOS and watchOS targets
- Check that `NSHealthShareUsageDescription` is in Info.plist
- HealthKit is not available in the iOS Simulator for all data types — test on a real device

### Watch app won't install
- Ensure watchOS deployment target matches your Watch's OS version
- Check that the Watch app is listed as a dependency of the iOS app
- Restart the Watch (hold side button → Power Off → Power On)
- In the Watch app on iPhone, scroll to AnxietyScope and tap Install manually

### "No signing certificate" or provisioning errors
- Xcode → Settings → Accounts → your team → Manage Certificates
- Delete expired certificates and let Xcode recreate them
- Product → Clean Build Folder, then rebuild

### TestFlight build stuck in "Processing"
- This usually resolves within 30 minutes
- If stuck longer, check App Store Connect for error messages
- Ensure your archive was built with a Release configuration
