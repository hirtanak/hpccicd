#!/bin/bash
echo "running unit test1...."

# $1: OpenFOAM Version
OPENFORM_VERSION=$1
if [ -z "${OPENFORM_VERSION}" ]; then
	OPENFORM_VERSION=v1906
fi
# $2: ノード数
NUMNODE=$2
# $3: PPN
PPN=$3

MyResourceGroup=tmcbmt01
VMPREFIX=tmcbmt01
USERNAME=azureuser # ユーザ名: デフォルト azureuser
# SSH公開鍵ファイルを指定：デフォルトではカレントディレクトリを利用する
# SSHKEYFILE="./${VMPREFIX}.pub"
SSHKEYDIR="./${VMPREFIX}"
echo "SSHKEYDIR: $SSHKEYDIR"

### ログイン処理
# サブスクリプションが複数ある場合は指定しておく
#az account set -s <Subscription ID or name>
# サービスプリンシパルの利用も可能以下のパラメータとログイン処理を有効にすること
#azure_name="uuid"
#azure_password="uuid"
#azure_tenant="uuid"
#az login --service-principal --username ${azure_name} --password ${azure_password} --tenant ${azure_tenant} --output none

# コマンド名取得
CMDNAME=$(basename "$0")
# コマンドオプションエラー処理
if [ $# -eq 1 ]; then
	echo "実行するには1個の引数が必要です。" 1>&2
	#exit 1
	echo "\$#: $#"
fi

# グローバルIPアドレスの取得・処理
curl -s https://ifconfig.io > tmpip #利用しているクライアントのグローバルIPアドレスを取得
curl -s https://ipinfo.io/ip >> tmpip #代替サイトでグローバルIPアドレスを取得
curl -s https://inet-ip.info >> tmpip #代替サイトでグローバルIPアドレスを取得
sed -i -e '/^$/d' tmpip > /dev/null
LIMITEDIP="$(head -n 1 ./tmpip)/32"
rm ./tmpip
echo "current your client global ip address: $LIMITEDIP. This script defines the ristricted access from this client"
LIMITEDIP2=113.40.3.153/32 #追加制限IPアドレスをCIRDで記載 例：1.1.1.0/24
echo "addtional accessible CIDR: $LIMITEDIP2"

# PBS VMIPアドレス取得
unset pbsvmip
pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
echo "accessing pbs vm: $pbsvmip"
if [ -z "$pbsvmip" ]; then 
	echo "You can not get ${VMPREFIX}-pbs ip address"
	exit 1
fi

# SSHアクセスチェック
unset checkssh
checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} -t $USERNAME@"${pbsvmip}" "uname")
if [ -z "$checkssh" ]; then
	echo "You can not access ${VMPREFIX}-pbs by ssh"
	exit 1
fi

# OpenFOAM チュートリアルセットアップ
SSHCMD="ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t"
${SSHCMD} "cp -pr /mnt/share/OpenFOAM/OpenFOAM-${OPENFORM_VERSION}/tutorials/multiphase/interFoam/laminar/damBreak /mnt/share/"

# スクリプトセットアップ
${SSHCMD} "wget -q https://raw.githubusercontent.com/hirtanak/hpccicd/main/apps/openfoam/dambreakrun.sh -O /mnt/share/damBreak/damBreak/dambreakrun.sh"
${SSHCMD} "chmod +x /mnt/share/damBreak/damBreak/dambreakrun.sh"
${SSHCMD} "/opt/pbs/bin/qsub -l select=${NUMNODE}:ncpus=${PPN} /mnt/share/damBreak/damBreak/dambreakrun.sh"


echo "$CMDNAME: end of openfoam unittest1"
