#!/bin/bash
echo "BENCHMARK: getting benchmark result1...."

# $1 ベンチマークコンフィグファイルの読み込み ./senarios/bmtconf
# デフォルト: ./apps/openfoam/20210425-bmtconf-01
BMTCONF=$1
if [ -z "${BMTCONF}" ]; then
	BMTCONF="20210425-bmtconf-01"
fi
OPENFORM_VERSION="v1906"

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

# PBS VM IPアドレス取得
unset pbsvmip
pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
echo "accessing vm1: $pbsvmip"
if [ -z "$pbsvmip" ]; then
	echo "can not get ${VMPREFIX}-pbs ip address"
	exit 1
fi

# SSHアクセスチェック
unset checkssh
checkssh=$(ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t $USERNAME@"${pbsvmip}" "uname")
for count in $(seq 1 10); do
	checkssh=$(ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t $USERNAME@"${pbsvmip}" "uname")
	if [ -n "$checkssh" ]; then
		break
	else
		checkssh=$(ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t $USERNAME@"${pbsvmip}" "uname")
		echo "sleep 2" & sleep 2
	fi
done
if [ -z "$checkssh" ]; then
	echo "can not access ${VMPREFIX}-pbs by ssh"
	exit 1
fi

SSHCMD="ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t"

# ベンチマークケースパラメータ生成
wget -q https://raw.githubusercontent.com/hirtanak/hpccicd/main/apps/openfoam/${BMTCONF} -O ./${BMTCONF}
# 空行削除
sed -i -e '/^$/d' ./${BMTCONF} > /dev/null
casenum=$(cat ./${BMTCONF} | wc -l)

for count in $(seq 1 "$casenum"); do
	line=$(sed -n "${count}"P ./${BMTCONF})
	SSHCMD="tar zcf ./${count}-damBreak.tar.gz -T /mnt/share/${count}-damBreak/"
done
# ローカルへ転送
scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@"${pbsvmip}":/home/$USERNAME/*-damBreak.tar.gz ./
file ./*-damBreak.tar.gz | cut -d ":" -f 1 > resultlist


echo "$CMDNAME: BENCHMARK - end of getting openfoam benchamrk result1"
