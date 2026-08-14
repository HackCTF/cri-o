# Incidente de Desincronización del Base del Thin-Pool Devmapper

**Cluster:** Combate (HackCTF) — workers `combate-w1` y `combate-w2`
**Fecha del incidente:** 2026-08-11
**Componente:** CRI-O 1.29.13 (fork `hackctf/rel-1.29-hackctf`) — driver de almacenamiento `devicemapper` (thin-provisioning)
**Estado:** Resuelto — commit `5530f29c4`

---

## 1. Resumen ejecutivo

El 2026-08-11, tras un corte de energía / reinicio forzado en los workers del cluster Combate, el driver `devicemapper` de CRI-O entró en un ciclo de recreación del dispositivo base (`createBaseImage()`) que terminó **desincronizando los metadatos del base entre userspace y el thin-pool del kernel**: el dispositivo base (id 1) quedó presente en la metadata del pool pero **sin árbol de mapeos** (visible como `dmsetup table` vacío), lo que provocó que **toda creación de snapshots fallara en el kernel** (`Creation of new snapshot X of device 1 failed`).

La causa raíz fue un defecto de durabilidad en `writeMetaFile()`: se sincronizaba el inode temporal y se hacía `os.Rename`, pero **nunca se hacía fsync del directorio de metadatos**. Después de un crash, las entradas de directorio de `base`, `deviceset-metadata` y `transaction-metadata` podían perderse, dejando a CRI-O sin metadata de userspace al reiniciar. Dos cambios del fork (relajar `checkThinPool` y omitir `validateLVMConfig`) eliminaron las salvaguardas que habrían abortado el arranque ante un pool no vacío, permitiendo el churn.

La corrección hace durable el rename (`unix.Fdatasync` sobre el inode temporal + `dir.Sync()` sobre el directorio de metadatos tras el rename). Desplegada en ambos workers, la evidencia post-despliegue muestra `NRestarts=0`, pods Running y 0 errores thin en el kernel.

---

## 2. Entorno y alcance

| Ítem | Valor |
|---|---|
| CRI-O | `1.29.13`, git `ab789f50` (fork HackCTF) |
| Driver de almacenamiento | `devicemapper` (thin-provisioning) |
| Thin-pool | `/dev/mapper/storage-thinpool` (`storage-thinpool_tdata` / `storage-thinpool_tmeta`) |
| Directorio de metadatos | `/var/lib/containers/storage/devicemapper/metadata` |
| Kernel | 6.12 (`dm-thin.c` v1.23.0) |
| Nodos afectados | `combate-w1`, `combate-w2` |
| Imágenes afectadas | KubeVirt, CDI, CloudNativePG, TopoLVM (pulls tras el reboot) |

Los dos workers presentaron el mismo patrón; `combate-w2` con mayor severidad (más snapshots fallidos en menor tiempo).

---

## 3. Línea de tiempo

| Hora (PDT) | Evento |
|---|---|
| 09:34–09:36 | Boot de los workers tras el corte de energía. LVM reactiva `storage-thinpool`. |
| 09:35:52 (w2) | CRI-O falla en el primer intento: `devicemapper: Non existing device storage-thinpool` (el pool aún no estaba activo). systemd reintenta. |
| 09:36:02 (w2) | CRI-O (PID 3200) arranca y asume el thin-pool. |
| 10:11:32 (w2) | Primer error kernel: `Creation of new snapshot 191 of device 1 failed.` |
| 10:22:37 (w1) | Primer error kernel: `Creation of new snapshot 129 of device 1 failed.` |
| 10:11–10:45 | Ciclo continuo de fallos: `Creation of new snapshot <id> of device 1 failed`, incluyendo `50000`, y `Deletion of thin device 50000 failed`. |
| 19:05 / 19:22 | Despliegue del binario corregido (`crio-fix1`, sha `36e007d1`) en w1 y w2. |
| Post-19:22 | `NRestarts=0`, pods Running, 0 errores thin en kernel, metadata del base estable. |

