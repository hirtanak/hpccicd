#!/bin/bash
echo "starting download-installOpenFOAM.sh"

OPENFOAM_VERSION="v1706 v1712 v1806 v1812 v1906 v1912 v2006"
DIR_DOWNLOAD="/mnt/share/OpenFOAM"

if [ -w $DIR_DOWNLOAD ]; then
  cd $DIR_DOWNLOAD || exit
else
  echo "Specified directory is not permitted to write."
  exit 1
fi

for VERDIR in $OPENFOAM_VERSION
do
  echo $DIR_DOWNLOAD/"$VERDIR"
  mkdir -p "$VERDIR"
  cd "$VERDIR" || exit
  git clone -q https://gitlab.com/OpenCAE/installOpenFOAM.git
  cd $DIR_DOWNLOAD/"$VERDIR"/installOpenFOAM || exit
  cp $DIR_DOWNLOAD/compile.sh .
  cd $DIR_DOWNLOAD || exit
done

echo "end of download-installOpenFOAM.sh"