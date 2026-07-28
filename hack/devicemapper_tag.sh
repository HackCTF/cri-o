#!/usr/bin/env bash
# hack/devicemapper_tag.sh — Detecta si devicemapper está habilitado
# Retorna "devicemapper" si la librería está disponible, sino nada.
# Reemplaza exclude_graphdriver_devicemapper en BUILDTAGS.
#
# Diferencia con libdm_installed.sh: este script NO agrega
# exclude_graphdriver_devicemapper cuando falta la librería.
# Si falta libdevmapper, simplemente no retorna nada (dm-thin
# no estará disponible, pero el build no falla).

if cc -E - >/dev/null 2>/dev/null <<EOF
#include <libdevmapper.h>
EOF
then
    echo "devicemapper"
fi
