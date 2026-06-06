#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# RyukGram Build Script
# ============================================================

GREEN='\033[1m\033[32m'
YELLOW='\033[0;33m'
RED='\033[1m\033[0;31m'
RESET='\033[0m'

APP_NAME="RyukGram"
PACKAGES_DIR="packages"
TWEAK_DYLIB=".theos/obj/${APP_NAME}.dylib"
BUNDLE_NAME="${APP_NAME}.bundle"
BUNDLE_PATH="${PACKAGES_DIR}/${BUNDLE_NAME}"

CMAKE_OSX_ARCHITECTURES="arm64e;arm64"
CMAKE_OSX_SYSROOT="iphoneos"

log() {
	printf "%b\n" "${GREEN}$*${RESET}"
}

warn() {
	printf "%b\n" "${YELLOW}$*${RESET}"
}

die() {
	printf "%b\n" "${RED}$*${RESET}" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "$2"
}

# Auto-detect THEOS if not set.
ensure_theos() {
	if [ -n "${THEOS:-}" ]; then
		return
	fi

	if [ -d "$HOME/theos" ]; then
		export THEOS="$HOME/theos"
	else
		die "THEOS not set and ~/theos not found.
Set THEOS or install Theos to ~/theos"
	fi
}

ensure_packages_dir() {
	mkdir -p "$PACKAGES_DIR"
}

clean_build() {
	make clean 2>/dev/null || true
	rm -rf .theos
}

# Always use FINALPACKAGE=1 for Theos builds.
make_final() {
	local args="${1:-}"

	if [ -n "$args" ]; then
		make FINALPACKAGE=1 $args
	else
		make FINALPACKAGE=1
	fi
}

