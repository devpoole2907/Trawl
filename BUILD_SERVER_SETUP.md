# Setting up the spare M1 Max as a Trawl build and test server

This guide turns the cracked-screen M1 Max into a second machine for building and
testing Trawl, so Claude and Codex stop queueing for one simulator.

You'll work through it once, sitting at the machine (or using Screen Sharing). It takes
about an hour, most of it waiting for the Xcode and simulator downloads. Everything
after that happens over SSH.

---

## What you get

| | This Mac (main) | Build server (spare M1 Max) |
|---|---|---|
| Xcode open, your day-to-day work | ✅ | – |
| Unit tests, quick builds | ✅ | ✅ |
| iPhone UI suite | ✅ | ✅ |
| iPad UI suite, full test plan | waits its turn today | ✅ runs at the same time |
| Device builds to the Duo | ✅ (signing lives here) | not needed |
| A Claude or Codex session working on its own | – | ✅ |

**Why this helps.** Only one simulator test run can go at a time on a Mac. Two at once
fake crashes and leave result bundles unfinished, which is why
`Scripts/run-ui-tests.sh` runs iPhone, then iPad. With two Macs, each half gets its own
machine: a full run takes about half as long, and Codex can test while Claude builds.

Both machines are M1 Max, so neither is the slow one.

---

## Checklist

- [ ] 1. Power and hardware (lid open, Ethernet, never sleeps)
- [ ] 2. macOS 27.2.x, a fixed name, automatic login
- [ ] 3. Remote Login (SSH) and Screen Sharing turned on
- [ ] 4. SSH key from this Mac, and `ssh trawl-builder` works
- [ ] 5. Xcode **27.2 (27B52)**, plus the iOS 26.4 and 27.2 simulators
- [ ] 6. Homebrew, `gh`, git identity
- [ ] 7. Repo cloned to `~/Developer/Trawl` (**not** Documents or iCloud)
- [ ] 8. One build and one UI test run, approved once from the server's own screen
- [ ] 9. Server can reach the test servers on your network
- [ ] 10. Claude app: SSH connection saved; Codex installed (optional)
- [ ] 11. Send me the four details at the bottom

---

## 1. Hardware and power

- **Leave the lid open.** A MacBook with its lid closed and no external display goes to
  sleep, whatever its settings say. Turn the brightness to zero instead; step 2 below
  turns the display off after a minute.
- **Use Ethernet if you can** (a USB-C adapter is fine). Wi-Fi works, but pulling the
  repo and downloading simulators is faster and steadier on a cable.
- **Plug in the charger permanently.** Then protect the battery:
  - System Settings › Battery › (ⓘ next to Battery Health or Charging) › turn on
    **Optimised Battery Charging**.
  - If your macOS version offers a **charge limit**, set it to 80%.

  A laptop that sits at 100% all day for months will swell its battery. If the battery
  ever looks puffy, stop using the machine.
- **The cracked screen doesn't matter.** Once step 3 is done you'll use it through
  Screen Sharing from this Mac. Until then, plug in an external display if the cracked
  one is hard to read.

## 2. macOS: version, name, sleep and login

**Update macOS** to the same version as this Mac, which is **macOS 27.2.1** (System
Settings › General › Software Update). Different macOS versions have produced
different simulator behaviour before (the 27.0 beta crashed the simulator panel on
every frame).

**Give the machine a fixed name.** Run these in Terminal on the server:

```bash
sudo scutil --set ComputerName "trawl-builder"
```

```bash
sudo scutil --set LocalHostName "trawl-builder"
```

```bash
sudo scutil --set HostName "trawl-builder"
```

This Mac can then reach it as `trawl-builder.local`. Also give it a fixed address on
your router: a DHCP reservation for its MAC address. That way the `.local` name never
matters if it's flaky.

**Never sleep, turn the display off after a minute, and restart after a power cut:**

```bash
sudo pmset -a sleep 0 disksleep 0 displaysleep 1 powernap 0 autorestart 1 womp 1
```

To check it worked:

```bash
pmset -g
```

**Turn on automatic login** (System Settings › Users & Groups › Automatically log in
as). UI tests need a logged-in desktop session, not just SSH. Without one, the
simulator UI tests time out at "enabling automation mode".

