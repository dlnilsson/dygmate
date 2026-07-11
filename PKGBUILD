# Maintainer: Daniel Nilsson <git@dlnilsson.se>

pkgname=dygmate-git
_pkgname=dygmate
pkgver=0.1.0.r26.gc075964
pkgrel=1
pkgdesc='Dygma Defy wireless battery indicator'
arch=('x86_64')
url='https://github.com/dlnilsson/dygmate'
license=('GPL-2.0-only')
makedepends=('zig')
options=('!debug')
provides=('dygmate')
conflicts=('dygmate')
source=("git+${url}.git")
sha256sums=('SKIP')

pkgver() {
    cd "${srcdir}/${_pkgname}"
    printf '0.1.0.r%s.g%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)"
}

build() {
    cd "${srcdir}/${_pkgname}"

    # The Zig dependency source is committed in zig-pkg/, so this does not
    # download dependencies during the build.
    zig build -Doptimize=ReleaseSmall
}

package() {
    cd "${srcdir}/${_pkgname}"

    install -Dm755 zig-out/bin/dygmate "${pkgdir}/usr/bin/dygmate"
    install -Dm755 zig-out/bin/dygmate-tray "${pkgdir}/usr/bin/dygmate-tray"
    install -Dm644 dygmate-tray.service "${pkgdir}/usr/lib/systemd/user/dygmate-tray.service"
    install -Dm644 99-dygmate.rules "${pkgdir}/usr/lib/udev/rules.d/99-dygmate.rules"
    install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
}
