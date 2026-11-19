#!/bin/bash

##########################################################
##                                                      ##
## Shell script for generating a boards manager release ##
## Created by MCUdude                                   ##
## Requires wget, jq and a bash environment             ##
##                                                      ##
##########################################################

# Called by the release workflow of the master branch with the tag,
# e.g. "bash Boards_manager_release.sh v2.7.0-pre5"; by hand as well.

AUTHOR=SpenceKonde       # author, part of the index file name
REPOSITORY=megaTinyCore  # Github repo name
REPOWNER=felias-fogg     # owner of this fork, where the releases and gh-pages are

# Which index to write. The workflow sets INDEX_FILE: a release candidate goes
# into an index of its own, so the board manager of an ordinary user never
# offers it. Without the variable, this is the stable index, the one the README
# names.
INDEX="${INDEX_FILE:-package_${AUTHOR}_${REPOSITORY}_index.json}"

# The tools the platform depends on, as in the 2.7.0-pre4 entry. The debug tools
# are no dependency any more since 2.7.0-pre5: they come from the AvrDebugger
# package, which the user installs separately and the platform finds as
# runtime.tools.avr-debugger.path.
AVRDUDE_VERSION="avrdude_v8.1-released"
AVR_GCC_VERSION="7.3.0-atmel3.6.1-azduino7b1"

TAG="$1"
if [ -z "$TAG" ]; then
    echo "You need to specify a tag, e.g. v2.7.0-pre5"
    exit 1
fi
DOWNLOAD_URL="https://api.github.com/repos/$REPOWNER/$REPOSITORY/tarball/$TAG"
DOWNLOADED_FILE="$TAG"
NAME="$REPOSITORY-${TAG#"v"}"
echo "Packaging ${TAG} into ${INDEX}"

# Check whether this exact version is already in the index. The archive name has
# to be matched in full: without the extension, "megaTinyCore-2.7.0-pre5" also matches
# "megaTinyCore-2.7.0-pre5-rc1.tar.bz2", and the final release would be refused because
# one of its own release candidates is in the index.
if grep -q "\"${NAME}.tar.bz2\"" "$INDEX"; then
    echo "This version is already in the index file. Nothing to do."
    exit 1
fi

# Download file
wget --no-verbose -O "${DOWNLOADED_FILE}.tar.gz" "$DOWNLOAD_URL" || exit 1

# Extract downloaded file and place it in a folder
printf "\nExtracting ${DOWNLOADED_FILE}.tar.gz to ${NAME}\n"
mkdir -p "$NAME" && tar -xzf "${DOWNLOADED_FILE}.tar.gz" -C "$NAME" --strip-components=1 || exit 1

# The platform is the megaavr folder of the repository: keep only that
mv "$NAME" "$NAME.full" && mv "$NAME.full/megaavr" "$NAME" && rm -rf "$NAME.full" "${DOWNLOADED_FILE}.tar.gz"
test -f "$NAME/platform.txt" || { echo "no platform.txt in the megaavr folder of ${TAG}"; exit 1; }

# Make sure there are no macOS related files added to the archive that's soon to be
# generated. dot_clean only exists on macOS; elsewhere there is nothing to clean.
if command -v dot_clean > /dev/null 2>&1; then
    dot_clean "$NAME"
fi
find "$NAME" -name "._*" -delete 2>/dev/null

# Compress folder to tar.bz2
printf "\nCompressing folder ${NAME} to ${NAME}.tar.bz2\n"
tar -cjSf "${NAME}.tar.bz2" "$NAME"
printf "Done!\n"

# Get file size on bytes
FILE_SIZE=$(wc -c "${NAME}.tar.bz2" | awk '{print $1}')

# Get SHA256 hash: shasum is a macOS thing, sha256sum a Linux one
if command -v shasum > /dev/null 2>&1; then
    SHA256="SHA-256:$(shasum -a 256 "${NAME}.tar.bz2" | awk '{print $1}')"