> **FileVault note:** with FileVault on, macOS won't log in automatically. After a
> reboot or a power cut, the Mac waits at the unlock screen until someone types the
> password. Choose one:
> - Turn FileVault off on this machine. It's a build box with no personal data, but it
>   will hold a GitHub login (step 6), so consider that.
> - Keep FileVault on, and unlock it with a keyboard and display after any restart.

**Allow developer tools without a password prompt every time.** Run these on the
server:

```bash
sudo DevToolsSecurity -enable
```

```bash
sudo dscl . append /Groups/_developer GroupMembership "$USER"
```

## 3. Turn on remote access

System Settings › General › Sharing:

- **Remote Login: on.** Allow access for your user only.
- **Screen Sharing: on.** This is how you'll see the server's desktop from this Mac:
  Finder › Network › trawl-builder › Share Screen, or `open vnc://trawl-builder.local`.

## 4. SSH key from this Mac

This Mac already has a key (`~/.ssh/id_ed25519`). Run this **on this Mac**, swapping in
your username on the server:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub YOURUSER@trawl-builder.local
```

Then add this entry to `~/.ssh/config` **on this Mac** so plain `ssh trawl-builder`
works:

```
Host trawl-builder
    HostName trawl-builder.local
    User YOURUSER
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 30
```

To check it worked (it should print the macOS version with no password prompt):

```bash
ssh trawl-builder sw_vers
```

## 5. Xcode and simulators

Install **exactly Xcode 27.2, build 27B52**, the same as this Mac. Use the App Store,
or download it from developer.apple.com › Downloads if the App Store offers a newer
version. A different Xcode means "it passed on the server" doesn't mean it passes here.

Then run these on the server:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

```bash
sudo xcodebuild -license accept
```

```bash
xcodebuild -runFirstLaunch
```

To check it worked (it should print `Xcode 27.2` and `Build version 27B52`):

```bash
xcodebuild -version
```

**Simulator runtimes.** In Xcode › Settings › Components, download:

- **iOS 26.4**: what the test plan and CLAUDE.md target.
- **iOS 27.2**: what the iOS 27 search-tab work was checked on.

Skip the old 27.0 betas this Mac still has lying around.

**Create the devices the scripts look for by name:**

```bash
xcrun simctl create "iPhone 17 Pro" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-26-4
```

```bash
xcrun simctl create "iPad Pro 13-inch (M5)" "iPad Pro 13-inch (M5)" com.apple.CoreSimulator.SimRuntime.iOS-26-4
```

To check, list them; both names should appear under iOS 26.4:

```bash
xcrun simctl list devices available
```

## 6. Command-line tools

Install Homebrew (follow the command on brew.sh), then:

```bash
brew install gh node
```

```bash
gh auth login
```

```bash
git config --global user.name "James Poole"
```

```bash
git config --global user.email "YOUR-GITHUB-EMAIL"
```

`gh auth login` gives the server push and pull access to `devpoole2907/Trawl`. If you'd
rather it could only read, use a fine-grained token limited to that one repository with
read access to Contents. Work then reaches the server via branches I push from this
Mac, which it pulls.

## 7. Clone the repo, outside iCloud

```bash
mkdir -p ~/Developer && gh repo clone devpoole2907/Trawl ~/Developer/Trawl
```

**Don't put it in Documents or Desktop.** On this Mac, iCloud syncs those folders and
keeps creating `" 2"` conflict copies that break builds. Even now, git here is
reporting half-written objects inside `.git`. `~/Developer` isn't synced.

## 8. First build and first UI test, at the server's own screen

Do this once **at the server's desktop** (Screen Sharing is fine), not over plain SSH.
Each step brings up a one-time permission prompt you have to click.

1. Open `~/Developer/Trawl/Trawl.xcodeproj` in Xcode once. Let it finish indexing and
   resolving packages, then quit.
2. In Terminal on the server, build:

   ```bash
   cd ~/Developer/Trawl && xcodebuild -project Trawl.xcodeproj -scheme Trawl -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' -derivedDataPath ~/Developer/dd build-for-testing
   ```

3. Run one small UI suite. Accept any "allow automation" or accessibility prompt that
   appears on the server's screen:

   ```bash
   cd ~/Developer/Trawl && TRAWL_DERIVED_DATA=~/Developer/dd TRAWL_RESULTS_DIR=~/Developer/results Scripts/run-ui-tests.sh NavigationSmokeWalkUITests
   ```

4. Build the Mac app too. If it complains about signing, sign in with your Apple ID in
   Xcode › Settings › Accounts on the server, then rerun:

   ```bash
   cd ~/Developer/Trawl && xcodebuild -project Trawl.xcodeproj -scheme TrawlMac -destination 'platform=macOS' -derivedDataPath ~/Developer/ddmac build
   ```

Once step 3 has passed at the desktop, the same command works over SSH from this Mac.

## 9. Reach the test servers

The live sweeps (Sonarr, Radarr, Prowlarr, Bazarr, SABnzbd, qBittorrent, Jellyfin,
Seerr, Cleanuparr) run on your home network, so the server needs to be on the same
network. To check from the server (it should print `200`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://TEST-SERVER-ADDRESS:14089/ping
```

