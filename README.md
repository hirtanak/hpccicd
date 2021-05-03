[![MIT License](https://img.shields.io/badge/license-MIT-brightgreen)](LICENSE) [![release](https://img.shields.io/github/v/release/hirtanak/hpccicd?include_prereleases)](release) [![Issues](https://img.shields.io/github/issues/hirtanak/hpccicd)](issues) [![downloads](https://img.shields.io/github/downloads/hirtanak/hpccicd/total)](downloads)

# hpccicd: これはなにか？

Azure向けHPC環境展開スクリプトをベースにした自動化プロジェクトです。
HPC環境作成の自動化・管理・アプリケーション管理の自動化を行います。

### Azure自動化ワークフロー
[![01azure_deploy](https://github.com/hirtanak/hpccicd/actions/workflows/01azure_deploy.yml/badge.svg)](https://github.com/hirtanak/hpccicd/actions/workflows/01azure_deploy.yml)　 --PBS--> [![12addpbsnode](https://github.com/hirtanak/hpccicd/actions/workflows/12addpbsnode.yml/badge.svg)](https://github.com/hirtanak/hpccicd/actions/workflows/12addpbsnode.yml) --CycleCloud--> [![14addcyclecloud](https://github.com/hirtanak/hpccicd/actions/workflows/14addcyclecloud.yml/badge.svg)](https://github.com/hirtanak/hpccicd/actions/workflows/14addcyclecloud.yml)

### 自動化ステータス：
[![92autocardassin](https://github.com/hirtanak/hpccicd/actions/workflows/92autocardassin.yml/badge.svg)](https://github.com/hirtanak/hpccicd/actions/workflows/92autocardassin.yml) : プロセス別プロジェクトアサイナーの自動変更

### Basicインフラテスト
[![11checkpingpong](https://github.com/hirtanak/hpccicd/actions/workflows/11checkpingpong.yml/badge.svg)](https://github.com/hirtanak/hpccicd/actions/workflows/11checkpingpong.yml) : [MPI pingpong の結果表示](https://hirtanak.github.io/hpccicd/)

### App1:
[![81appinstall_openfoam](https://github.com/hirtanak/hpccicd/actions/workflows/81appinstall_openfoam.yml/badge.svg)](https://github.com/hirtanak/hpccicd/actions/workflows/81appinstall_openfoam.yml) : OpenFOAM アプリケーションビルド

[![82openfoam_unittest](https://github.com/hirtanak/hpccicd/actions/workflows/82openfoam_unittest.yml/badge.svg)](https://github.com/hirtanak/hpccicd/actions/workflows/82openfoam_unittest.yml): OpenFOAM ユニットテスト

[![83openfoam_benchmarktest](https://github.com/hirtanak/hpccicd/actions/workflows/83openfoam_benchmark01.yml/badge.svg)](https://github.com/hirtanak/hpccicd/actions/workflows/83openfoam_benchmark01.yml): OpenFOAM ベンチマークテスト

### App2:

#### depreciated workflow
[![91creatingissues](https://github.com/hirtanak/hpccicd/actions/workflows/91creatingissues.yml/badge.svg)](https://github.com/hirtanak/hpccicd/actions/workflows/91creatingissues.yml) : テスト(issue)自動生成 

[![93makepingpongresult](https://github.com/hirtanak/hpccicd/actions/workflows/93makepingpongresult.yml/badge.svg)](https://github.com/hirtanak/hpccicd/actions/workflows/93makepingpongresult.yml) : MPI pingpong の結果表示

[![94movecard](https://github.com/hirtanak/hpccicd/actions/workflows/94movecard.yml/badge.svg)](https://github.com/hirtanak/hpccicd/actions/workflows/94movecard.yml) : 


