#!/usr/bin/env bash
# 生成是语输入法 App Store 截图 (1290x2796)。
# 用法: bash gen/build.sh   (在 iOS/store-assets 目录下运行)
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
GEN=gen; OUT=output
mkdir -p "$OUT"
TPL=$(cat gen/template.html)

gen_one () {
  local name="$1" theme="$2" title="$3" sub="$4" pad="$5" img="$6"
  local html="${TPL//\{\{THEME\}\}/$theme}"
  html="${html//\{\{TITLE\}\}/$title}"
  html="${html//\{\{SUB\}\}/$sub}"
  html="${html//\{\{PAD\}\}/$pad}"
  html="${html//\{\{IMG\}\}/$img}"
  printf '%s' "$html" > "$GEN/_$name.html"
  "$CHROME" --headless --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=1 --window-size=1284,2778 \
    --screenshot="$OUT/$name.png" \
    "file://$PWD/$GEN/_$name.html" 2>/dev/null
  echo "$name -> $OUT/$name.png"
}

gen_one "01-offline" "dark" \
  "完全离线的输入法" \
  "不联网 · 不申请完全访问 · <span class='accent'>输入永不出手机</span>" \
  "<div class='bubble recv'>这个方案能发我一份吗？</div><div class='bubble'>可以，我整理好发你</div>" \
  "../keyboards/kbd-candidates-dark.png"

gen_one "02-shuangpin" "light" \
  "完美支持双拼输入" \
  "微软双拼开箱即用，<span class='accent'>全拼一键切换</span>" \
  "<div class='bubble recv'>你用的什么输入法？</div><div class='bubble'>是语，双拼输入法</div>" \
  "../keyboards/kbd-shuangpin-light.png"

gen_one "03-sentence" "dark" \
  "可以整句话输入" \
  "本地整句解码，<span class='accent'>连着打，少打断</span>" \
  "<div class='bubble recv'>在忙吗？</div><div class='bubble'>可以打完整的一句话</div>" \
  "../keyboards/kbd-sentence-dark.png"

echo "done."
