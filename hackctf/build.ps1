# build.ps1 — Script de build de CRI-O con dm-thin
# Ejecutar desde D:\HackCTF\cri-o
# Requiere Docker corriendo en Windows
#
# Uso:
#   .\hackctf\build.ps1                    # Build completo
#   .\hackctf\build.ps1 -SkipTests         # Sin tests
#   .\hackctf\build.ps1 -Push              # Build + push a Harbor
#   .\hackctf\build.ps1 -OutputDir C:\out  # Directorio de salida custom

param(
    [string]$ImageTag = "harbor.k8s.local/library/cri-o:hackctf-dm-thin-v1",
    [switch]$SkipTests,
    [switch]$Push,
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"
$StartTime = Get-Date

Write-Host "=== CRI-O dm-thin Build ===" -ForegroundColor Cyan
Write-Host "Rama: hackctf/rel-1.29-hackctf" -ForegroundColor Yellow
Write-Host "Imagen: $ImageTag" -ForegroundColor Yellow
Write-Host "Inicio: $($StartTime.ToString('HH:mm:ss'))" -ForegroundColor Gray

# Verificar que estamos en la rama correcta
$currentBranch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($currentBranch -ne "hackctf/rel-1.29-hackctf") {
    Write-Host "ERROR: Estás en la rama '$currentBranch', no en 'hackctf/rel-1.29-hackctf'" -ForegroundColor Red
    Write-Host "Ejecuta: git checkout hackctf/rel-1.29-hackctf" -ForegroundColor Yellow
    exit 1
}

# Verificar que Docker está corriendo
try {
    docker info 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw }
} catch {
    Write-Host "ERROR: Docker no está corriendo" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "[1/4] Verificando BUILDTAGS..." -ForegroundColor Cyan

# Verificar que exclude_graphdriver_devicemapper NO está en el Makefile
$makefile = Get-Content "Makefile" -Raw
if ($makefile -match "exclude_graphdriver_devicemapper") {
    Write-Host "  ALERTA: exclude_graphdriver_devicemapper encontrado en Makefile" -ForegroundColor Yellow
    Write-Host "  Esto debe eliminarse para dm-thin" -ForegroundColor Yellow
} else {
    Write-Host "  OK: Makefile limpio (sin exclude_graphdriver_devicemapper)" -ForegroundColor Green
}

Write-Host ""
Write-Host "[2/4] Compilando CRI-O en Docker..." -ForegroundColor Cyan

# Build de la imagen de compilación
Write-Host "  Ejecutando: docker build -f hackctf/Dockerfile.build -t crio-build:hackctf ."
docker build -f hackctf/Dockerfile.build -t crio-build:hackctf . 2>&1 | Tee-Object -FilePath "hackctf\output\build.log"

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR en la compilación. Ver hackctf\output\build.log" -ForegroundColor Red
    exit 1
}

Write-Host "  OK: CRI-O compilado exitosamente" -ForegroundColor Green

# Extraer binarios
Write-Host ""
Write-Host "[3/4] Extrayendo binarios..." -ForegroundColor Cyan

$tempContainer = "crio-build-temp-" + (Get-Random -Maximum 9999)
docker create --name $tempContainer crio-build:hackctf 2>$null
docker cp "${tempContainer}:/output" "hackctf\output\"
docker rm $tempContainer 2>$null

Write-Host "  Binarios extraídos a hackctf\output\" -ForegroundColor Green
Get-ChildItem "hackctf\output\" -Recurse | Format-Table Name, Length, LastWriteTime

Write-Host ""
Write-Host "[4/4] Construyendo imagen de runtime..." -ForegroundColor Cyan

# Build de la imagen de runtime
docker build -f hackctf/Dockerfile.runtime -t $ImageTag . 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR en la imagen de runtime" -ForegroundColor Red
    exit 1
}

Write-Host "  OK: Imagen de runtime creada: $ImageTag" -ForegroundColor Green

# Push a Harbor si se solicita
if ($Push) {
    Write-Host ""
    Write-Host "Push a Harbor..." -ForegroundColor Cyan
    docker push $ImageTag 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR en push a Harbor" -ForegroundColor Red
        exit 1
    }
    Write-Host "  OK: Push completado" -ForegroundColor Green
}

# Resumen
$EndTime = Get-Date
$Duration = $EndTime - $StartTime

Write-Host ""
Write-Host "=== Build Completado ===" -ForegroundColor Green
Write-Host "Duración: $($Duration.Minutes)m $($Duration.Seconds)s" -ForegroundColor Gray
Write-Host "Imagen: $ImageTag" -ForegroundColor Yellow
Write-Host ""
Write-Host "Próximos pasos:" -ForegroundColor Cyan
Write-Host "  1. Crear thin pool en el worker:" -ForegroundColor Gray
Write-Host "     ssh root@192.168.56.141" -ForegroundColor Gray
Write-Host "     pvcreate /dev/sdd && vgcreate crio-vg /dev/sdd" -ForegroundColor Gray
Write-Host "     lvcreate -L 180G -T crio-vg/crio-dm-pool -l 95%FREE" -ForegroundColor Gray
Write-Host "  2. Desplegar imagen:" -ForegroundColor Gray
Write-Host "     podman pull $ImageTag" -ForegroundColor Gray
Write-Host "     # Copiar binarios a /usr/local/bin/" -ForegroundColor Gray
Write-Host "  3. Ejecutar benchmark:" -ForegroundColor Gray
Write-Host "     bash hackctf/benchmark/bench-container-creation.sh 1000" -ForegroundColor Gray