# Copy Localization resources (*.lproj) into a RyukGram.bundle.
# Arg 1: destination bundle directory, created if missing.
copy_localization_into_bundle() {
	local dest="$1"
	local src="src/Localization/Resources"

	[ -d "$src" ] || return 0

	mkdir -p "$dest"

	for lproj in "$src"/*.lproj; do
		[ -d "$lproj" ] || continue
		cp -R "$lproj" "$dest/"
	done
}

# Copy generic static assets into RyukGram.bundle.
# Used for bundled images the tweak loads via SCILocalizationBundle().
# Arg 1: destination bundle directory, created if missing.
copy_bundle_assets() {
	local dest="$1"
	local src="src/BundleAssets"

	[ -d "$src" ] || return 0

	mkdir -p "$dest"

	find "$src" -maxdepth 1 -type f \( \
		-iname '*.png' -o \
		-iname '*.jpg' -o \
		-iname '*.jpeg' -o \
		-iname '*.pdf' \
	\) -exec cp {} "$dest/" \;
}

# Post-process IPA in one extraction pass:
# - Copy custom alternate app icons from ./AppIcon/
# - Patch Info.plist CFBundleAlternateIcons
# - Embed Safari extension for sideload/trollstore
# - Strip .appex bundles for the no-plugins build
# Arg 1: path to IPA.
# Arg 2: zip compression level.
# Arg 3: mode: normal / noplugins / trollstore
postprocess_ipa_bundle() {
	local ipa="$1"
	local compression="$2"
	local mode="${3:-normal}"
	local dup_id="${4:-}"

	local tmpdir
	local app_dir
	local plist
	local pb="/usr/libexec/PlistBuddy"

	local icon_src="AppIcon"
	local appex_src="extensions/OpenInstagramSafariExtension.appex"

	local icon_names=(
		"2010"
	)

	local icon_suffixes=(
		"@2x"
		"@3x"
		"-iPad@2x"
		"-iPadPro@2x"
	)

	log "Post-processing IPA"

	tmpdir="$(mktemp -d)"

	unzip -q "$ipa" -d "$tmpdir"

	app_dir="$(find "$tmpdir/Payload" -maxdepth 1 -type d -name '*.app' | head -1)"

	if [ -z "$app_dir" ]; then
		rm -rf "$tmpdir"
		die "Could not find .app bundle inside IPA."
	fi

	plist="$app_dir/Info.plist"

	if [ ! -f "$plist" ]; then
		rm -rf "$tmpdir"
		die "Info.plist not found inside app bundle."
	fi

	# Patch alternate icons if ./AppIcon exists.
	if [ -d "$icon_src" ]; then
		[ -x "$pb" ] || {
			rm -rf "$tmpdir"
			die "PlistBuddy not found at $pb"
		}

		log "Patching alternate app icons"

		for icon_name in "${icon_names[@]}"; do
			for suffix in "${icon_suffixes[@]}"; do
				local icon="${icon_name}${suffix}.png"

				if [ ! -f "$icon_src/$icon" ]; then
					rm -rf "$tmpdir"
					die "Missing icon file: $icon_src/$icon"
				fi

				cp -f "$icon_src/$icon" "$app_dir/"
			done
		done

		"$pb" -c "Print :CFBundleIcons" "$plist" >/dev/null 2>&1 || \
			"$pb" -c "Add :CFBundleIcons dict" "$plist"

		"$pb" -c "Print :CFBundleIcons:CFBundleAlternateIcons" "$plist" >/dev/null 2>&1 || \
			"$pb" -c "Add :CFBundleIcons:CFBundleAlternateIcons dict" "$plist"

		for icon_name in "${icon_names[@]}"; do
			"$pb" -c "Delete :CFBundleIcons:CFBundleAlternateIcons:${icon_name}" "$plist" >/dev/null 2>&1 || true
			"$pb" -c "Add :CFBundleIcons:CFBundleAlternateIcons:${icon_name} dict" "$plist"
			"$pb" -c "Add :CFBundleIcons:CFBundleAlternateIcons:${icon_name}:CFBundleIconFiles array" "$plist"

			for suffix in "${icon_suffixes[@]}"; do
				"$pb" -c "Add :CFBundleIcons:CFBundleAlternateIcons:${icon_name}:CFBundleIconFiles: string ${icon_name}${suffix}" "$plist"
			done
		done
	fi

	if [ "$mode" = "noplugins" ]; then
		local appex_count="0"

		log "Stripping app extensions (no-plugins build)"

		appex_count="$(find "$app_dir" -type d -name '*.appex' | wc -l | tr -d ' ')"
		find "$app_dir" -type d -name '*.appex' -prune -exec rm -rf {} +

		warn "  removed ${appex_count} .appex bundle(s)"
	else
		if [ -d "$appex_src" ]; then
			log "Embedding Safari extension"

			mkdir -p "$app_dir/PlugIns"
			rm -rf "$app_dir/PlugIns/OpenInstagramSafariExtension.appex"
			cp -R "$appex_src" "$app_dir/PlugIns/"

			# This extension lands after cyan, so re-prefix its nested id under
			# the dup parent by hand (iOS rejects a non-prefixed nested id).
			if [ -n "$dup_id" ]; then
				local ext_plist="$app_dir/PlugIns/OpenInstagramSafariExtension.appex/Info.plist"
				local ext_id
				ext_id="$("$pb" -c "Print :CFBundleIdentifier" "$ext_plist" 2>/dev/null || true)"
				if [ -n "$ext_id" ]; then
					"$pb" -c "Set :CFBundleIdentifier ${dup_id}${ext_id#com.burbn.instagram}" "$ext_plist" 2>/dev/null || true
					warn "  re-prefixed extension id → ${dup_id}${ext_id#com.burbn.instagram}"
				fi
			fi
		fi
	fi

	(
		cd "$tmpdir"
		zip -qr -"${compression}" ../repacked.ipa Payload
	)

	mv "$tmpdir/../repacked.ipa" "$ipa"
	rm -rf "$tmpdir"
}

# Copy FFmpegKit frameworks into RyukGram.bundle. Names preserved — the
# frameworks resolve siblings via @loader_path/.. so they all need to land
# in one directory together. No install_name patching required.
# Arg 1: bundle path.
patch_ffmpegkit_frameworks() {
	local bundle="$1"

	[ -d "modules/ffmpegkit/ffmpegkit.framework" ] || return 0

	log "Copying FFmpegKit frameworks"

	for fw in modules/ffmpegkit/*.framework; do
		[ -d "$fw" ] || continue
		cp -R "$fw" "$bundle/"
	done
}

# Build RyukGram.bundle: lproj resources + static assets + optional FFmpegKit.
build_bundle() {
	local bundle="$1"

	rm -rf "$bundle"
	mkdir -p "$bundle"

	copy_localization_into_bundle "$bundle"
	copy_bundle_assets "$bundle"
	patch_ffmpegkit_frameworks "$bundle"
}

# Inject RyukGram.bundle into a .deb (lproj resources + optional FFmpegKit).
# Path: Library/Application Support/RyukGram.bundle/. Arg 1: .deb path; cwd = packages/.
inject_bundle_into_deb() {
	local base_deb="$1"
	local tmpdir
	local dylib_dir
	local prefix=""
	local bundle_dir

	tmpdir="$(mktemp -d)"

	dpkg-deb -R "$base_deb" "$tmpdir"

	dylib_dir="$(find "$tmpdir" -name "${APP_NAME}.dylib" -exec dirname {} \; | head -1)"

	if [ -z "$dylib_dir" ]; then
		rm -rf "$tmpdir"
		return 0
	fi

	[[ "$dylib_dir" == *"/var/jb/"* ]] && prefix="var/jb/"

	bundle_dir="$tmpdir/${prefix}Library/Application Support/${BUNDLE_NAME}"

	mkdir -p "$bundle_dir"

	(
		cd ..
		copy_localization_into_bundle "$bundle_dir"
		copy_bundle_assets "$bundle_dir"
		patch_ffmpegkit_frameworks "$bundle_dir"
	)

	if [ -n "${THEOS:-}" ] && [ -x "${THEOS}/vendor/dm.pl/dm.pl" ]; then
		"${THEOS}/vendor/dm.pl/dm.pl" \
			-Z"${THEOS_PLATFORM_DEB_COMPRESSION_TYPE:-lzma}" \
			-z"${THEOS_PLATFORM_DEB_COMPRESSION_LEVEL:-9}" \
			-b "$tmpdir" "$base_deb"
	else
		dpkg-deb -Z"${THEOS_PLATFORM_DEB_COMPRESSION_TYPE:-lzma}" -z"${THEOS_PLATFORM_DEB_COMPRESSION_LEVEL:-9}" --uniform-compression -b "$tmpdir" "$base_deb"
	fi

	rm -rf "$tmpdir"
}

# Build zxPluginsInject.dylib -> packages/zxPluginsInject.dylib
build_zxpi_dylib() {
	local mod_dir="modules/zxPluginsInject"
	local dylib_out="${mod_dir}/.theos/obj/zxPluginsInject.dylib"

	ensure_theos

	log "Building zxPluginsInject.dylib"

	(
		cd "$mod_dir"
		make FINALPACKAGE=1 >/dev/null
	)

	[ -f "$dylib_out" ] || die "zxPluginsInject.dylib build failed"

	ensure_packages_dir

	cp "$dylib_out" "${PACKAGES_DIR}/zxPluginsInject.dylib"

	# Match the @rpath LC that ipapatch writes into target binaries.
	install_name_tool -id "@rpath/zxPluginsInject.dylib" \
		"${PACKAGES_DIR}/zxPluginsInject.dylib" 2>/dev/null || true
}

# LC-inject zxPluginsInject.dylib into main exec + every .appex in the IPA.
# Arg 1: path to the IPA.
run_ipapatch() {
	local ipa="$1"

	need_cmd ipapatch "ipapatch not found. Install it from:
  https://github.com/asdfzxcvbn/ipapatch/releases/latest"

	log "Running ipapatch (zxPluginsInject LC injection)"

	ipapatch --input "$ipa" --inplace --noconfirm --dylib "${PACKAGES_DIR}/zxPluginsInject.dylib"
}

# Find decrypted Instagram IPA.
# Checks packages/ first, then moves a matching IPA from cwd into packages/.
find_instagram_ipa() {
	local ipa_file=""
	local cwd_ipa=""

	ensure_packages_dir

	ipa_file="$(find "./${PACKAGES_DIR}" -maxdepth 1 -type f \( \
		-iname '*com.burbn.instagram*.ipa' -o \
		-iname 'Instagram*.ipa' -o \
		-iname '[0-9]*.ipa' \
	\) ! -iname "${APP_NAME}*.ipa" -exec basename {} \; 2>/dev/null | head -1)"

	if [ -n "$ipa_file" ]; then
		printf "%s\n" "$ipa_file"
		return 0
	fi

	cwd_ipa="$(find . -maxdepth 1 -type f \( \
		-iname '*com.burbn.instagram*.ipa' -o \
		-iname 'Instagram*.ipa' -o \
		-iname '[0-9]*.ipa' \
	\) 2>/dev/null | head -1)"

	if [ -n "$cwd_ipa" ]; then
		log "Moving $(basename "$cwd_ipa") → ${PACKAGES_DIR}/" >&2
		mv "$cwd_ipa" "$PACKAGES_DIR/"
		printf "%s\n" "$(basename "$cwd_ipa")"
		return 0
	fi

	return 1
}

# Check for FLEXing submodule.
check_flex() {
	if [ -n "$(ls -A modules/FLEXing 2>/dev/null || true)" ]; then
		printf "1\n"
	else
		printf "0\n"
	fi
}

# Build just the dylib for Feather/manual injection.
build_dylib() {
	local option="${1:-}"

	# --fast: incremental build, no clean.
	if [ "$option" != "--fast" ]; then
		clean_build
	fi

	log "Building ${APP_NAME} dylib"

	make_final ""

	ensure_packages_dir

	cp "$TWEAK_DYLIB" "${PACKAGES_DIR}/${APP_NAME}.dylib"

	# Ship localization bundle next to the dylib so Feather/manual installs work.
	rm -rf "$BUNDLE_PATH"
	mkdir -p "$BUNDLE_PATH"

	copy_localization_into_bundle "$BUNDLE_PATH"
	copy_bundle_assets "$BUNDLE_PATH"

	log "Done!"
	echo
	echo "Dylib at:  $(pwd)/${PACKAGES_DIR}/${APP_NAME}.dylib"
	echo "Bundle at: $(pwd)/${BUNDLE_PATH}"
}

# Build sideloaded IPA.
# noplugins = sideload + SideloadPatch, appex stripped, no zxPluginsInject/ipapatch.
build_sideload() {
	local mode="${1:-sideload}"
	shift || true

	# --dup [id]: spoof bundle id for a side-by-side install. id resolves:
	# CLI arg > RG_DUP_ID env > com.ryuk.ryukgram. RG_DUP_NAME renames the app.
	local option=""
	local dup_id=""
	local dup_enabled=0

	while [ "$#" -gt 0 ]; do
		case "$1" in
			--dup)
				dup_enabled=1
				local nxt="${2:-}"
				if [ -n "$nxt" ] && [ "${nxt#--}" = "$nxt" ]; then
					dup_id="$nxt"
					shift
				fi
				;;
			--dev|--buildonly|--devquick)
				option="$1"
				;;
			"")
				;;
			*)
				warn "Unknown sideload option: $1"
				;;
		esac
		shift
	done

	if [ "$dup_enabled" = "1" ]; then
		# dup needs appex stripped + SideloadPatch — i.e. the noplugins build.
		if [ "$mode" != "noplugins" ]; then
			die "--dup is only supported on the noplugins build.
Run: ./build.sh noplugins --dup [id]"
		fi
		dup_id="${dup_id:-${RG_DUP_ID:-com.ryuk.ryukgram}}"
	fi

	local dup_args=""
	if [ -n "$dup_id" ]; then
		dup_args="-b $dup_id"
		[ -n "${RG_DUP_NAME:-}" ] && dup_args="$dup_args -n ${RG_DUP_NAME}"

		# Concrete keychain-access-group + app-group tied to the dup's bundle id.
		# $(AppIdentifierPrefix) is left literal for the signer to substitute.
		local dup_ent="${PACKAGES_DIR}/dup-entitlements.plist"
		cat > "$dup_ent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>keychain-access-groups</key>
	<array>
		<string>\$(AppIdentifierPrefix)${dup_id}</string>
	</array>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.${dup_id}</string>
	</array>
</dict>
</plist>
EOF
		dup_args="$dup_args -x $dup_ent"
	fi

	local rg_sidestore=0
	local build_label="sideloading"
	local out_ipa="${PACKAGES_DIR}/${APP_NAME}-sideloaded.ipa"
	local compression=9
	local makeargs=""
	local flexpath=""
	local has_flex
	local ipa_file
	local tweakpath
	local cyan_files=""

	if [ "$mode" = "noplugins" ]; then
		rg_sidestore=1
		export RG_SIDESTORE=1
		build_label="no-plugins"
		out_ipa="${PACKAGES_DIR}/${APP_NAME}-noplugins.ipa"
	fi

	# Keep dup IPAs out of the normal build's path.
	if [ -n "$dup_id" ]; then
		out_ipa="${out_ipa%.ipa}-dup.ipa"
	fi

	# Check for FLEXing submodule.
	has_flex="$(check_flex)"

	if [ "$has_flex" = "0" ]; then
		warn "FLEXing submodule not found — building without FLEX debugger."
		warn "To include FLEX, run: git submodule update --init --recursive"
		echo
	fi

	# Check if building with dev mode.
	if [ "$option" = "--dev" ]; then
		[ "$has_flex" = "1" ] || die "Dev mode requires FLEXing submodule."

		# Cache pre-built FLEX libs.
		ensure_packages_dir
		mkdir -p "${PACKAGES_DIR}/cache"

		cp -f ".theos/obj/AllFLEXing.dylib" "${PACKAGES_DIR}/cache/AllFLEXing.dylib" 2>/dev/null || true

		if [[ ! -f "${PACKAGES_DIR}/cache/AllFLEXing.dylib" ]]; then
			warn "Could not find cached pre-built AllFLEXing dylib, building prerequisite binaries"
			echo

			"$0" sideload --buildonly
			./build-dev.sh true
			exit 0
		fi

		makeargs="DEV=1"
		flexpath="${PACKAGES_DIR}/cache/AllFLEXing.dylib"
		compression=0
	else
		# Clear cached FLEX libs.
		rm -rf "${PACKAGES_DIR}/cache"

		if [ "$has_flex" = "1" ]; then
			makeargs="SIDELOAD=1"
			flexpath=".theos/obj/AllFLEXing.dylib"
		fi

		compression=9
	fi

	if [ "$rg_sidestore" = "1" ]; then
		makeargs="${makeargs} SIDESTORE=1"
		makeargs="$(printf "%s" "$makeargs" | xargs)"
	fi

	# Clean build artifacts.
	clean_build
	ensure_packages_dir

	# Check for decrypted Instagram IPA.
	ipa_file="$(find_instagram_ipa)" || die "Decrypted Instagram IPA not found.
Place a *com.burbn.instagram*.ipa in ./ or ./packages/."

	# Check for cyan and ipapatch before building.
	# Skip full IPA tool checks for --buildonly.
	if [ "$option" != "--buildonly" ]; then
		need_cmd cyan "cyan not found. Install it with:
  pip install --force-reinstall https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip

Use ./build.sh sideload --buildonly to just compile without creating the IPA.
Or use ./build.sh dylib to build the dylib for Feather injection."

		if [ "$rg_sidestore" != "1" ]; then
			need_cmd ipapatch "ipapatch not found. Install it from:
  https://github.com/asdfzxcvbn/ipapatch/releases/latest"
		fi
	fi

	log "Building ${APP_NAME} tweak for ${build_label} as IPA"

	make_final "$makeargs"

	# Skip zxPluginsInject for the no-plugins build — its LC injection trips ldid on resign.
	if [ "$rg_sidestore" != "1" ]; then
		build_zxpi_dylib
	fi

	# Copy dylib to packages.
	cp "$TWEAK_DYLIB" "${PACKAGES_DIR}/${APP_NAME}.dylib"

	# Only build libs for future use in dev build mode.
	if [ "$option" = "--buildonly" ]; then
		log "Build-only finished."
		exit 0
	fi

	# Build RyukGram.bundle with renamed frameworks for cyan injection.
	log "Building ${BUNDLE_NAME}"
	build_bundle "$BUNDLE_PATH"

	tweakpath="$TWEAK_DYLIB"

	if [ "$option" = "--devquick" ]; then
		tweakpath=""
	fi

	if [ -n "$tweakpath" ]; then
		cyan_files="$cyan_files $tweakpath"
	fi

	if [ -n "$flexpath" ]; then
		cyan_files="$cyan_files $flexpath"
	fi

	if [ -d "$BUNDLE_PATH" ]; then
		cyan_files="$cyan_files $BUNDLE_PATH"
	fi

	cyan_files="$(printf "%s" "$cyan_files" | xargs)"

	# Create IPA: cyan injects dylib + copies RyukGram.bundle to app root.
	log "Creating the IPA file"

	rm -f "$out_ipa"

	[ -n "$dup_id" ] && log "Duplicate build → bundle id ${dup_id}${RG_DUP_NAME:+, name ${RG_DUP_NAME}}"

	cyan -i "${PACKAGES_DIR}/${ipa_file}" \
		-o "$out_ipa" \
		-f $cyan_files \
		-c "$compression" \
		-m 15.0 \
		-du \
		$dup_args

	if [ "$rg_sidestore" = "1" ]; then
		postprocess_ipa_bundle "$out_ipa" "$compression" "noplugins" "$dup_id"
	else
		postprocess_ipa_bundle "$out_ipa" "$compression" "normal" "$dup_id"
	fi

	if [ "$rg_sidestore" != "1" ]; then
		run_ipapatch "$out_ipa"
	fi

	log "Done, enjoy ${APP_NAME}!"
	echo
	echo "IPA at: $(pwd)/$out_ipa"
}

# Build rootless/rootful .deb with FFmpegKit.
build_deb() {
	local scheme="$1"
	local base_deb
	local new_name

	clean_build
	ensure_packages_dir

	if [ "$scheme" = "rootless" ]; then
		log "Building ${APP_NAME} tweak for rootless"
		export THEOS_PACKAGE_SCHEME=rootless
	else
		log "Building ${APP_NAME} tweak for rootful"
		unset THEOS_PACKAGE_SCHEME
	fi

	make_final "package"

	log "Injecting ${BUNDLE_NAME} with localization + FFmpegKit into deb"

	(
		cd "$PACKAGES_DIR"

		base_deb="$(ls -t *.deb 2>/dev/null | head -n1)"

		[ -n "$base_deb" ] || die "No deb package found."

		inject_bundle_into_deb "$base_deb"

		new_name="${base_deb%.deb}-${scheme}.deb"
		mv "$base_deb" "$new_name"
	)

	[ -d "modules/ffmpegkit/ffmpegkit.framework" ] || warn "FFmpegKit not found — deb built without FFmpegKit."

	log "Done, enjoy ${APP_NAME}!"
	echo
	echo "Deb at: $(pwd)/${PACKAGES_DIR}"
}

# TrollStore build — .tipa is a renamed .ipa.
# Skip sideload re-sign; TrollStore signs on-device.
build_trollstore() {
	local has_flex
	local makeargs=""
	local flexpath=""
	local compression=9
	local ipa_file
	local out_ipa="${PACKAGES_DIR}/${APP_NAME}-trollstore.ipa"
	local out_tipa="${PACKAGES_DIR}/${APP_NAME}-trollstore.tipa"
	local cyan_files="$TWEAK_DYLIB"

	has_flex="$(check_flex)"

	if [ "$has_flex" = "1" ]; then
		makeargs="SIDELOAD=1"
		flexpath=".theos/obj/AllFLEXing.dylib"
	else
		warn "FLEXing submodule not found — building TrollStore package without FLEX debugger."
		echo
	fi

	clean_build
	ensure_packages_dir

	ipa_file="$(find_instagram_ipa)" || die "Decrypted Instagram IPA not found."

	need_cmd cyan "cyan not found. Install it with:
  pip install --force-reinstall https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip"

	need_cmd ipapatch "ipapatch not found. Install it from:
  https://github.com/asdfzxcvbn/ipapatch/releases/latest"

	log "Building ${APP_NAME} tweak for TrollStore .tipa"

	make_final "$makeargs"

	cp "$TWEAK_DYLIB" "${PACKAGES_DIR}/${APP_NAME}.dylib"

	build_zxpi_dylib

	# Build RyukGram.bundle with renamed frameworks for cyan injection.
	log "Building ${BUNDLE_NAME}"
	build_bundle "$BUNDLE_PATH"

	if [ -n "$flexpath" ]; then
		cyan_files="$cyan_files $flexpath"
	fi

	if [ -d "$BUNDLE_PATH" ]; then
		cyan_files="$cyan_files $BUNDLE_PATH"
	fi

	cyan_files="$(printf "%s" "$cyan_files" | xargs)"

	log "Creating the TIPA file"

	rm -f "$out_ipa" "$out_tipa"

	cyan -i "${PACKAGES_DIR}/${ipa_file}" \
		-o "$out_ipa" \
		-f $cyan_files \
		-c "$compression" \
		-m 15.0 \
		-du

	postprocess_ipa_bundle "$out_ipa" "$compression" "trollstore"

	run_ipapatch "$out_ipa"

	mv "$out_ipa" "$out_tipa"

	log "Done!"
	echo
	echo "TIPA at: $(pwd)/$out_tipa"
}

# Build TrollFools zip — dylib + RyukGram.bundle + FFmpegKit frameworks at zip
# root. TrollFools LC-injects each top-level dylib and copies top-level
# .framework dirs into the target app's Frameworks/. No cyan/ipapatch/IPA.
build_trollfools() {
	local has_flex
	local makeargs=""
	local flexpath=""
	local stage
	local stage_bundle
	local out_zip="${PACKAGES_DIR}/${APP_NAME}-trollfools.zip"

	has_flex="$(check_flex)"

	if [ "$has_flex" = "1" ]; then
		makeargs="SIDELOAD=1"
		flexpath=".theos/obj/AllFLEXing.dylib"
	else
		warn "FLEXing submodule not found — building TrollFools package without FLEX debugger."
		echo
	fi

	clean_build
	ensure_packages_dir

	log "Building ${APP_NAME} tweak for TrollFools"

	make_final "$makeargs"

	stage="$(mktemp -d)"

	cp "$TWEAK_DYLIB" "$stage/${APP_NAME}.dylib"

	for p in $flexpath; do
		[ -f "$p" ] && cp "$p" "$stage/"
	done

	stage_bundle="$stage/${BUNDLE_NAME}"
	mkdir -p "$stage_bundle"
	copy_localization_into_bundle "$stage_bundle"
	copy_bundle_assets "$stage_bundle"

	if [ -d "modules/ffmpegkit/ffmpegkit.framework" ]; then
		log "Staging FFmpegKit at zip root"
		patch_ffmpegkit_frameworks "$stage"
	else
		warn "FFmpegKit not found — zip built without FFmpegKit."
	fi

	if command -v ldid >/dev/null 2>&1; then
		log "Adhoc-signing staged binaries (ldid -S)"

		local signed=0
		local f
		local bin

		for f in "$stage"/*.dylib; do
			[ -f "$f" ] || continue
			ldid -S "$f" && signed=$((signed + 1))
		done

		for f in "$stage"/*.framework; do
			[ -d "$f" ] || continue

			bin="$f/$(basename "${f%.framework}")"
			[ -f "$bin" ] || continue

			ldid -S "$bin" && signed=$((signed + 1))
		done

		warn "  signed ${signed} binar(ies)"
	else
		warn "ldid not found — leaving binaries unsigned."
	fi

	rm -f "$out_zip"

	(
		cd "$stage"
		zip -qr -9 "$OLDPWD/$out_zip" .
	)

	rm -rf "$stage"

	log "Done!"
	echo
	echo "TrollFools zip at: $(pwd)/$out_zip"
}

usage() {
	echo '+-----------------------+'
	echo '| RyukGram Build Script |'
	echo '+-----------------------+'
	echo
	echo "Usage: $0 <dylib/sideload/noplugins/trollstore/trollfools/rootless/rootful> [option]"
	echo
	echo 'Commands:'
	echo '  dylib                 Build the dylib only for Feather/manual injection'
	echo '  dylib --fast          Build dylib without cleaning'
	echo '  sideload              Build a patched IPA, requires cyan + decrypted IPA'
	echo '  sideload --buildonly  Compile only, do not create IPA'
	echo '  sideload --dev        Build dev IPA with cached FLEX libs'
	echo '  sideload --devquick   Create IPA without RyukGram.dylib injection'
	echo '  sideload --dup [id]   Spoof bundle id so it installs next to stock Instagram'
	echo '  noplugins             Like sideload but appex stripped + SideloadPatch baked in;'
	echo '                        works with any sideloader (SideStore / AltStore / Feather)'
	echo '  noplugins --dup [id]  No-plugins dup build for coexist install next to stock IG'
	echo '  trollstore            Build a .tipa for TrollStore, requires cyan + decrypted IPA'
	echo '  trollfools            Build a TrollFools zip (dylib + bundle + frameworks, no IPA)'
	echo '  rootless              Build a rootless .deb package with FFmpegKit'
	echo '  rootful               Build a rootful .deb package with FFmpegKit'
	echo
	echo 'Duplicate (--dup) notes:'
	echo '  id resolves: CLI arg > RG_DUP_ID env > com.ryuk.ryukgram'
	echo '  RG_DUP_NAME (optional, single token) renames the app on the home screen'
	echo '  cyan re-prefixes nested appex ids; output goes to *-dup.ipa'
	echo
	exit 1
}

main() {
	# Prefer lzma/9 for every packaging path (dm.pl and Theos internal tooling).
	export THEOS_PLATFORM_DEB_COMPRESSION_TYPE="${THEOS_PLATFORM_DEB_COMPRESSION_TYPE:-lzma}"
	export THEOS_PLATFORM_DEB_COMPRESSION_LEVEL="${THEOS_PLATFORM_DEB_COMPRESSION_LEVEL:-9}"
	ensure_theos

	local command="${1:-}"
	local option="${2:-}"

	case "$command" in
		dylib)
			build_dylib "$option"
			;;
		sideload)
			build_sideload "sideload" "${@:2}"
			;;
		noplugins|sidestore)
			build_sideload "noplugins" "${@:2}"
			;;
		trollstore)
			build_trollstore
			;;
		trollfools)
			build_trollfools
			;;
		rootless)
			build_deb "rootless"
			;;
		rootful)
			build_deb "rootful"
			;;
		*)
			usage
			;;
	esac
}

main "$@"