---

## 4. Síntomas observados

1. **Pulls de imágenes sin progreso.** CRI-O reportaba `Image ... not found` de forma repetida (KubeVirt, CDI, CNPG) y nunca completaba el pull.
2. **Errores del kernel (dm-thin) en bucle** (`jw1_kernel.log:1528-1541`, `jw2_kernel.log:1316-1343`):

   ```
   device-mapper: thin: Creation of new snapshot 129 of device 1 failed.
   device-mapper: thin: Creation of new snapshot 50000 of device 1 failed.
   device-mapper: thin: Deletion of thin device 50000 failed.
   device-mapper: thin: Creation of new thinly-provisioned device with id 129 failed.
   ```

3. **Dispositivo base sin mapeos.** `dmsetup table container-base` (y las capas) sin entrada de tabla; el id de dispositivo 1 sigue existiendo en la metadata del pool pero **sin árbol de mapeos en `tl_info`**.
4. **Contadores de device-id escalando.** Los intentos saltan de ids consecutivos (129–137, 191–218) hasta `50000`, indicando churn de `getNextFreeDeviceID()`.

---

## 5. Investigación inicial

- Se comparó `deviceset.go` del fork contra el upstream de `containers/storage`: se encontraron tres desviaciones relevantes (ver secciones 6 y 7).
- Se extrajo el árbol de dispositivos del pool con `dmsetup message <pool> 0 reserve_metadata_snap` + `thin_dump`, confirmando la presencia de device 1 y la inconsistencia de mapeos.
- Se correlacionó cada mensaje de error del kernel con su sitio de origen exacto en `dm-thin.c` / `dm-thin-metadata.c` (ver sección 8).
- Se reconstruyó el binario afectado desde el fork (parche `deviceset.b64`), se compiló `crio-fix1` y se validó en los workers.

---

## 6. Causa raíz (userspace): `writeMetaFile` no durable

`writeMetaFile()` (commit previo, `deviceset.go:342`) escribía los metadatos con el patrón *write temp → Sync() → rename*:

```go
if err := tmpFile.Sync(); err != nil { ... }
if err := tmpFile.Close(); err != nil { ... }
if err := os.Rename(tmpFile.Name(), filePath); err != nil { ... }
```

`Sync()` garantiza que los **datos del inode** están en disco, pero **no garantiza la entrada de directorio** creada por `os.Rename`. Tras un corte de energía entre el rename y el drenaje del directorio, el filesystem puede recuperar el estado anterior: los inodes (con datos) sobreviven, pero las **entradas de directorio** de `base`, `deviceset-metadata` y `transaction-metadata` se pierden o quedan obsoletas.

Consecuencia: al reiniciar, CRI-O **no encuentra la metadata del base en userspace** aunque el thin-pool del kernel conserva todos sus dispositivos y bloques.

---

## 7. Factores agravantes (cambios del fork)

El fork introdujo dos relajaciones que eliminaron las salvaguardas de arranque seguro:

1. **`checkThinPool` permisivo** (`deviceset.go:1130-1144`): upstream devolvía error si `dataUsed != 0` o `transactionID != 0` (se negaba a tomar posesión de un pool sucio). El fork lo cambió a `logrus.Warnf(...) ... continuing`. Sin este cambio, CRI-O habría **abortado el arranque** en lugar de recrear el base sobre un pool con datos.

2. **Omisión de `validateLVMConfig`** (`deviceset.go:2877-2881`): se salta la validación cuando `thinPoolDevice` ya está pre-configurado (`if !testMode && devices.thinPoolDevice == ""`), permitiendo proseguir con configuraciones que antes se rechazaban.

Estos cambios se introdujeron en los commits `db3e0453c` y `228c750f6` (2026-07-28/29), antes del incidente.

---

## 8. Mecanismo en el kernel: el base queda "sin mapeos"

