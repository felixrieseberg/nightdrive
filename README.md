# Nightdrive

It's 2026, I got an old iPod again, and I want an old-school-but-good app
to play and sync my music. I'm nostalgic but not really stuck in the past, I
want a native player written in modern Swift that _feels_ like a modern app.
This is my take on a media player with bi-directional iPod syncing and a
visualizer deck that hopefully reminds you of fancy car stereos in the
1990s and 2000s.

Features:

- Play and browse a folder-based audio library, with (smart) playlists,
  queues, favorites, ratings, audiobook support, and listening history
- Podcast subscriptions and management using Apple's podcasts API
- Find and fix duplicates, missing metadata, artwork, and disorganized files
- Two-way syncing with classic iPods, including mini, nano, Classic, and shuffle
- Automatically convert formats an iPod cannot play, without modifying originals
- A fold-down VFD deck with visualizers, themed colourways, and a detachable
  floating mini-player. You can build your own via plugins!
- Fully native and performant macOS app
- Free without accounts, ads, or subscriptions. It's
  [open-source](https://github.com/felixrieseberg/nightdrive), too.

# Install
Download the newest build from
[the releases page](https://github.com/felixrieseberg/nightdrive/releases/latest),
or grab
[Nightdrive.zip](https://github.com/felixrieseberg/nightdrive/releases/latest/download/Nightdrive.zip)
directly. The app auto-updates by default.

# Build from source
You need the Swift 6.3 toolchain (it ships with Xcode) and Node.js, which the
build scripts use. Then:

```bash
make run    # build the app and launch it
make test   # run the tests
make help   # list all commands
```

# iPod Support
Nightdrive supports mass-storage iPods from 1G through 5.5G, both minis,
photo/color, nano 1G–5G, Classic 6G/7G, and shuffle 1G–4G. Nano 5G devices
must first have been initialized with Apple's iPod software so their
firmware-specific database and signing material exist. Shuffle 3G/4G sync
tracks and playlists using their newer play-order database. Shuffle 1G/2G sync
tracks using their original play-order format, which does not carry playlists.
Nightdrive does not generate spoken VoiceOver labels for shuffle 3G/4G.
