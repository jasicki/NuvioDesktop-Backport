# Nuvio macOS 10.13 High Sierra Compatibility Patch Backport

[![pl](https://img.shields.io/badge/lang-pl-red.svg)](README.pl.md)

Complete backport, compatibility layer (Objective-C / C shim), and performance mod allowing **Nuvio Desktop** (originally built for macOS 12+ Monterey / Ventura) to run smoothly on **macOS 10.13.6 High Sierra** (with legacy WebKit / Safari 11).

---

## Features & Fixes

1. **Running macOS 12+ Binaries on macOS 10.13 (dyld & Objective-C Runtime):**
   - On-the-fly conversion of modern Objective-C *Relative Method Lists* (introduced in macOS 12) into the classic `method_list_64_t` structure supported by `libobjc.A.dylib` on High Sierra.
   - Emulation and safe stubs for missing classes and symbols from macOS 10.14–13.0:
     - `MPRemoteCommandCenter`, `MPNowPlayingInfoCenter`, `MPMediaItemArtwork` (MediaPlayer)
     - `NSWorkspaceOpenConfiguration`, `NSAppearanceNameDarkAqua`, `effectiveAppearance` (AppKit)
     - `MTLCommandBufferDescriptor`, `supportsFamily:`, `hasUnifiedMemory` (Metal API for Skiko / Compose)
     - `CTFontManagerCreateFontDescriptorsFromData` (CoreText)
     - `std::__1::__fs::filesystem` (C++17), `ffi_closure_alloc`, and `___chkstk_darwin`.

2. **Video Player Fixes & Hardware Acceleration (libmpv & libplayer_bridge):**
   - Forces direct **`videotoolbox`** hardware decoding (zero-copy on Intel HD / legacy GPUs) and fast `bilinear` scaling filters.
   - Bypasses legacy TLS/SSL certificate issues on macOS 10.13 when fetching external subtitles (`sub-add`) by intercepting requests and downloading subtitle files via system `curl`.
   - Asynchronous OpenGL/MPV context teardown (`mpv_render_context_free` and `mpv_terminate_destroy`) preventing deadlocks and crashes when exiting playback.

3. **On-the-fly Safari 11 Player UI Transpiler (WKWebView):**
   - Automatic transpilation of **ES2020+** syntax in `controls.js` (`?.` Optional Chaining and `??` Nullish Coalescing) to ES6.
   - Converts unsupported **Pointer Events** (`pointermove`, `pointerdown`, `pointerup`, `pointerleave`, `pointercancel`) into classic mouse events (`mousemove`, `mousedown`, `mouseup`, `mouseleave`) with polyfills for `setPointerCapture` and `scrollIntoView`.
   - Native AppKit mouse movement monitor (`NSEvent addLocalMonitorForEventsMatchingMask:`) ensuring instant player UI wake-up on cursor movement.
   - Automatic conversion of modern CSS in `controls.css` unsupported by Safari 11 (`clamp()`, `min()`, `max()`, `inset`, `aspect-ratio`, `:is()`, `place-items: center`, `gap` in CSS Grid and Flexbox) and SVG icon attributes (`href` to `xlink:href`).

4. **CPU / GPU Performance Optimizations:**
   - Bypasses slow IPC window queries (`SLWindowListCopyWindowInfo`) inside `+[AWTWindow getTopmostWindowUnderMouseIDImpl:]` on every mouse move.
   - Disables expensive `backdrop-filter: blur(...)` effects, shadows, and background animations that bottleneck older GPUs.

---

## Repository Structure

* **legacy_shim.m** – main Objective-C / C compatibility shim source code.
* **install_patch.sh** – interactive installer script (English / Polish) that compiles the shim and patches `/Applications/Nuvio.app`.
* **README.md** – documentation in English.
* **README.pl.md** – documentation in Polish.

---

## Installation

### Requirements:
* **macOS 10.13.6 High Sierra**
* **Xcode Command Line Tools** installed (`clang` compiler)
* **Nuvio.app** installed in `/Applications/Nuvio.app`

### Installation Steps in Terminal:

    git clone https://github.com/YOUR_USERNAME/Nuvio-macOS-10.13-High-Sierra-Compatibility-Patch-Backport.git
    cd Nuvio-macOS-10.13-High-Sierra-Compatibility-Patch-Backport
    chmod +x install_patch.sh
    ./install_patch.sh

Select your preferred language in the interactive installer using the arrow keys and press **Enter**. Once completed, launch **Nuvio** normally from the Applications folder.

---

## License
MIT License