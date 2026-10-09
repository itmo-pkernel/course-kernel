#!/usr/bin/env bash
# Сборка ядра стенда курса «Программирование в режиме ядра».
#
# Использование:
#   build.sh <stand|debug> <out_dir>
#
# Результат в <out_dir>:
#   kmc-<flavor>-<версия>.tar.xz — vmlinuz, config, System.map и build/ — дерево для
#                                   сборки внешних модулей (make -C build M=...)
#   *.deb                       — те же ядро и заголовки пакетами Debian
#
# Почему своё ядро, а не ядро дистрибутива: модуль должен собираться ровно под то
# ядро, которое грузится в QEMU (vermagic, лекция 2), а ядро хоста и раннеров
# GitHub меняется без нашего ведома. Отладочный вариант (KASAN, UBSAN, lockdep)
# в дистрибутивах не поставляется вовсе.
set -euo pipefail

FLAVOR="${1:?usage: build.sh <stand|debug> <out_dir>}"
OUT="$(realpath -m "${2:?usage: build.sh <stand|debug> <out_dir>}")"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/VERSION"          # KVER, KSHA256

case "$FLAVOR" in
    stand) FRAGMENTS=("$HERE/configs/stand.config") ;;
    debug) FRAGMENTS=("$HERE/configs/stand.config" "$HERE/configs/debug.config") ;;
    *) echo "неизвестный вариант: $FLAVOR" >&2; exit 1 ;;
esac

mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

TARBALL="linux-${KVER}.tar.xz"
curl -fsSL -o "$TARBALL" "https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/${TARBALL}"
echo "${KSHA256}  ${TARBALL}" | sha256sum -c -
tar -xf "$TARBALL"
cd "linux-${KVER}"

make -s x86_64_defconfig
scripts/kconfig/merge_config.sh -m .config "${FRAGMENTS[@]}" >/dev/null
make -s olddefconfig

# merge_config только предупреждает, если опция не применилась (не выполнены
# зависимости). Нам нужна гарантия: каждая опция из фрагментов — в итоговом .config.
fail=0
while IFS= read -r line; do
    case "$line" in
        CONFIG_*=*)
            grep -qxF -- "$line" .config || { echo "не применилось: $line" >&2; fail=1; } ;;
        "# CONFIG_"*" is not set")
            opt="${line#\# }"; opt="${opt%% *}"
            if grep -qE "^${opt}=" .config; then echo "не выключилось: $opt" >&2; fail=1; fi ;;
    esac
done < <(awk '
    /^CONFIG_/                   { k = substr($0, 1, index($0, "=") - 1) }
    /^# CONFIG_.* is not set$/   { k = $2 }
    k != "" { if (!(k in v)) ord[n++] = k; v[k] = $0; k = "" }
    END { for (i = 0; i < n; i++) print v[ord[i]] }' "${FRAGMENTS[@]}")
[ "$fail" -eq 0 ] || exit 1

make -j"$(nproc)" bindeb-pkg KDEB_PKGVERSION="${KVER}-1" >build.log 2>&1 || { tail -n 80 build.log; exit 1; }

KREL="$(make -s kernelrelease)"
cd "$WORK"
mkdir -p "pkg/kmc-${FLAVOR}"
for deb in linux-image-"${KREL}"_*.deb linux-headers-"${KREL}"_*.deb; do
    dpkg-deb -x "$deb" pkg/root
done
P="pkg/kmc-${FLAVOR}"
cp "pkg/root/boot/vmlinuz-${KREL}" "$P/vmlinuz"
cp "pkg/root/boot/config-${KREL}" "$P/config"
cp "pkg/root/boot/System.map-${KREL}" "$P/System.map"
cp -a "pkg/root/usr/src/linux-headers-${KREL}" "$P/build"
echo "$KREL" > "$P/release"
tar -C pkg -cJf "$OUT/kmc-${FLAVOR}-${KVER}.tar.xz" "kmc-${FLAVOR}"
cp linux-image-"${KREL}"_*.deb linux-headers-"${KREL}"_*.deb "$OUT/"
echo "Готово: $OUT/kmc-${FLAVOR}-${KVER}.tar.xz (${KREL})"
