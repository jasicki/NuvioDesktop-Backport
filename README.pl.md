# Nuvio macOS 10.13 High Sierra Compatibility Patch Backport

[![en](https://img.shields.io/badge/lang-en-blue.svg)](README.md)

Kompletny backport, warstwa kompatybilności (shim w Objective-C / C) oraz zestaw optymalizacji pozwalający na uruchomienie i płynne działanie aplikacji **Nuvio Desktop** (zbudowanej oryginalnie dla macOS 12+ Monterey / Ventura) na systemie **macOS 10.13.6 High Sierra** (wraz z silnikiem WebKit / Safari 11).

---

## Co naprawia ten projekt? (Funkcje)

1. **Uruchamianie binarek z macOS 12+ na macOS 10.13 (dyld & Objective-C Runtime):**
   - Konwersja w locie nowych list metod Objective-C (*Relative Method Lists* wprowadzonych w macOS 12) do klasycznego formatu `method_list_64_t` obsługiwanego przez `libobjc.A.dylib` w High Sierra.
   - Emulacja i bezpieczne zaślepki (stubs) dla brakujących klas i symboli z macOS 10.14–13.0:
     - `MPRemoteCommandCenter`, `MPNowPlayingInfoCenter`, `MPMediaItemArtwork` (MediaPlayer)
     - `NSWorkspaceOpenConfiguration`, `NSAppearanceNameDarkAqua`, `effectiveAppearance` (AppKit)
     - `MTLCommandBufferDescriptor`, `supportsFamily:`, `hasUnifiedMemory` (Metal API dla Skiko / Compose)
     - `CTFontManagerCreateFontDescriptorsFromData` (CoreText)
     - Funkcje `std::__1::__fs::filesystem` (C++17), `ffi_closure_alloc` oraz `___chkstk_darwin`.

2. **Pełna naprawa odtwarzacza wideo i akceleracja sprzętowa (libmpv & libplayer_bridge):**
   - Wymuszenie bezpośredniego dekodowania sprzętowego **`videotoolbox`** (zero-copy na GPU Intel HD / starszych kartach) oraz szybkich filtrów skalowania `bilinear`.
   - Obejście problemów ze starymi certyfikatami TLS/SSL na macOS 10.13 podczas pobierania zewnętrznych napisów (`sub-add`) poprzez automatyczny przechwyt i pobranie pliku przez systemowy `curl`.
   - Asynchroniczne zwalnianie kontekstu OpenGL/MPV (`mpv_render_context_free` i `mpv_terminate_destroy`) zapobiegające zawieszaniu (deadlockom) i crashom przy wychodzeniu z filmu do menu.

3. **Transpilator UI odtwarzacza w locie dla Safari 11 (WKWebView):**
   - Automatyczna transpilacja składni **ES2020+** w `controls.js` (`?.` Optional Chaining oraz `??` Nullish Coalescing) do klasycznego ES6.
   - Zamiana nieobsługiwanych w Safari 11 zdarzeń **Pointer Events** (`pointermove`, `pointerdown`, `pointerup`, `pointerleave`, `pointercancel`) na klasyczne zdarzenia myszy (`mousemove`, `mousedown`, `mouseup`, `mouseleave`) wraz z polyfillami dla `setPointerCapture` i `scrollIntoView`.
   - Natywny monitor ruchu myszy w AppKit (`NSEvent addLocalMonitorForEventsMatchingMask:`) zapewniający natychmiastowe wybudzanie interfejsu odtwarzacza po dotknięciu kursora.
   - Automatyczna konwersja nowoczesnego CSS w `controls.css` nieobsługiwanego przez Safari 11 (`clamp()`, `min()`, `max()`, `inset`, `aspect-ratio`, `:is()`, `place-items: center`, `gap` w CSS Grid i Flexbox) oraz przepisanie ikon SVG (`href` na `xlink:href`).

4. **Optymalizacja wydajności CPU / GPU:**
   - Ominięcie wolnego zapytania IPC `SLWindowListCopyWindowInfo` w `+[AWTWindow getTopmostWindowUnderMouseIDImpl:]` przy każdym ruchu myszką.
   - Wyłączenie kosztownych filtrów `backdrop-filter: blur(...)`, cieni i animacji tła obciążających starsze układy graficzne.

---

## Zawartość repozytorium

* **legacy_shim.m** – główny kod źródłowy biblioteki przechwytującej (Objective-C / C).
* **install_patch.sh** – interaktywny skrypt instalacyjny (Polski / Angielski) kompilujący bibliotekę i aplikujący poprawki do `/Applications/Nuvio.app`.
* **README.md** – dokumentacja w języku angielskim.
* **README.pl.md** – dokumentacja w języku polskim.

---

## Instalacja

### Wymagania:
* System **macOS 10.13.6 High Sierra**
* Zainstalowane narzędzia wiersza poleceń Xcode (**Xcode Command Line Tools** – kompilator `clang`)
* Zainstalowana aplikacja **Nuvio.app** w katalogu `/Applications/Nuvio.app`

### Kroki instalacji w Terminalu:

    git clone https://github.com/YOUR_USERNAME/Nuvio-macOS-10.13-High-Sierra-Compatibility-Patch-Backport.git
    cd Nuvio-macOS-10.13-High-Sierra-Compatibility-Patch-Backport
    chmod +x install_patch.sh
    ./install_patch.sh

Wybierz język instalatora za pomocą strzałek na klawiaturze i zatwierdź klawiszem **Enter**. Po zakończeniu działania skryptu uruchom **Nuvio** normalnie z folderu Aplikacje (Applications).

---

## Licencja
MIT License