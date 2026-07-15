#!/bin/bash
#
# build_dosbox_appimage.sh
#
# Packages a legacy DOSBox Daum linux build (e.g. from ykhwong.x-y.net) into
# an AppImage, bundling an old Ubuntu-era libasound.so.2 so it runs on modern
# distros that lack the (now largely obsolete) plain ALSA runtime package.
#
# USAGE:
#   1. Download and extract the Dosbox Daum build somewhere, e.g. ~/dosbox-daum/
#      It should contain a "dosbox" executable (and usually dosbox.conf, langs, etc).
#   2. Run:  ./build_dosbox_appimage.sh /path/to/extracted/dosbox-daum-folder
#   3. Output: DOSBox-Daum-<arch>.AppImage in the current directory.
#
# Requires: bash, curl, dpkg-deb, wget or curl, awk, file, fuse (to run the
# result) or use --appimage-extract-and-run if FUSE isn't available.

set -euo pipefail

SRC_DIR="${1:-}"
if [[ -z "$SRC_DIR" || ! -d "$SRC_DIR" ]]; then
    echo "Usage: $0 /path/to/extracted/dosbox-daum-folder"
    echo "  (the folder must contain the 'dosbox' executable)"
    exit 1
fi
SRC_DIR="$(cd "$SRC_DIR" && pwd)"   # make absolute; script cd's elsewhere later

DOSBOX_BIN=$(find "$SRC_DIR" -maxdepth 2 -type f -iname 'dosbox' | head -n1)
if [[ -z "$DOSBOX_BIN" ]]; then
    echo "Could not find a 'dosbox' executable under $SRC_DIR"
    exit 1
fi
echo "Found dosbox binary: $DOSBOX_BIN"

# --- Detect architecture -----------------------------------------------
# NOTE: the payload (dosbox binary) architecture and the AppImage *runtime
# stub* architecture are two different things. The runtime stub is what
# actually executes on the host to mount the squashfs and run AppRun, so it
# must match the HOST's CPU (almost always x86_64 for a modern machine),
# regardless of whether the payload inside is 32-bit or 64-bit.
FILE_OUT=$(file -b "$DOSBOX_BIN")
echo "file: $FILE_OUT"
if echo "$FILE_OUT" | grep -qi '32-bit'; then
    DEB_ARCH="i386"
    NEEDS_32BIT_LOADER=1
elif echo "$FILE_OUT" | grep -qi '64-bit'; then
    DEB_ARCH="amd64"
    NEEDS_32BIT_LOADER=0
else
    echo "Could not determine payload architecture automatically; assuming amd64."
    DEB_ARCH="amd64"
    NEEDS_32BIT_LOADER=0
fi

HOST_ARCH="$(uname -m)"
APPIMAGE_ARCH="$HOST_ARCH"   # runtime stub matches the build/host machine
echo "Payload deb arch: $DEB_ARCH  /  Host (runtime stub) arch: $APPIMAGE_ARCH"

if [[ "$NEEDS_32BIT_LOADER" == "1" && "$HOST_ARCH" != "x86_64" ]]; then
    echo "WARNING: building a 32-bit x86 payload on a non-x86_64 host ($HOST_ARCH)."
    echo "This will likely not run correctly. Build on an x86_64 machine instead."
fi

WORK="$(mktemp -d)"
echo "Work directory (not auto-deleted, useful for debugging): $WORK"
APPDIR="$WORK/AppDir"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"

# --- 1. Copy the dosbox build into the AppDir ---------------------------
cp -a "$SRC_DIR/." "$APPDIR/usr/bin/"
chmod +x "$APPDIR/usr/bin/dosbox"

# --- 2. Fetch a period-correct libasound2 from the old Ubuntu archives --
# We use old-releases.ubuntu.com (Trusty 14.04, contemporaneous with 2015
# builds) and parse the Packages index dynamically rather than hardcoding
# a .deb filename, since exact package/version strings can change.
echo "Fetching libasound2 ($DEB_ARCH) from Ubuntu Trusty archives..."
cd "$WORK"
BASE_URL="http://archive.ubuntu.com/ubuntu"
DIST="trusty"

echo "Fetching package indices for $DEB_ARCH (main, universe, multiverse, restricted)..."
> Packages   # combined index across all components
for COMPONENT in main universe multiverse restricted; do
    echo "  - $COMPONENT"
    if curl -fsSL "$BASE_URL/dists/$DIST/$COMPONENT/binary-$DEB_ARCH/Packages.gz" -o "Packages-$COMPONENT.gz"; then
        gunzip -f "Packages-$COMPONENT.gz"
        cat "Packages-$COMPONENT" >> Packages
        echo "" >> Packages
    else
        echo "    (could not fetch $COMPONENT, skipping)"
    fi
