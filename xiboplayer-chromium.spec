%global debug_package %{nil}

Name:           xiboplayer-chromium
Version:        0.7.23
Release:        1%{?dist}
Summary:        Self-contained Xibo digital signage player (Chromium kiosk)

License:        AGPL-3.0-or-later
URL:            https://xiboplayer.org
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
BuildRequires:  nodejs >= 18

Requires:       (chromium or google-chrome-stable)
Requires:       nodejs >= 18
Requires:       jq
Requires:       curl
Requires:       systemd
Recommends:     xdotool
Recommends:     xset
Recommends:     unclutter

# Smooth upgrade from the old package name
Obsoletes:      xiboplayer-pwa < %{version}-%{release}
Provides:       xiboplayer-pwa = %{version}-%{release}

%description
Self-contained Xibo digital signage player for kiosk deployments.
Bundles the PWA player locally and serves it via a Node.js server,
then launches Chromium in kiosk mode. Only the CMS base URL is needed.

%prep
%setup -q -n %{name}-%{version}

%build
# Install Node.js server dependencies (fetches @xiboplayer/proxy + @xiboplayer/pwa)
cd server
npm install --production --no-optional 2>&1
cd ..

%install
# Server (Node.js + dependencies including bundled PWA)
install -Dm755 server/server.js %{buildroot}%{_libexecdir}/%{name}/server/server.js
cp server/package.json %{buildroot}%{_libexecdir}/%{name}/server/
cp -r server/node_modules %{buildroot}%{_libexecdir}/%{name}/server/

# Launch script
install -Dm755 launch-kiosk.sh \
    %{buildroot}%{_libexecdir}/%{name}/launch-kiosk.sh

# Wrapper in PATH
install -Dm755 /dev/stdin %{buildroot}%{_bindir}/%{name} << 'WRAPPER'
#!/bin/bash
exec %{_libexecdir}/xiboplayer-chromium/launch-kiosk.sh "$@"
WRAPPER

# Minimal config (copied to ~/.config/xiboplayer/ on first run)
install -Dm644 config.json \
    %{buildroot}%{_datadir}/%{name}/config.json

# Full config reference with all options documented
install -Dm644 config.json.example \
    %{buildroot}%{_docdir}/%{name}/config.json.example

# Documentation
install -Dm644 CONFIG.md \
    %{buildroot}%{_docdir}/%{name}/CONFIG.md
install -Dm644 README.md \
    %{buildroot}%{_docdir}/%{name}/README.md

# Config management scripts and templates
install -Dm755 configs/apply.sh \
    %{buildroot}%{_datadir}/%{name}/configs/apply.sh
install -Dm755 configs/clean.sh \
    %{buildroot}%{_datadir}/%{name}/configs/clean.sh
install -Dm644 configs/secrets.env.example \
    %{buildroot}%{_datadir}/%{name}/configs/secrets.env.example
for tmpl in configs/chromium-*.json; do
    install -Dm644 "$tmpl" \
        %{buildroot}%{_datadir}/%{name}/configs/$(basename "$tmpl")
done

# Systemd user service
install -Dm644 %{name}.service \
    %{buildroot}%{_userunitdir}/%{name}.service

# Desktop entry
install -Dm644 %{name}.desktop \
    %{buildroot}%{_datadir}/applications/%{name}.desktop

# Icon
install -Dm644 xiboplayer.png \
    %{buildroot}%{_datadir}/icons/hicolor/256x256/apps/xiboplayer.png

%files
%{_bindir}/%{name}
%{_libexecdir}/%{name}/
%{_datadir}/%{name}/
%{_docdir}/%{name}/
%{_userunitdir}/%{name}.service
%{_datadir}/applications/%{name}.desktop
%{_datadir}/icons/hicolor/256x256/apps/xiboplayer.png

%post
# Register alternatives (higher priority than Electron)
alternatives --install %{_bindir}/xiboplayer xiboplayer %{_bindir}/%{name} 60

touch --no-create %{_datadir}/icons/hicolor &>/dev/null || :
gtk-update-icon-cache %{_datadir}/icons/hicolor &>/dev/null || :

echo ""
echo "  Xibo Player (Chromium) installed."
echo ""
echo "  1. Run 'xiboplayer-chromium' once — creates ~/.config/xiboplayer/config.json"
echo "  2. Edit ~/.config/xiboplayer/config.json — set cmsUrl to your CMS address"
echo "  3. systemctl --user enable --now xiboplayer-chromium.service"
echo ""

%preun
if [ "$1" -eq 0 ]; then
    alternatives --remove xiboplayer %{_bindir}/%{name}
    echo "  Remember to: systemctl --user disable --now %{name}.service"
fi