else
    SHA256="SHA-256:$(sha256sum "${NAME}.tar.bz2" | awk '{print $1}')"
fi

# The archive is served from this branch (gh-pages)
URL="https://${REPOWNER}.github.io/${REPOSITORY}/${NAME}.tar.bz2"

cp "$INDEX" "$INDEX.tmp"

# Add new boards release entry
jq -r                                          \
--arg version          "${TAG#"v"}"            \
--arg url              "$URL"                  \
--arg checksum         "$SHA256"               \
--arg file_size        "$FILE_SIZE"            \
--arg avrdude_ver      "$AVRDUDE_VERSION"      \
--arg avr_gcc_ver      "$AVR_GCC_VERSION"      \
--arg file_name        "${NAME}.tar.bz2"       \
'.packages[].platforms[.packages[].platforms | length] |= . +
{
  "name": "megaTinyCore (debug-configured)",
  "architecture": "megaavr",
  "version": $version,
  "category": "Contributed",
  "url": $url,
  "archiveFileName": $file_name,
  "checksum": $checksum,
  "size": $file_size,
  "boards": [
            {
              "name": "Full Arduino support for the tinyAVR 0-series, 1-series, and the new 2-series!<br/> 24-pin parts: ATtiny3227/3217/1627/1617/1607/827/817/807/427<br/> 20-pin parts: ATtiny3226/3216/1626/1616/1606/826/816/806/426/416/406<br/> 14-pin parts: ATtiny3224/1624/1614/1604/824/814/804/424/414/404/214/204<br/> 8-pin parts: ATtiny412/402/212/202<br/> Microchip Boards: Curiosity Nano 3217/1627/1607 and Xplained Pro (3217/817), Mini (817) Nano (416). Direct USB uploads may not work on linux, but you can export hex and <br/> upload through the mass storage projection."
            },
            { "name": "2.7.0-pre3 was the first experimental version to include the debug capability. 2.7.0-pre4 can be installed stand-alone and uses avrdude 8.1. Since 2.7.0-pre5, the debug tools come from the AvrDebugger package, which has to be installed in addition." 
            },
            {
              "name": "2.6.10 is a critical bugfix to 2.6.9. This also pulls in the fix for missing constants for ADCPowerOptions(), and board manager installations no longer elide the text portions of the documentation."
            },
            {
              "name": "2.6.9 was largely a bugfix release, fixing the bootloaders (reburn bootloader if using optiboot if having entry condition issues, older versions with the new entry condition options had bad bootloader binaries that ignored the requested entry conditions.</br> 2.6.8 and older should not be used."
            },
            {
              "name": "Supported UPDI programmers: SerialUPDI (serial adapter w/diode or resistor), jtag2updi, nEDBG, mEDBG, EDBG, SNAP, Atmel-ICE, PICkit4, Power Debugger, and JTAGICE3 - or use one of those to load<br/> the Optiboot serial bootloader (included) for serial programming. Which programing method makes more sense depends on your application and requirements. <br/><br/> The full documentation is not included with board manager installations (it is hard to find and the images bloat the download); we recommend viewing it through github at the link above<br/> or if it must be read withouht an internet connection by downaloding the manual installation package"
            }
  ],
  "toolsDependencies": [
    {
      "packager": "megaTinyCore",
      "name": "avr-gcc",
      "version": $avr_gcc_ver
    },
    {
      "packager": "megaTinyCore",
      "name": "avrdude",
      "version": $avrdude_ver
    },
    {
      "packager": "arduino",
      "name": "arduinoOTA",
      "version": "1.3.0"
    }
  ]
}' "$INDEX.tmp" > "$INDEX" || { mv "$INDEX.tmp" "$INDEX"; echo "jq failed, index unchanged"; exit 1; }

# Remove files that are no longer needed (the archive stays: it is what the URL serves)
rm -rf "$NAME" "$INDEX.tmp"