Don't copy any API keys onto it yourself. When a sweep needs them I'll pass them to the
test as a file and delete it afterwards, the same way I handle them on this Mac.

## 10. Let Claude and Codex work there

**Claude.** In the Claude desktop app, open the new-session location picker and **add
an SSH connection**. Point it at `trawl-builder`, the same host as your `~/.ssh/config`
entry, with `~/Developer/Trawl` as the default folder, and name it **trawl-builder**.
After that:

- you can start a session that runs on the server, and
- I can start one there myself for jobs like "run the full UI plan on the server while I
  keep building here".

Right now the app has no SSH connections saved, which is why I can't do this yet. If you
also want the command-line version on the server:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Then run `claude` once and sign in.

**Codex (optional).** Install it on the server, then sign in:

```bash
npm install -g @openai/codex
```

```bash
codex login
```

> **The Codex CLI on this Mac is currently broken.** `codex --version` crashes with
> `ENOENT … codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex`: the Homebrew
> npm install is missing its native binary. Reinstalling fixes it:
>
> ```bash
> npm uninstall -g @openai/codex && npm install -g @openai/codex
> ```
>
> If you use the Codex app rather than the CLI, it isn't affected.

## How the two Macs work together day to day

**Work moves as git branches, never as copied folders:**

1. I push a branch from this Mac: `git push origin HEAD:some-branch`.
2. The server runs it, for example:

   ```bash
   ssh trawl-builder 'cd ~/Developer/Trawl && git fetch -q && git checkout -q --detach origin/some-branch && TRAWL_DERIVED_DATA=~/Developer/dd TRAWL_RESULTS_DIR=~/Developer/results TRAWL_IPHONE_SIM="iPhone 17 Pro" Scripts/run-ui-tests.sh'
   ```

3. Results come back as the log plus `xcresulttool` counts over SSH. I don't trust a bare
   "TEST SUCCEEDED": `-only-testing` can match nothing and still print it.

**A sensible split:**

- **This Mac:** editing, unit suites, the iPhone UI chrome, device installs to the Duo.
- **Server:** the iPad UI chrome and the full plan at release checkpoints. It's also
  where Codex works when it's running alongside me, so we never share a simulator.

The rule of one simulator test run at a time still applies on each machine
separately. The gain is that there are now two machines.

Once the server exists, I'll add a `Scripts/remote-test.sh` wrapper that does step 2 and
pulls the results back. I'd rather write it against the real host than guess.

## Keeping it healthy

- **After Xcode updates:** update both Macs together, or neither. Recreate the
  simulators if the runtime changes.
- **Disk:** DerivedData and result bundles grow quickly. Monthly:

  ```bash
  rm -rf ~/Developer/dd ~/Developer/ddmac ~/Developer/results
  ```

  ```bash
  xcrun simctl delete unavailable
  ```

- **If a run hangs:** check `pgrep -x xcodebuild`. Use `-x`: `-f` also matches unrelated
  processes and once killed the wrong one. Shut the simulator down with
  `xcrun simctl shutdown all` before retrying.

---

## When you're done, send me these four things

1. The server's **username**, and that `ssh trawl-builder sw_vers` works from this Mac.
2. The **name of the SSH connection** you saved in the Claude app (ideally
   `trawl-builder`).
3. Whether **step 8.3's UI suite passed** at the server's desktop.
4. Whether **FileVault** is on or off, so I know if a power cut needs you in person.

With those, I'll write the remote test script, run the full plan split across both
Macs, and record the setup so future sessions know the server exists.
