# CRI-O v6 (dm-thin) - build nativo AlmaLinux 10.1

Binarios `crio` (1.29.13, fork `hackctf/rel-1.29-hackctf`) y `pinns`
compilados **nativamente en `nervous-vaughan`** (AlmaLinux 10.1) el
2026-07-24, con soporte devicemapper/thin-pool (patches en
`vendor/github.com/containers/storage/drivers/devmapper/`).

El build anterior (`D:\HackCTF\cri-o\hackctf\output\crio`, hecho en Docker con
base `golang:1.23-bookworm`) **no corre en AlmaLinux** — requiere
`libdevmapper.so.1.02.1` con ABI de Debian/Bookworm, incompatible con RHEL10.
Este binario aqui SI es el correcto.

## Como se compilo

```bash
# En el nodo target (AlmaLinux 10), NO usar el Dockerfile.build (bookworm):
dnf install -y libseccomp-devel gpgme-devel btrfs-progs-devel glibc-static \
    libxcrypt-static libaio-devel libselinux-devel device-mapper-devel

export PATH=$PATH:/usr/local/go/bin   # go 1.23.4 ya instalado en el nodo
cd crio-build   # source tar del repo, rama hackctf/rel-1.29-hackctf (con
                # los cambios de vendor/ SIN commitear incluidos)
go build -trimpath -ldflags "-s -w -X github.com/cri-o/cri-o/internal/version.buildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -tags "containers_image_ostree_stub exclude_graphdriver_btrfs btrfs_noversion containers_image_openpgp seccomp selinux libdm_no_deferred_remove" \
  -o crio ./cmd/crio

cd pinns && make   # requiere glibc-static (link -static)
```

## Deploy

```bash
cp crio /usr/bin/crio
cp pinns /usr/bin/pinns
systemctl restart crio
```

Storage config necesaria (`/etc/containers/storage.conf`):
```ini
[storage]
driver = "devicemapper"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
```
Y en `/etc/crio/crio.conf.d/05-storage.conf` (¡NO en storage.conf, y la
seccion es `[crio]` plano, NO `[crio.storage]`!):
```ini
[crio]
storage_driver = "devicemapper"
storage_option = [
    "dm.thinpooldev=/dev/mapper/storage-thinpool",
    "dm.fs=xfs",
]
```

## Estado (2026-07-24)

Instalado y corriendo en `nervous-vaughan` (`/usr/bin/crio`, `/usr/bin/pinns`).
Thin pool `storage-thinpool` activo (VG `storage`, 249.74G).

## Pendiente para reproducibilidad completa

NO wireado al playbook Ansible (`dm_thin` role es EXPERIMENTAL/opt-in). Ver
nota equivalente en `D:\HackCTF\lvm2\prebuilt-almalinux10\README.md`.
