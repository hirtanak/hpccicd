#!/bin/bash
#PBS -q workq
#PBS -j oe
#PBS -l select=2:ncpus=60

APPDIR=/mnt/share
VERSION=v1906

cd "${PBS_O_WORKDIR}" || exit

#source /opt/intel/impi/2018.4.274/intel64/bin/mpivars.sh
source $APPDIR/OpenFOAM/OpenFOAM-$VERSION/etc/bashrc
#LD_LIBRARY_PATH=$APPDIR/OpenFOAM/ThirdParty-$VERSION/platforms/linux64Gcc4_8_5DPInt32/lib:/opt/openmpi-4.0.5:lib:$LD_LIBRARY_PATH; export LD_LIBRARY_PATH
LD_LIBRARY_PATH=$APPDIR/OpenFOAM/ThirdParty-$VERSION/platforms/linux64Gcc4_8_5DPInt32/lib:/mnt/share/OpenFOAM/ThirdParty-v1906/platforms/linux64Gcc4_8_5/openmpi-1.10.7/lib64/:/opt/openmpi-4.0.5:lib:$LD_LIBRARY_PATH; export LD_LIBRARY_PATH
#PATH=/mnt/share/OpenFOAM/OpenFOAM-v1906/platforms/linux64Gcc4_8_5DPInt32Opt/bin:/opt/openmpi-4.0.5/bin:$PATH
PATH=/mnt/share/OpenFOAM/OpenFOAM-v1906/platforms/linux64Gcc4_8_5DPInt32Opt/bin:/opt/openmpi-4.0.5/bin:$PATH

./Allclean
./Allrun
