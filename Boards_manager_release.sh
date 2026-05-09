#!/bin/bash

##########################################################
##                                                      ##
## Shell script for generating a boards manager release ##
## Created by MCUdude                                   ##
## Requires wget, jq and a bash environment             ##
##                                                      ##
##########################################################

# Change these to match your repo
AUTHOR=SpenceKonde       # Github username
REPOSITORY=megaTinyCore # Github repo name
REPOWNER=felias-fogg # Repository owner (not necessarily author)
PAOOWNER=felias-fogg # Github owner of PyAvrOCD

# Get the version number of most recent (or specified) PyAvrOCD version
PAOVERSION=$1
if [ -z "${PAOVERSION}" ]; then
    PAOVERSION=$(curl -s https://api.github.com/repos/$PAOOWNER/PyAvrOCD/releases/latest | grep "tag_name" |  awk -F\" '{print $4}')
fi

echo "PAOVERSION: ${PAOVERSION}"

AVROCDVERSION=${PAOVERSION#"v"}

AVRDUDE_VERSION="6.3.0-arduino17or18"

# Get the download URL for the latest release from Github
DOWNLOAD_URL=$(curl -s https://api.github.com/repos/$REPOWNER/$REPOSITORY/releases/latest | grep "tarball_url" | awk -F\" '{print $4}')

echo "Download URL: ${DOWNLOAD_URL}"

# Get filename
DOWNLOADED_FILE=$(echo $DOWNLOAD_URL | awk -F/ '{print $8}')

echo "Downloaded file: ${DOWNLOADED_FILE}"


# Check whether most recent board file is already in the index
if grep -q ${REPOSITORY}-${DOWNLOADED_FILE#"v"}\" package_${AUTHOR}_${REPOSITORY}_index.json; then
    echo "Most recent board version is already in the index file. Nothing to do."
    exit 1
fi

# Check whether current PyAvrOCD is already part of the index
if grep -q "avrocd-tools-"${AVROCDVERSION} package_${AUTHOR}_${REPOSITORY}_index.json; then
    echo "Current PyAvrOCD version is in index. Continue ..."
else
    echo "Current PyAvrOCD version is not in index. Add it first."
    exit 1
fi


# Download file
wget --no-verbose $DOWNLOAD_URL

# Add .tar.bz2 extension to downloaded file
mv $DOWNLOADED_FILE ${DOWNLOADED_FILE}.tar.bz2

# Extract downloaded file and place it in a folder
printf "\nExtracting folder ${DOWNLOADED_FILE}.tar.bz2 to $REPOSITORY-${DOWNLOADED_FILE#"v"}\n"
mkdir -p "$REPOSITORY-${DOWNLOADED_FILE#"v"}" && tar -xzf ${DOWNLOADED_FILE}.tar.bz2 -C "$REPOSITORY-${DOWNLOADED_FILE#"v"}" --strip-components=1
printf "Done!\n"

# Move files out of the megaavr folder
mv $REPOSITORY-${DOWNLOADED_FILE#"v"}/megaavr/* $REPOSITORY-${DOWNLOADED_FILE#"v"}

# Delete downloaded file and empty megaavr folder
rm -rf ${DOWNLOADED_FILE}.tar.bz2 $REPOSITORY-${DOWNLOADED_FILE#"v"}/megaavr

# Compress folder to tar.bz2
printf "\nCompressing folder $REPOSITORY-${DOWNLOADED_FILE#"v"} to $REPOSITORY-${DOWNLOADED_FILE#"v"}.tar.bz2\n"
tar -cjSf $REPOSITORY-${DOWNLOADED_FILE#"v"}.tar.bz2 $REPOSITORY-${DOWNLOADED_FILE#"v"}
printf "Done!\n"

# Get file size on bytes
FILE_SIZE=$(wc -c "$REPOSITORY-${DOWNLOADED_FILE#"v"}.tar.bz2" | awk '{print $1}')

# Get SHA256 hash
SHA256="SHA-256:$(shasum -a 256 "$REPOSITORY-${DOWNLOADED_FILE#"v"}.tar.bz2" | awk '{print $1}')"

# Create Github download URL
URL="https://${REPOWNER}.github.io/${REPOSITORY}/$REPOSITORY-${DOWNLOADED_FILE#"v"}.tar.bz2"

cp "package_${AUTHOR}_${REPOSITORY}_index.json" "package_${AUTHOR}_${REPOSITORY}_index.json.tmp"

# Add new boards release entry
jq -r                                   \
--arg repository $REPOSITORY            \
--arg version    ${DOWNLOADED_FILE#"v"} \
--arg url        $URL                   \
--arg checksum   $SHA256                \
--arg file_size  $FILE_SIZE             \
--arg avrdude_ver $AVRDUDE_VERSION      \
--arg avrocdversion $AVROCDVERSION      \
--arg file_name  $REPOSITORY-${DOWNLOADED_FILE#"v"}.tar.bz2  \
'.packages[].platforms[.packages[].platforms | length] |= . +
{
  "name": $repository,
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
            { "name": "2.7.0-pre1 is the first experimental version to include the debug capability" 
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
      "packager": "DxCore",
      "name": "avr-gcc",
      "version": "7.3.0-atmel3.6.1-azduino7b1"
    },
    {
      "packager": "DxCore",
      "name": "avrdude",
      "version":  $avrdude_ver
    },
    {
      "packager": "arduino",
      "name": "arduinoOTA",
      "version": "1.3.0"
    },
    {
      "packager": "megaTinyCore",
      "name": "avrocd-tools",
      "version": $avrocdversion
    }   
  ]
}' "package_${AUTHOR}_${REPOSITORY}_index.json.tmp" > "package_${AUTHOR}_${REPOSITORY}_index.json"

# Remove files that's no longer needed
rm -rf "$REPOSITORY-${DOWNLOADED_FILE#"v"}" "package_${AUTHOR}_${REPOSITORY}_index.json.tmp"
