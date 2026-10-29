#!/bin/bash
# class-dump 安装脚本（iOS/RootHide 终端直用）
# 用法：把这个文件放到任意位置，然后:
#   cd 到所在目录 && bash install-class-dump.sh

set -e

echo "== 下载 class-dump (macOS 版跑不了，改用 iOS 原生 dsdump / 或编译好的 class-dump CLI) =="

# iOS 上可用的是 dyld_shared_cache 感知的 dsdump 或 classdump-dyld。
# 最稳的是 classdump-dyld（老但能跑）；如果失败再试 dsdump。

mkdir -p /var/jb/usr/local/bin
cd /var/jb/usr/local/bin

echo "== 尝试 1: dsdump (Procursus 二进制) =="
if curl -fsSL -o dsdump https://github.com/nicklockwood/dsdump/releases/latest/download/dsdump-ios 2>/dev/null; then
  chmod 755 dsdump
  echo "dsdump 下载成功"
  ls -l dsdump
  exit 0
fi
echo "dsdump 下载失败，尝试下一种"

echo "== 尝试 2: classdump-dyld (GitHub release) =="
if curl -fsSL -o classdump-dyld https://github.com/limneos/classdump-dyld/releases/latest/download/classdump-dyld 2>/dev/null; then
  chmod 755 classdump-dyld
  echo "classdump-dyld 下载成功"
  ls -l classdump-dyld
  exit 0
fi
echo "classdump-dyld 下载失败"

echo "== 都失败了 =="
echo "请把这段输出截图发给咪咪"