done

echo "Fetching Contents index (file -> package map) for $DEB_ARCH..."
echo "(this file is tens of MB; it's what lets us look up ANY missing"
echo " library's owning package automatically instead of hardcoding names)"
curl -fsSL "$BASE_URL/dists/$DIST/Contents-$DEB_ARCH.gz" -o Contents.gz
gunzip -f Contents.gz    # -> ./Contents

mkdir -p extracted

get_deb_filename_for_package() {
    local pkg="$1"
    awk -v p="Package: $pkg" '$0==p{flag=1} flag{print} /^$/{if(flag)exit}' Packages > "/tmp/stanza_$$.txt"
    grep '^Filename:' "/tmp/stanza_$$.txt" | awk '{print $2}'
    rm -f "/tmp/stanza_$$.txt"
}

get_package_for_libfile() {
    # Looks up which package owns a given shared-object filename via the
    # archive's Contents index.
    local libname="$1"
    local libregex

    # Escape regex metacharacters so grep -E treats the filename literally.
    libregex=$(printf '%s' "$libname" | sed 's/[][(){}.^$*+?|\\]/\\&/g')

    # A few libraries are provided by multiple packages in the archive
    # where the "obvious" match isn't the one we want; force these.
    case "$libname" in
        libGL.so.1)  echo "libgl1-mesa-glx"; return 0 ;;
        libGLU.so.1) echo "libglu1-mesa";    return 0 ;;
    esac

    {
        grep -E "/${libregex}([.][0-9]+)*[[:space:]]" Contents \
            | grep -v '/debug/' \
            | awk '{print $NF}' \
            | tr ',' '\n' \
            | sed 's#.*/##' \
            | grep -Ev -- '-dbg$|-dbgsym$|^fglrx|^nvidia|-cross$' \
            | head -n1
    } || true
}

declare -A DEB_FETCHED
declare -A BUNDLED

fetch_and_extract_package() {
    local pkg="$1"
    [[ -n "${DEB_FETCHED[$pkg]:-}" ]] && return 0
    local filename
    filename="$(get_deb_filename_for_package "$pkg")"
    if [[ -z "$filename" ]]; then
        echo "  !! could not find package '$pkg' in archive index, skipping"
        return 1
    fi
    echo "  fetching $pkg  ($filename)"

    local attempt ok=0
    for attempt in 1 2 3; do
        if curl -fsSL "$BASE_URL/$filename" -o "${pkg}.deb"; then
            ok=1
            break
        fi
        echo "    (attempt $attempt failed to download $pkg, retrying in 2s...)"
        sleep 2
    done
    if [[ "$ok" != "1" ]]; then
        echo "  !! FAILED to download $pkg after 3 attempts -- $pkg will be MISSING from the bundle"
        rm -f "${pkg}.deb"
        return 1
    fi

    mkdir -p "extracted/$pkg"
    if ! dpkg-deb -x "${pkg}.deb" "extracted/$pkg"; then
        echo "  !! FAILED to extract $pkg -- $pkg will be MISSING from the bundle"
        return 1
    fi

    DEB_FETCHED[$pkg]=1
    return 0
}

bundle_libfile_from_extracted() {
    local libname="$1"
    find extracted -type f -name "${libname}*" -print0 2>/dev/null | while IFS= read -r -d '' f; do
        cp -a "$f" "$APPDIR/usr/lib/" 2>/dev/null || true
    done
    find extracted -type l -name "${libname}*" -print0 2>/dev/null | while IFS= read -r -d '' f; do
        cp -a "$f" "$APPDIR/usr/lib/" 2>/dev/null || true
    done
}

get_needed_of_file() {
    local f="$1"
    readelf -d "$f" 2>/dev/null | grep NEEDED | sed -E 's/.*\[(.*)\].*/\1/'
}

# libc6 provides the whole glibc family: ld-linux.so.2, libc, libm,
# libpthread, librt, libdl, libresolv, libnsl, libutil, libcrypt.
LIBC_FAMILY_REGEX='^(ld-linux(-x86-64)?\.so\.2|libc\.so\.6|libm\.so\.6|libpthread\.so\.0|librt\.so\.1|libdl\.so\.2|libresolv\.so\.2|libnsl\.so\.1|libutil\.so\.1|libcrypt\.so\.1)$'