%postun
if [ $1 -eq 0 ] ; then
    touch --no-create %{_datadir}/icons/hicolor &>/dev/null
    gtk-update-icon-cache %{_datadir}/icons/hicolor &>/dev/null || :
fi

%changelog
* Wed Nov 18 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.23-1
- Build RPMs for Fedora 44 and 45; bump @xiboplayer/* to 0.7.23

* Thu Apr 16 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.22-1
- Datasource package with dedup/cache/offline, @xiboplayer/expr XPath runtime + xp:state store, xpIf runtime gating in renderer, setSyncGroup API with layout-tag sync bridge, window.xpDatasource in widget iframe context

* Thu Apr 16 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.21-1
- GPU fix followup: lower best_rank init so virtio rank -1 is selectable (bug in 0.7.20 virtual-GPU detection)

* Thu Apr 16 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.20-1
- GPU detection: virtio-gpu / QEMU / VMware SVGA force software rendering to avoid crash loop (MODE_CREATE_DUMB EACCES). Real GPUs unchanged. Opt-out via XIBOPLAYER_FORCE_GPU=1.

* Tue Apr 14 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.19-1
- Stability fixes + chromium instrumentation: proxy crash on closed client stream, stale-cache age log calculation, chromium launcher renderer log forwarding, SECURITY.md, SBOM CI.

* Sun Apr 12 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.18-1
- Layout transitions and xmds reliability fixes

* Wed Apr 08 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.17-1
- Fix CmsApiClient.uploadMediaUrl to target /library/uploadUrl (xibo-players/xiboplayer#332). BREAKING: signature changes to uploadMediaUrl(url, type, {optionalName}).

* Sat Apr 04 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.15-1
- Security fixes (XSS, TLS bypass, secret redaction), bug fixes (EventEmitter.once, GPU sort, insertCSS leak, dead deps), shared GPU/memory module, popup suppression, Chromium memory tier sync

* Sat Apr 04 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.14-1
- Security fixes (XSS, TLS), bug fixes (EventEmitter, GPU sort, insertCSS, dead deps), shared GPU module

* Thu Apr 02 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.13-1
- Integration tests, overlay tests, Docker Compose CMS stack, nightly CI

* Thu Apr 02 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.12-1
- Split Vite builds for SW isolation, major dependency upgrades (vite 8, typescript 6, pdfjs-dist 5), PDF worker fix, e2e port fix

* Wed Apr 01 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.11-1
- Optional XIBOPLAYER_DEBUG_PORT for CDP monitoring, player selection wizard, relative setup.html path

* Mon Mar 30 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.10-1
- ContentStore deferred on first boot, unclutter Recommends, Ed25519 GPG key

* Sun Mar 29 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.9-1
- GPU rasterization (91% to 5% CPU), preload race fix, 512x512 tiles

* Fri Mar 27 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.8-1
- GPU auto-detection, layout stall fix, HLS/iframe cleanup, GPU crash recovery, config packaging in RPM/DEB

* Thu Mar 26 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.7-1
- Triple preload fix, video GPU buffer release, stripped Chrome services for stable Chromium kiosk

* Wed Mar 25 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.6-1
- Timer deferral fix, offline playback, download/cache race fixes, Electron 41 with --no-zygote GPU fix, Chromium kiosk optimization

* Tue Mar 24 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.5-2
- Optimize kiosk: disable extensions and spare renderer process
- Removes GNOME browser connector, prevents idle renderer accumulation

* Mon Mar 23 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.5-1
- Store protocol 204, zero console errors, logger override, timeline badge fix

* Sun Mar 22 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.4-1
- Preloaded video autoplay and duration tracking fix, refactoring, 1629 tests

* Sat Mar 21 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.3-1
- Safe chunked download chain: write locks, timeout scaling, auth persistence (#285)

* Fri Mar 20 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.2-1
- Shared content cache across instances, startup layout storm fix, Playwright e2e tests, POST /config controls fix, cache migration via hardlinks

* Thu Mar 19 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.1-1
- mDNS auto-discovery for zero-config video walls, CORE_EVENTS constants, shared openIDB helper, setup.html Electron fix

* Tue Mar 17 2026 Pau Aliagas <linuxnow@gmail.com> - 0.7.0-1
- Cross-device multi-display sync with <8ms precision, 12 choreography effects, token-authenticated WebSocket relay, unified prepare/show layout flow, sync status overlay, setup focus fix, instance-aware Chromium data dirs

* Fri Mar 13 2026 Pau Aliagas <linuxnow@gmail.com> - 0.6.13-1
- fix: serve XMDS dependencies from media/file fallback, fix CMS custom volume mount persistence

* Fri Mar 13 2026 Pau Aliagas <linuxnow@gmail.com> - 0.6.12-1
- XMDS file download caching, idempotent cache-through architecture, X-Cms-Download-Url header for XMDS-only CMSes, fix layout XLF 500 errors on XMDS transport

* Thu Mar 12 2026 Pau Aliagas <linuxnow@gmail.com> - 0.6.11-1
- Native XMR client replacing upstream framework, DataConnector refreshAll fix, timeline overlay duration fix, AGPL-3.0 license, clientCode 400 registration

* Sun Mar 08 2026 Pau Aliagas <linuxnow@gmail.com> - 0.6.8-1
- Fix double layoutEnd emit, HTTP 304 retry bug, XLF media cache check, double-pop race, proxy stale-cache fallback, add proxy response timing and log timestamps

* Sun Mar 08 2026 Pau Aliagas <linuxnow@gmail.com> - 0.6.7-1
- fix: store layout durations as write-once facts, prevent startup double-pop

* Sat Mar 07 2026 Pau Aliagas <linuxnow@gmail.com> - 0.6.6-1
- Tiered screenshot capture (getDisplayMedia + html2canvas fallback), fix layout storm on fresh start via preparingLayoutId guard, fix timeline duration key mismatch, handle unconfigured CMS download window, HLS stream proxy, auto-approve screen capture in Chromium

* Fri Mar 06 2026 Pau Aliagas <linuxnow@gmail.com> - 0.6.5-1
- fix: eliminate XMR WebSocket connection leak, delegate reconnection to framework, add XMR disconnected warning in top bar

* Fri Mar 06 2026 Pau Aliagas <linuxnow@gmail.com> - 0.6.4-1
- Features: cross-device sync, shell commands, per-CMS storage, video controls. Fixes: FD leak, V8 OOM, video duration, timeline overlay. Refactor: canonical /player/api/v2 path, CmsClient interface.

* Thu Mar 05 2026 Pau Aliagas <linuxnow@gmail.com> - 0.6.3-1
- Canvas regions, protocol auto-detect, persistent durations, XIC handlers, download resume, vitest 4 upgrade

* Wed Mar 04 2026 Pau Aliagas <linuxnow@gmail.com> - 0.6.2-1
- fix: expire current layout when schedule changes, fix: multi-widget playlist cycling, fix: layout background fallback for storedAs filenames, refactor: single source of truth for layout duration calculation

* Tue Mar 03 2026 Pau Aliagas <linuxnow@gmail.com> - 0.6.1-1
- feat: switch default clientType from chromeOS to linux, fix: keyboard shortcuts on Wayland and quit for Chromium kiosk, fix: replace globalShortcut with Menu accelerators for Wayland (Electron), refactor: use shared packaging library for build scripts, fix: remove per-build repo update trigger race conditions

* Mon Mar 02 2026 Pau Aliagas <linuxnow@gmail.com> - 0.6.0-1
- REST v2 transport with auto-detection, chunked download resume, shared config extraction (extractPwaConfig), cert warning overlay fix, download overlay fix

* Sun Mar 01 2026 Pau Aliagas <linuxnow@gmail.com> - 0.5.20-1
- Fix memory leaks: PDF single-canvas rendering with page.cleanup(), event listener cleanup on widget hide, HLS instance destroy, blob URL tracking

* Sat Feb 28 2026 Pau Aliagas <linuxnow@gmail.com> - 0.5.19-1
- PDF multi-page cycling, SSL cert relaxation (relaxSslCerts), configurable log levels, config passthrough fixes

* Sat Feb 28 2026 Pau Aliagas <linuxnow@gmail.com> - 0.5.18-1
- Fix proxy crash, improve kill patterns, forward proxy logs to DevTools

* Sat Feb 28 2026 Pau Aliagas <linuxnow@gmail.com> - 0.5.17-1
- Decouple Chromium from SDK monorepo, fix cache clearing

* Sat Feb 28 2026 Pau Aliagas <linuxnow@gmail.com> - 0.5.16-4
- Fall back to Google Chrome when Chromium binary is not found
- Add --server-dir, --pwa-path and --no-kiosk CLI options for development

* Fri Feb 27 2026 Pau Aliagas <linuxnow@gmail.com> - 0.5.16-3
- Install default config.json (not config.json.example) for first-run copy
- Install full config reference and docs (CONFIG.md, README.md) to /usr/share/doc
- Add webcam/microphone capture policies (VideoCaptureAllowed, AudioCaptureAllowed)
- Add optional Google Geolocation API key support (googleGeoApiKey)
- Add config.json controls for keyboard shortcuts and mouse hover
- Add transport config option (auto/xmds) for unpatched Xibo CMS