Flujo al reiniciar con metadata de userspace perdida:

1. `setupBaseImage()` (`deviceset.go:1241-1284`) encuentra `oldInfo == nil` (la metadata del base se perdió) y, por el `checkThinPool` permisivo, continúa.
2. `createBaseImage()` (`deviceset.go:1071-1101`) → `createRegisterDevice("")` (`deviceset.go:804-857`) → `CreateDevice(pool, 1)`. Si el id 1 ya existe en el pool, el kernel devuelve `-EEXIST` → libdevmapper lo reporta como `ErrDeviceIDExists` → el bucle salta al siguiente id libre ("Device ID %d exists in pool but it is supposed to be unused", `deviceset.go:826`). El churn de create/delete repite esto en cada reintento/restart.
3. **El `delete <id>` sí puede remover el árbol de mapeos.** `DeleteDevice` (`devmapper.go:690`) envía el mensaje `delete <dev_id>` → `process_delete_mesg` → `dm_pool_delete_thin_device` → `__delete_device` (`dm-thin-metadata.c:1249`), que borra el dispositivo de `details_info` y de **`tl_info` (árbol de mapeos principal, `dm-thin-metadata.c:1272`)**. Los metadatos del pool sobreviven al crash; los de userspace no. El resultado observable: **el id 1 existe en la metadata del pool pero sin árbol de mapeos → `dmsetup table` vacío para el base**.

4. **Toda creación de snapshot falla.** `create_snap` → `process_create_snap_mesg` (`dm-thin.c:3726`) → `dm_pool_create_snap` → `__create_snap` (`dm-thin-metadata.c:1180`): la búsqueda del origen en `tl_info` falla (`dm-thin-metadata.c:1196-1198`), generando el DMWARN:

   ```
   "Creation of new snapshot %s of device %s failed."   // dm-thin.c:3746
   ```

   El delete de las capas rotas también falla:

   ```
   "Deletion of thin device %s failed."                  // dm-thin.c:3769
   ```

5. Las capas que sí quedaron en userspace (p.ej. id `50000`) referencian un origen sin mapeos; su borrado falla porque el id ya no está en `details_info` (`__delete_device`, `dm-thin-metadata.c:1256`).

En resumen: **la pérdida de metadata de userspace + las relajaciones del fork + el churn de `createBaseImage` dejaron al dispositivo base (id 1) del thin-pool sin árbol de mapeos**, y por ello todos los snapshots posteriores que lo usan como origen fallan en el kernel.

---

## 9. Correlación de evidencia

| Evidencia | Sitio de origen |
|---|---|
| `Creation of new snapshot 129 of device 1 failed.` | `dm-thin.c:3746` (`process_create_snap_mesg` → `dm_pool_create_snap`) |
| Causa del fallo de snapshot | `dm-thin-metadata.c:1196-1198` (origen sin árbol en `tl_info`) |
| `Deletion of thin device 50000 failed.` | `dm-thin.c:3769` (`process_delete_mesg` → `dm_pool_delete_thin_device`) |
| Borrado del árbol de mapeos del base | `dm-thin-metadata.c:1249-1277` (`__delete_device`, remoción en `tl_info`) |
| Churn userspace | `deviceset.go:1241-1284` (`setupBaseImage`), `deviceset.go:804-857` (`createRegisterDevice`) |
| Relajación de salvaguardas | `deviceset.go:1130-1144` (`checkThinPool`), `deviceset.go:2877-2881` |
| Defecto de durabilidad | `deviceset.go:342` (`writeMetaFile`, pre-fix) |

---

## 10. Mitigaciones temporales

- Detener los reintentos de pull en los nodos afectados para frenar el churn.
- Verificación manual del estado del pool: `dmsetup table storage-thinpool`, `dmsetup message storage-thinpool 0 reserve_metadata_snap` + `thin_dump`.
- Confirmar la consistencia de `transaction-metadata` (`open_txid` == `txid` del pool) antes de cualquier operación destructiva.
- No re-crear el base manualmente mientras el pool tenga datos no referenciados por userspace; ante duda, preservar la metadata del pool.