QUEUE=()
process_lib() {
    local lib="$1"
    [[ -n "${BUNDLED[$lib]:-}" ]] && return 0
    BUNDLED[$lib]=1

    if [[ "$lib" =~ $LIBC_FAMILY_REGEX ]]; then
        fetch_and_extract_package "libc6" || return 0
        bundle_libfile_from_extracted "$lib"
        return 0
    fi

    local pkg
    pkg="$(get_package_for_libfile "$lib" || true)"
    if [[ -z "$pkg" ]]; then
        echo "  !! no owning package found for $lib -- leaving it to the host system"
        return 0
    fi
    fetch_and_extract_package "$pkg" || return 0
    bundle_libfile_from_extracted "$lib"

    # Recurse: this library likely has its own dependencies (e.g. libX11
    # needs libxcb, libGL needs libdrm/libexpat, etc.)
    local realfile
    realfile=$(find "extracted/$pkg" -type f -name "${lib}*" | head -n1)
    if [[ -n "$realfile" ]]; then
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            [[ -n "${BUNDLED[$dep]:-}" ]] || QUEUE+=("$dep")
        done < <(get_needed_of_file "$realfile")
    fi
}

echo ""
echo "Resolving full dependency closure starting from dosbox's NEEDED entries"
echo "plus any bundled .so wrapper libraries shipped in the distribution"
echo "(e.g. libglide2x.so, which DOSBox dlopen()'s at runtime and so never"
echo "shows up in the main binary's own NEEDED list):"
while IFS= read -r lib; do
    [[ -n "$lib" ]] && QUEUE+=("$lib")
done < <(get_needed_of_file "$DOSBOX_BIN")

while IFS= read -r -d '' bundled_so; do
    echo "  (also resolving deps of bundled $(basename "$bundled_so"))"
    while IFS= read -r lib; do
        [[ -n "$lib" ]] && QUEUE+=("$lib")
    done < <(get_needed_of_file "$bundled_so")
done < <(find "$SRC_DIR" -maxdepth 2 -name '*.so*' -type f -print0)

