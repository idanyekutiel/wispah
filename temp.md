# Notes

## Media Detection (mediaremote-adapter)

Since macOS 15.4, Apple blocks third-party apps from using `MediaRemote.framework` directly. The `mediaremoted` daemon now checks the bundle identifier of the calling process and only allows `com.apple.*` bundle IDs through.

We use [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3-Clause) to work around this. Here's how it works:

1. `/usr/bin/perl` is an Apple system binary with bundle ID `com.apple.perl`
2. A Perl script loads a compiled Objective-C framework (`MediaRemoteAdapter.framework`) via Perl's `DynaLoader`
3. That framework calls `MediaRemote.framework` APIs to check if media is playing
4. Since `mediaremoted` sees the process as `com.apple.perl`, access is granted
5. The result comes back as JSON on stdout — we parse the `"playing"` boolean

At runtime, Wispah runs:
```
/usr/bin/perl <app bundle>/Contents/Resources/mediaremote-adapter.pl <app bundle>/Contents/Resources/MediaRemoteAdapter.framework get
```

### Build setup

The framework needs to be compiled once from the cloned repo (lives at `../mediaremote-adapter`):
```bash
cd ../mediaremote-adapter
mkdir -p build && cd build
cmake .. && cmake --build .
```

The Makefile automatically copies the built framework + Perl script into the app bundle on every build.

### Licensing

- Wispah: MIT
- mediaremote-adapter: BSD-3-Clause (compatible with MIT)
- Full license text in `THIRD_PARTY_LICENSES.md`