---

## 11. Defecto, corrección y evidencia post-despliegue

### 11.1 El defecto

`writeMetaFile()` (`deviceset.go:342`) usaba `tmpFile.Sync()` + `os.Rename` **sin fsync del directorio padre**. Después de un crash del host entre el rename y el drenaje de la entrada de directorio, los archivos de metadata (`base`, `deviceset-metadata`, `transaction-metadata`) podían perderse en el siguiente boot aunque el inode estuviera durablemente commiteado. Eso, combinado con las relajaciones del fork (secciones 7), llevó al churn de `createBaseImage()` y a dejar el dispositivo 1 del thin-pool sin mapeos (sección 8).

### 11.2 La corrección (commit `5530f29c4`)

```go
// Antes
if err := tmpFile.Sync(); err != nil { ... }
if err := tmpFile.Close(); err != nil { ... }
if err := os.Rename(tmpFile.Name(), filePath); err != nil { ... }

// Después (deviceset.go:345-359)
if err := unix.Fdatasync(int(tmpFile.Fd())); err != nil { ... }
if err := tmpFile.Close(); err != nil { ... }
if err := os.Rename(tmpFile.Name(), filePath); err != nil { ... }
dir, err := os.Open(devices.metadataDir())
if err == nil {
    if derr := dir.Sync(); derr != nil {
        logrus.Warnf("devmapper: Error syncing metadata directory %s: %v", devices.metadataDir(), derr)
    }
    dir.Close()
}
```

- `unix.Fdatasync()` sobre el inode temporal: sincroniza los datos sin forzar actualizaciones de metadatos de inode innecesarias.
- `dir.Sync()` (fsync sobre el directorio) tras el `os.Rename`: fuerza la **entrada de directorio** a disco, haciendo durable el rename.
- Si `dir.Sync()` falla, solo se registra un warning: los datos ya están en disco; únicamente el índice del directorio puede quedar rezagado.

### 11.3 Evidencia post-despliegue

Binario corregido `crio-fix1` (sha `36e007d1...`), desplegado en `combate-w1` (19:05 PDT) y `combate-w2` (19:22 PDT) el 2026-08-11:

- **`NRestarts=0`** en ambos workers tras el despliegue (sin reintentos de `crio.service`).
- **Pods Running**; los pulls de KubeVirt/CDI/CNPG completan.
- **0 errores `device-mapper: thin`** en el kernel post-restart (antes: decenas de `Creation of new snapshot ... of device 1 failed`).
- **`combate-w2` recreó metadata/base correctamente** por la ruta de fix (`initialized: true`).
- **`transaction-metadata` alineado**: `open_txid` == `txid` del pool.
- **`BaseDeviceUUID` estable** entre reinicios en `deviceset-metadata`.

---

## 12. Lecciones aprendidas y recomendaciones

1. **Durabilidad de metadata**: cualquier escritura de metadata vía rename requiere `fsync` del directorio padre (o al menos del archivo) para sobrevivir a cortes de energía. Aplicable a `writeMetaFile`, `saveDeviceSetMetaData` y cualquier archivo crítico de storage.
2. **No relajar `checkThinPool`**: tomar posesión de un pool con `dataUsed != 0` o `transactionID != 0` debe seguir siendo un error duro; la verificación de ownership protege contra la re-creación de un base sobre datos existentes.
3. **Monitorización**: alertar sobre mensajes kernel `device-mapper: thin: Creation of new snapshot ... of device <n> failed` y sobre `dmsetup table` vacío en dispositivos del pool; son síntomas tempranos de desincronización base.
4. **Diagnóstico**: ante la pérdida de metadata de userspace, preservar la metadata del pool (`reserve_metadata_snap` + `thin_dump`) antes de cualquier acción correctiva.