while [[ ${#QUEUE[@]} -gt 0 ]]; do
    lib="${QUEUE[0]}"
    QUEUE=("${QUEUE[@]:1}")
    echo "  -> $lib"
    process_lib "$lib"
done

# Ensure the 32-bit loader is present, executable, and consistently named,
# since AppRun invokes it by the fixed name "ld-linux.so.2".
if [[ "$DEB_ARCH" == "i386" && ! -e "$APPDIR/usr/lib/ld-linux.so.2" ]]; then
    REAL_LOADER=$(find "$APPDIR/usr/lib" -maxdepth 1 -name 'ld-*.so*' | head -n1)
    [[ -n "$REAL_LOADER" ]] && ln -sf "$(basename "$REAL_LOADER")" "$APPDIR/usr/lib/ld-linux.so.2"
fi
chmod +x "$APPDIR"/usr/lib/ld-linux.so.2 2>/dev/null || true

echo ""
echo "Bundled library files:"
ls -la "$APPDIR/usr/lib/"

echo ""
echo "Verifying expected libraries actually made it into the bundle..."
MISSING_ANY=0
for expected in libasound.so.2 libtbb.so.2 libdbus-1.so.3 libX11.so.6 libGL.so.1 \
                libSDL-1.2.so.0 libGLU.so.1 libstdc++.so.6 libgcc_s.so.1 \
                ld-linux.so.2 libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2; do
    if ! compgen -G "$APPDIR/usr/lib/${expected}*" > /dev/null; then
        echo "  !! MISSING: $expected was NOT successfully bundled"
        MISSING_ANY=1
    fi
done
if [[ "$MISSING_ANY" == "1" ]]; then
    echo ""
    echo "WARNING: one or more expected libraries are missing (see '!! MISSING'"
    echo "lines above). This usually means a transient network failure during"
    echo "the build. Simply re-run this script from scratch -- each run starts"
    echo "clean and will retry everything. Do NOT ship an AppImage with a"
    echo "'!! MISSING' library still unresolved; that's the same failure this"
    echo "whole build exists to fix."
else
    echo "All expected libraries present."
fi

echo ""
echo "NOTE: libGL.so.1 bundled here comes from Mesa's software/legacy stack"
echo "as of Trusty. If your target machines reliably have working 32-bit"
echo "GL drivers already, you can 'rm' it from usr/lib after this script"
echo "runs (before the appimagetool step) to prefer the host's hardware-"
echo "accelerated driver instead — DOSBox's GL usage is lightweight enough"
echo "that software rendering is unlikely to matter either way."

# --- 3. AppRun launcher ---------------------------------------------------
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
BINDIR="${HERE}/usr/bin"
DATADIR="${XDG_DATA_HOME:-$HOME/.local/share}/dosbox-daum"

# The AppImage's squashfs mount is read-only, but DOSBox Daum wants to
# write savestates (SAVE/) and captures (CAPTURE/), and users will want
# to edit dosbox.conf. So on first run we build a writable "shadow"
# directory: symlink every static bundled file/dir into it (so relative
# lookups like libglide2x.so, glide2x.ovl, FONTS/, win9x-drv resolve
# exactly as in the original distribution folder), but give CAPTURE,
# SAVE, and dosbox.conf real writable copies instead of symlinks.
if [[ ! -d "$DATADIR" ]]; then
    mkdir -p "$DATADIR"
    for item in "$BINDIR"/*; do
        name="$(basename "$item")"
        case "$name" in
            CAPTURE|SAVE)
                mkdir -p "$DATADIR/$name"
                ;;
            dosbox.conf)
                cp -a "$item" "$DATADIR/$name"
                ;;
            dosbox)
                : # the executable is invoked directly below, no symlink needed
                ;;
            *)
                ln -sf "$item" "$DATADIR/$name"
                ;;
        esac
    done
fi

# Cover both usr/lib (bundled ALSA/TBB/X11/GL/libc) and usr/bin (where
# libglide2x.so lives) so dlopen("libglide2x.so") resolves at runtime,
# not just the NEEDED entries resolved at process startup.
export LD_LIBRARY_PATH="${HERE}/usr/lib:${BINDIR}:${LD_LIBRARY_PATH:-}"

LOADER="${HERE}/usr/lib/ld-linux.so.2"
cd "$DATADIR"

if [[ -x "$LOADER" ]]; then
    # Fully self-contained: use our bundled 32-bit dynamic linker directly.
    exec "$LOADER" --library-path "${HERE}/usr/lib" "${BINDIR}/dosbox" "$@"
else
    # 64-bit payload path (or no bundled loader found).
    exec "${BINDIR}/dosbox" "$@"
fi
EOF
chmod +x "$APPDIR/AppRun"

# --- 4. .desktop file -------------------------------------------------
cat > "$APPDIR/usr/share/applications/dosbox-daum.desktop" <<'EOF'
[Desktop Entry]
Name=DOSBox Daum
Comment=DOSBox Daum (legacy build, bundled ALSA)
Exec=dosbox
Icon=dosbox-daum
Type=Application
Categories=Game;Emulator;
Terminal=false
EOF
cp "$APPDIR/usr/share/applications/dosbox-daum.desktop" "$APPDIR/"

# --- 5. Icon (simple placeholder if none is bundled with the build) ---
ICON_SRC=$(find "$SRC_DIR" -iname '*.png' | head -n1 || true)
if [[ -n "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APPDIR/usr/share/icons/hicolor/256x256/apps/dosbox-daum.png"
else
    # 1x1 transparent PNG placeholder — replace with a real icon if you have one
    base64 -d > "$APPDIR/usr/share/icons/hicolor/256x256/apps/dosbox-daum.png" <<'B64'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=
B64
fi
cp "$APPDIR/usr/share/icons/hicolor/256x256/apps/dosbox-daum.png" "$APPDIR/dosbox-daum.png"

# --- 6. Fetch appimagetool and build ------------------------------------
# appimagetool itself must match the HOST architecture (it's the tool doing
# the building, and its embedded runtime stub must run on this machine).
echo "Fetching appimagetool for host arch ${HOST_ARCH}..."
APPIMAGETOOL="$WORK/appimagetool"
curl -fsSL "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${HOST_ARCH}.AppImage" -o "$APPIMAGETOOL"
chmod +x "$APPIMAGETOOL"

OUT_NAME="DOSBox-Daum-${HOST_ARCH}.AppImage"
cd "$OLDPWD" 2>/dev/null || cd -
ARCH="$HOST_ARCH" "$APPIMAGETOOL" "$APPDIR" "$OUT_NAME" \
    || "$APPIMAGETOOL" --appimage-extract-and-run "$APPDIR" "$OUT_NAME"

echo ""
echo "Done. Built: $OUT_NAME"
echo "Run it with: ./$OUT_NAME"
echo "(If FUSE isn't available: ./$OUT_NAME --appimage-extract-and-run)"
