#!/bin/bash
#PBS -q workq

OPENFOAM_VERSION=$1
HOMEDIR=$2
CUSER=$3
echo "In compile.sh - OPENFOAM_VERSION : $OPENFOAM_VERSION"
echo "In compile.sh - HOMEDIR : $HOMEDIR"
echo "In compile.sh - CUSER : $CUSER"

cd "$PBS_O_WORKDIR" || exit
./install.sh

if [ -n "$OPENFOAM_VERSION" ]; then
  if [ "$OPENFOAM_VERSION" = "v1712" ]; then
    echo "In compile.sh - IN FOR v1712 SPEFIC PROCESSING"
    cp "$HOMEDIR"/OpenFOAM/"$CUSER"-v1712/platforms/linux64Gcc4_8_5DPInt32Opt/bin/sphereSurfactantFoam /mnt/exports/apps/OpenFOAM/OpenFOAM-v1712/platforms/linux64Gcc
4_8_5DPInt32Opt/bin
    \rm -rf "$HOMEDIR"/OpenFOAM
  fi
  if [ -d /mnt/exports/apps/OpenFOAM/OpenFOAM-"$OPENFOAM_VERSION"/platforms ] && [ -w /mnt/exports/apps/OpenFOAM/OpenFOAM-"$OPENFOAM_VERSION"/platforms ]; then
    cd /mnt/exports/apps/OpenFOAM/OpenFOAM-"$OPENFOAM_VERSION"/platforms || exit
    echo "In compile.sh - LINKDIR : $(pwd)"
    ln -s linux64Gcc4_8_5DPInt32Opt linux64GccDPInt32Opt
  fi
else
  echo "In compile.sh - OPENFOAM_VERSION is not specified."
fi

#if [ -d /mnt/exports/apps/OpenFOAM/workdir -a -w /mnt/exports/apps/OpenFOAM/workdir ]; then
#  echo "rm -rf /mnt/exports/apps/OpenFOAM/workdir"
#  \rm -rf /mnt/exports/apps/OpenFOAM/workdir
#fi