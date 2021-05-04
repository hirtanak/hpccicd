#!/bin/bash
echo "starting setupcred.sh."

# apps 配下のアプリケーション実行時の設定変更利用
# $1 変更対象のファイル名
# $2 台数
# $3

if [ $# -eq 0 ]; then
    echo "error!: no parameter for this command. require at least one."
    exit 1
fi

## 一般的な設定
sed -i -e "s/^MyResourceGroup=tmcbmt01/MyResourceGroup=tmcbmt01-hpccicd01/" ./${1}
sed -i -e "s/^VMPREFIX=tmcbmt01/VMPREFIX=hpccicd01/" ./${1}

# VMサイズ・ディスク
sed -i -e "s/^PBSVMSIZE=Standard_D8as_v4/PBSVMSIZE=Standard_D4as_v4/" ./${1}
sed -i -e "s/^PBSPERMANENTDISK=2048/PBSPERMANENTDISK=256/" ./${1}

# github actionsのための設定
#sed -i -e "s!LIMITEDIP2=113.40.3.153/32!LIMITEDIP2=Internet!" ./${1}
sed -i -e 's/^#az login/az login/' ./${1}


echo "end of setupcred.sh."
