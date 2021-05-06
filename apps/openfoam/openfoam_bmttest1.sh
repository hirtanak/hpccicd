#!/bin/bash
echo "BENCHMARK: running benchmark test1...."

# $1 ベンチマークコンフィグファイルの読み込み ./senarios/bmtconf
# デフォルト: ./apps/openfoam/20210425-bmtconf-01
BMTCONF=$1
if [ -z "${BMTCONF}" ]; then
	BMTCONF="20210425-bmtconf-01"
fi
OPENFORM_VERSION=v1906

MyResourceGroup=tmcbmt01-hpccicd01
VMPREFIX=hpccicd01
USERNAME=azureuser # ユーザ名: デフォルト azureuser
# SSH公開鍵ファイルを指定：デフォルトではカレントディレクトリを利用する
SSHKEYFILE="./${VMPREFIX}.pub"

### ログイン処理
# サブスクリプションが複数ある場合は指定しておく
#az account set -s <Subscription ID or name>
# サービスプリンシパルの利用も可能以下のパラメータとログイン処理を有効にすること
#azure_name="uuid"
#azure_password="uuid"
#azure_tenant="uuid"
# az login --service-principal --username ${azure_name} --password ${azure_password} --tenant ${azure_tenant} --output none

# コマンド名取得
CMDNAME=$(basename "$0")
# コマンドオプションエラー処理
if [ $# -eq 1 ]; then
	echo "実行するには1個の引数が必要です。" 1>&2
	#exit 1
fi
# SSH鍵チェック
SSHKEYDIR="./${VMPREFIX}"
echo "SSHKEYDIR: $SSHKEYDIR"

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
checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} -t $USERNAME@"${pbsvmip}" "uname")
if [ -z "$checkssh" ]; then
	echo "can not access ${VMPREFIX}-pbs by ssh"
	exit 1
fi

# OpenFOAM チュートリアルセットアップ
SSHCMD="ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t"
${SSHCMD} "cp -pr /mnt/share/OpenFOAM/OpenFOAM-${OPENFORM_VERSION}/tutorials/multiphase/interFoam/laminar/damBreak /home/$USERNAME/"
${SSHCMD} "wget -q https://raw.githubusercontent.com/hirtanak/hpccicd/main/apps/openfoam/dambreakrun.sh -O /home/$USERNAME/damBreak/dambreakrun.sh"
${SSHCMD} "chmod +x /home/$USERNAME/damBreak/dambreakrun.sh"

# ベンチマークケースパラメータ生成
wget -q https://raw.githubusercontent.com/hirtanak/hpccicd/main/apps/openfoam/${BMTCONF} -O ./${BMTCONF}
# 空行削除
sed -i -e '/^$/d' ./${BMTCONF} > /dev/null
casenum=$(cat ./${BMTCONF} | wc -l)
for count in $(seq 1 "$casenum"); do
	line=$(sed -n "${count}"P ./${BMTCONF})
	${SSHCMD} "mkdir -p /mnt/share/${count}-damBreak"
	# OpenFOAM チュートリアルセットアップ
	${SSHCMD} "cp -pr /home/$USERNAME/damBreak /mnt/share/${count}-damBreak"
	# スクリプトセットアップ
	${SSHCMD} "cp /home/$USERNAME/damBreak/dambreakrun.sh /mnt/share/${count}-damBreak/damBreak/dambreakrun.sh"
	# パラメータセットアップ
	NUMNODE=$(echo "$line" | cut -d " " -f 2)
	NP=$(echo "$line" | cut -d " " -f 3)
	PPN=$(echo "$line" | cut -d " " -f 4)
	OPT1=$(echo "$line" | cut -d " " -f 5)
	OPT2=$(echo "$line" | cut -d " " -f 6)
	# ジョブ投入
	${SSHCMD} "cd /mnt/share/${count}-damBreak/damBreak/ && /opt/pbs/bin/qsub -l select=${NUMNODE}:ncpus=${PPN} /mnt/share/${count}-damBreak/damBreak/dambreakrun.sh"
done


echo "$CMDNAME: BENCHMARK - end of openfoam benchamrk test1"
