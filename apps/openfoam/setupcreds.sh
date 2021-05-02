#!/bin/bash

if [ $# -eq 0 ]; then
    echo "error!: no parameter for this command."
    exit 1
fi

# installopenfoam-v1.sh 向け変更
#sed -i -e "s/^MyResourceGroup=tmcbmt01/MyResourceGroup=tmcbmt01-hpccicd01/" ./apps/openfoam/$1
#sed -i -e "s/^VMPREFIX=tmcbmt01/VMPREFIX=hpccicd01/" ./apps/openfoam/$1
sed -i -e "s/^MAXVM=2/MAXVM=2/" ./apps/openfoam/$1

sed -i -e "s/PBSVMSIZE=Standard_D8as_v4/PBSVMSIZE=Standard_D4as_v4/" ./apps/openfoam/$1
sed -i -e "s/PBSPERMANENTDISK=2048/PBSPERMANENTDISK=256/" ./apps/openfoam/$1

# github actionsのための設定
sed -i -e "s!LIMITEDIP2=113.40.3.153/32!LIMITEDIP2=Internet!" ./apps/openfoam/$1
sed -i -e 's!^#az login!az login!' ./apps/openfoam/$1

# 完全に削除するまで待つ
sed -i -e "s/sleep 10 ##置換##/sleep 120 ##置換##/" ./apps/openfoam/$1

# OpenFOAM bashrc 向け変更：v1906
# 's!FOAM_INSTALL_DIRECTORY=${HOME}/OpenFOAM!FOAM_INSTALL_DIRECTORY=/mnt/share/OpenFOAM!' ./apps/openfoam/$1
